# GPU telemetry from NVML (libnvidia-ml), the library `nvidia-smi` reads. Called in process, a few
# calls per device, so sampling every couple of seconds costs microseconds and needs no CUDA.jl. A
# job sees the GPUs its allocation holds (NVML lists only the devices the process may use). Where
# the library is absent (no NVIDIA driver: a laptop, a CPU node) there are no GPUs to report.

const _Libdl = Base.Libc.Libdl
const _NVML = Ref{Ptr{Cvoid}}(C_NULL)
const _NVML_STATE = Ref(0)                    # 0 not tried yet, 1 ready, -1 unavailable
const _NVML_NAMES = Dict{Int,String}()        # device index → name, read once

function _nvml_ready()
    _NVML_STATE[] == 0 || return _NVML_STATE[] == 1
    h = Sys.iswindows() ? _Libdl.dlopen("nvml.dll"; throw_error = false) :
                          _Libdl.dlopen("libnvidia-ml.so.1"; throw_error = false)
    init = h === nothing ? nothing : _Libdl.dlsym(h, :nvmlInit_v2; throw_error = false)
    if init === nothing || ccall(init, Cint, ()) != 0
        _NVML_STATE[] = -1
        return false
    end
    _NVML[] = h
    _NVML_STATE[] = 1
    return true
end

_nvml_fn(name::Symbol) = _Libdl.dlsym(_NVML[], name; throw_error = false)

# The memory of process `pid` on `dev`, from the running-compute-process list (struct versions 2 and 3
# share a 24-byte layout: pid, then used bytes at offset 8; version 1 is 16 bytes). -1 when unknown.
function _nvml_proc_mem(dev::Ptr{Cvoid}, pid::Integer)
    for (sym, stride) in ((:nvmlDeviceGetComputeRunningProcesses_v3, 24),
                          (:nvmlDeviceGetComputeRunningProcesses_v2, 24),
                          (:nvmlDeviceGetComputeRunningProcesses, 16))
        f = _nvml_fn(sym); f === nothing && continue
        n = Ref{Cuint}(64)
        buf = zeros(UInt8, 64 * stride)
        rc = ccall(f, Cint, (Ptr{Cvoid}, Ref{Cuint}, Ptr{UInt8}), dev, n, buf)
        rc == 0 || return Int64(-1)
        for k in 0:Int(n[]) - 1
            p = GC.@preserve buf unsafe_load(Ptr{Cuint}(pointer(buf, k * stride + 1)))
            Int(p) == Int(pid) || continue
            return Int64(GC.@preserve buf unsafe_load(Ptr{UInt64}(pointer(buf, k * stride + 9))))
        end
        return Int64(0)                         # listed nothing for this process: it holds none
    end
    return Int64(-1)
end

# NVML samples a GPU's utilization itself, several times a second, into a buffer it keeps. Reading
# that buffer since the previous call gives the busy share over the WHOLE interval between telemetry
# samples, where the single reading `nvmlDeviceGetUtilizationRates` returns covers well under a second
# of it and misses short kernels. `(avg, max)` in percent, or `nothing` when NVML has no samples to give.
const _NVML_LAST_TS = Dict{Int,UInt64}()     # device index → timestamp of the newest sample seen
const _NVML_SAMPLE_BUF = zeros(UInt8, 16 * 128)   # nvmlSample_t: UInt64 timestamp, then the 8-byte value
function _nvml_util_window(i::Integer, dev::Ptr{Cvoid})
    f = _nvml_fn(:nvmlDeviceGetSamples); f === nothing && return nothing
    last = get(_NVML_LAST_TS, Int(i), UInt64(0))
    vtype = Ref{Cint}(0); n = Ref{Cuint}(128)
    buf = _NVML_SAMPLE_BUF
    rc = GC.@preserve buf ccall(f, Cint, (Ptr{Cvoid}, Cint, Culonglong, Ref{Cint}, Ref{Cuint}, Ptr{UInt8}),
                                dev, 1, last, vtype, n, buf)          # NVML_GPU_UTILIZATION_SAMPLES = 1
    (rc != 0 || n[] == 0) && return nothing
    tot = 0; mx = 0; newest = last
    for k in 0:Int(n[]) - 1
        ts = GC.@preserve buf unsafe_load(Ptr{UInt64}(pointer(buf, 16k + 1)))
        v = Int(GC.@preserve buf unsafe_load(Ptr{UInt32}(pointer(buf, 16k + 9))))   # unsigned int value
        tot += v; mx = max(mx, v); newest = max(newest, ts)
    end
    _NVML_LAST_TS[Int(i)] = newest
    # The first call of a process has no "since": what it returns is NVML's whole recent history.
    last == 0 && return nothing
    return (round(Int, tot / n[]), mx)
end

"""
    gpu_sample(; pid = getpid()) -> Vector{NamedTuple}

One reading per visible GPU: `i`, `name`, `util` (percent busy, averaged over the time since the
previous call), `util_max` (its busiest moment in that time), `mem_util` (percent), `mem_used` and `mem_total`
(bytes), `temp` (°C), `power_w` and `power_limit_w`, `sm_mhz` and `sm_max_mhz`, `throttle` (what is
holding its clocks down, by name) and `proc_mem`, the bytes process `pid` holds there. A field NVML
cannot give is -1. Empty without NVML.
"""
function gpu_sample(; pid::Integer = getpid())
    out = NamedTuple[]
    _nvml_ready() || return out
    count = Ref{Cuint}(0)
    f = _nvml_fn(:nvmlDeviceGetCount_v2)
    (f === nothing || ccall(f, Cint, (Ref{Cuint},), count) != 0) && return out
    for i in 0:Int(count[]) - 1
        dev = Ref{Ptr{Cvoid}}(C_NULL)
        ccall(_nvml_fn(:nvmlDeviceGetHandleByIndex_v2), Cint, (Cuint, Ref{Ptr{Cvoid}}), i, dev) == 0 || continue
        d = dev[]
        name = get!(_NVML_NAMES, i) do
            buf = zeros(UInt8, 96)
            ccall(_nvml_fn(:nvmlDeviceGetName), Cint, (Ptr{Cvoid}, Ptr{UInt8}, Cuint), d, buf, 96) == 0 ?
                String(buf[1:something(findfirst(==(0x00), buf), 97) - 1]) : "GPU $i"
        end
        util = Ref{NTuple{2,Cuint}}((0, 0))                     # nvmlUtilization_t: gpu, memory
        u = ccall(_nvml_fn(:nvmlDeviceGetUtilizationRates), Cint, (Ptr{Cvoid}, Ref{NTuple{2,Cuint}}), d, util) == 0
        win = _nvml_util_window(i, d)
        mem = Ref{NTuple{3,UInt64}}((0, 0, 0))                  # nvmlMemory_t: total, free, used
        m = ccall(_nvml_fn(:nvmlDeviceGetMemoryInfo), Cint, (Ptr{Cvoid}, Ref{NTuple{3,UInt64}}), d, mem) == 0
        temp = Ref{Cuint}(0)                                    # NVML_TEMPERATURE_GPU = 0
        t = ccall(_nvml_fn(:nvmlDeviceGetTemperature), Cint, (Ptr{Cvoid}, Cint, Ref{Cuint}), d, 0, temp) == 0
        mw = Ref{Cuint}(0)
        p = ccall(_nvml_fn(:nvmlDeviceGetPowerUsage), Cint, (Ptr{Cvoid}, Ref{Cuint}), d, mw) == 0
        lim = Ref{Cuint}(0)
        pl = (f = _nvml_fn(:nvmlDeviceGetEnforcedPowerLimit); f !== nothing &&
              ccall(f, Cint, (Ptr{Cvoid}, Ref{Cuint}), d, lim) == 0)
        sm, smax = Ref{Cuint}(0), Ref{Cuint}(0)                   # NVML_CLOCK_SM = 1
        c1 = ccall(_nvml_fn(:nvmlDeviceGetClockInfo), Cint, (Ptr{Cvoid}, Cint, Ref{Cuint}), d, 1, sm) == 0
        c2 = ccall(_nvml_fn(:nvmlDeviceGetMaxClockInfo), Cint, (Ptr{Cvoid}, Cint, Ref{Cuint}), d, 1, smax) == 0
        thr = Ref{UInt64}(0)                                      # why the clocks are below their maximum
        tf = something(_nvml_fn(:nvmlDeviceGetCurrentClocksEventReasons),
                       _nvml_fn(:nvmlDeviceGetCurrentClocksThrottleReasons), Some(nothing))
        th = tf !== nothing && ccall(tf, Cint, (Ptr{Cvoid}, Ref{UInt64}), d, thr) == 0
        push!(out, (i = i, name = name,
                    util = win !== nothing ? win[1] : u ? Int(util[][1]) : -1,
                    util_max = win !== nothing ? win[2] : u ? Int(util[][1]) : -1,
                    mem_util = u ? Int(util[][2]) : -1,
                    mem_used = m ? Int64(mem[][3]) : Int64(-1), mem_total = m ? Int64(mem[][1]) : Int64(-1),
                    temp = t ? Int(temp[]) : -1, power_w = p ? round(mw[] / 1000; digits = 1) : -1.0,
                    power_limit_w = pl ? round(lim[] / 1000; digits = 1) : -1.0,
                    sm_mhz = c1 ? Int(sm[]) : -1, sm_max_mhz = c2 ? Int(smax[]) : -1,
                    throttle = th ? _throttle_names(thr[]) : String[],
                    proc_mem = _nvml_proc_mem(d, pid)))
    end
    return out
end

# NVML's clock-event reasons that say the GPU is held back, by name. Idle and application-clock
# settings are left out: they are not something slowing work down.
const _THROTTLE_BITS = ((0x0004, "power cap"), (0x0008, "slowdown"), (0x0020, "thermal (software)"),
                        (0x0040, "thermal (hardware)"), (0x0080, "power brake"), (0x0100, "display clocks"))
_throttle_names(bits::UInt64) = String[n for (b, n) in _THROTTLE_BITS if bits & b != 0]

# The readings as the JSON array the telemetry line carries.
function gpu_sample_json(gs)
    isempty(gs) && return "[]"
    q(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"")
    return "[" * join(("{\"i\":$(g.i),\"name\":\"$(q(g.name))\",\"util\":$(g.util),\"util_max\":$(g.util_max),\"mem_util\":$(g.mem_util)," *
                       "\"mem_used\":$(g.mem_used),\"mem_total\":$(g.mem_total),\"temp\":$(g.temp)," *
                       "\"power_w\":$(g.power_w),\"power_limit_w\":$(g.power_limit_w),\"sm_mhz\":$(g.sm_mhz)," *
                       "\"sm_max_mhz\":$(g.sm_max_mhz),\"throttle\":[" * join(("\"$(q(t))\"" for t in g.throttle), ",") * "]," *
                       "\"proc_mem\":$(g.proc_mem)}" for g in gs), ",") * "]"
end
