# Host, process and job figures for the telemetry sample, read from /proc and the process's cgroup on
# Linux. Each is one small file, so a whole sample costs about a millisecond; elsewhere the figures
# are absent. Rates (per-core CPU, I/O, network, allocation) are per second since the previous sample,
# so a `SysSampler` keeps the counters it last saw.

mutable struct SysSampler
    t::Float64                          # when the last counters were read
    cores::Vector{Tuple{Int,Int}}       # per core: (busy, total) jiffies
    net::Tuple{Int,Int}                 # (rx, tx) bytes, all interfaces but loopback
    io::Tuple{Int,Int}                  # (read, written) bytes, this process's storage I/O
    alloc::Int                          # bytes this process has allocated
    cg::String                          # the cgroup holding the nearest memory limit, "" when none
end
SysSampler() = SysSampler(0.0, Tuple{Int,Int}[], (-1, -1), (-1, -1), -1, _cgroup_dir())

_rd(path) = try; read(path, String); catch; ""; end

# A cpuset list ("0-15,64-79") as the core indices it names.
function _cpulist(s::AbstractString)
    out = Int[]
    for part in split(strip(s), ',', keepempty = false)
        ab = split(part, '-')
        a = tryparse(Int, ab[1]); b = length(ab) > 1 ? tryparse(Int, ab[2]) : a
        (a === nothing || b === nothing) || append!(out, a:b)
    end
    return out
end

# The cores the process may run on, from the nearest cgroup that sets a cpuset, as a scheduler's job
# does; empty when nothing narrows it.
function _cgroup_cpuset(dir::AbstractString)
    while startswith(dir, "/sys/fs/cgroup") && length(dir) > length("/sys/fs/cgroup")
        c = _cpulist(_rd(joinpath(dir, "cpuset.cpus.effective")))
        isempty(c) || return c
        dir = dirname(dir)
    end
    return Int[]
end
_num(s) = something(tryparse(Int, strip(s)), -1)

# The process's own cgroup (v2), walked up to the nearest one with a memory limit: on a cluster that
# is the job's allocation, the limit that actually ends a process, rather than the node's memory.
function _cgroup_dir()
    Sys.islinux() || return ""
    line = findfirst(l -> startswith(l, "0::"), split(_rd("/proc/self/cgroup"), '\n'))
    line === nothing && return ""
    rel = split(_rd("/proc/self/cgroup"), '\n')[line][4:end]
    dir = normpath("/sys/fs/cgroup" * rel)
    while startswith(dir, "/sys/fs/cgroup") && length(dir) > length("/sys/fs/cgroup")
        _num(_rd(joinpath(dir, "memory.max"))) > 0 && return dir
        dir = dirname(dir)
    end
    return ""
end

# avg10 of a pressure-stall line: the share of the last 10 s that work waited on the resource.
function _psi(res::AbstractString, which::AbstractString = "some")
    for l in eachline(IOBuffer(_rd("/proc/pressure/" * res)))
        startswith(l, which) || continue
        m = match(r"avg10=([0-9.]+)", l)
        return m === nothing ? -1.0 : parse(Float64, m.captures[1])
    end
    return -1.0
end

# macOS's own idea of available memory: free, inactive, speculative and purgeable pages, which it gives
# back on demand (`Sys.free_memory` counts free pages only, so a Mac always reads nearly full). From
# `host_statistics64(HOST_VM_INFO64)`; the offsets are those of `vm_statistics64` in mach/vm_statistics.h.
function _macos_mem_avail()
    buf = zeros(UInt8, 152)
    n = Ref{Cuint}(38)                                          # HOST_VM_INFO64_COUNT, in 32-bit words
    host = ccall(:mach_host_self, Cuint, ())
    ccall(:host_statistics64, Cint, (Cuint, Cint, Ptr{UInt8}, Ref{Cuint}), host, 4, buf, n) == 0 || return -1
    w(off) = Int(GC.@preserve buf unsafe_load(Ptr{UInt32}(pointer(buf, off + 1))))
    pages = w(0) + w(8) + w(88) + w(92)                         # free, inactive, purgeable, speculative
    return pages * Int(ccall(:getpagesize, Cint, ()))
end

_alloc_bytes() = try
    isdefined(Base, :gc_total_bytes) ? Int(Base.gc_total_bytes(Base.gc_num())) : Int(Base.gc_num().allocd)
catch
    -1
end

"""
    sys_sample!(s::SysSampler) -> NamedTuple

`(; host, proc, job)`, each a Dict of what this machine can say: per-core CPU, load, memory and
swap, pressure stall and network for the host; threads, file handles, I/O and allocation for this
process; the memory limit and use and CPU allowance of its cgroup for the job. Rates are per second.
"""
function sys_sample!(s::SysSampler)
    now = time()
    dt = s.t > 0 ? now - s.t : 0.0
    rate(cur, prev) = (dt > 0 && cur >= 0 && prev >= 0 && cur >= prev) ? round((cur - prev) / dt) : -1.0
    host = Dict{String,Any}(); proc = Dict{String,Any}(); job = Dict{String,Any}()
    proc["threads"] = Threads.nthreads()
    host["ncpu"] = Sys.CPU_THREADS         # every platform; `cores` below (per-core load) is Linux only
    a = _alloc_bytes()
    proc["alloc_rate"] = rate(a, s.alloc); s.alloc = a
    proc["heap"] = try; Int(Base.gc_live_bytes()); catch; -1; end
    Sys.isapple() && (host["mem_avail"] = try; _macos_mem_avail(); catch; -1; end)
    if Sys.islinux()
        cores = Tuple{Int,Int}[]
        for l in eachline(IOBuffer(_rd("/proc/stat")))
            (startswith(l, "cpu") && length(l) > 3 && isdigit(l[4])) || continue
            v = parse.(Int, split(l)[2:end])
            push!(cores, (sum(v) - v[4] - (length(v) >= 5 ? v[5] : 0), sum(v)))
        end
        if length(cores) == length(s.cores)
            host["cores"] = [(t - pt) > 0 ? round(100 * (b - pb) / (t - pt); digits = 1) : 0.0
                             for ((b, t), (pb, pt)) in zip(cores, s.cores)]
        end
        s.cores = cores
        la = split(_rd("/proc/loadavg"))
        length(la) >= 3 && (host["load5"] = parse(Float64, la[2]); host["load15"] = parse(Float64, la[3]))
        mi = Dict{String,Int}()
        for l in eachline(IOBuffer(_rd("/proc/meminfo")))
            m = match(r"^(\w+):\s+(\d+)", l); m === nothing || (mi[m.captures[1]] = parse(Int, m.captures[2]) * 1024)
        end
        host["mem_avail"] = get(mi, "MemAvailable", -1)
        host["mem_cached"] = get(mi, "Cached", -1)
        host["swap_used"] = get(mi, "SwapTotal", 0) - get(mi, "SwapFree", 0)
        host["psi_cpu"] = _psi("cpu"); host["psi_mem"] = _psi("memory"); host["psi_io"] = _psi("io")
        rx = tx = 0
        for l in Iterators.drop(eachline(IOBuffer(_rd("/proc/net/dev"))), 2)
            name, rest = split(l, ':'; limit = 2) .|> strip
            name == "lo" && continue
            f = split(rest); length(f) >= 9 || continue
            rx += parse(Int, f[1]); tx += parse(Int, f[9])
        end
        host["net_rx"] = rate(rx, s.net[1]); host["net_tx"] = rate(tx, s.net[2]); s.net = (rx, tx)
        io = Dict(m.captures[1] => parse(Int, m.captures[2])
                  for m in eachmatch(r"(read_bytes|write_bytes): (\d+)", _rd("/proc/self/io")))
        r, w = get(io, "read_bytes", -1), get(io, "write_bytes", -1)
        proc["io_read"] = rate(r, s.io[1]); proc["io_write"] = rate(w, s.io[2]); s.io = (r, w)
        proc["fds"] = try; length(readdir("/proc/self/fd")); catch; -1; end
        if !isempty(s.cg)
            job["mem_max"] = _num(_rd(joinpath(s.cg, "memory.max")))
            job["mem_cur"] = _num(_rd(joinpath(s.cg, "memory.current")))
            cm = split(_rd(joinpath(s.cg, "cpu.max")))
            (length(cm) == 2 && cm[1] != "max") && (job["cpus"] = round(parse(Int, cm[1]) / parse(Int, cm[2]); digits = 1))
            # A scheduler limits CPUs by a cpuset (which cores), not a quota: the count, and the cores
            # themselves so a view of a shared node can show this job's and leave out its neighbours'.
            own = _cgroup_cpuset(s.cg)
            if !isempty(own) && length(own) < length(cores)
                job["cpuset"] = own
                haskey(job, "cpus") || (job["cpus"] = length(own))
            end
        end
    end
    s.t = now
    return (; host, proc, job)
end

# A Dict of numbers (and number vectors) as a JSON object, for the telemetry line.
function sys_json(d::AbstractDict)
    val(v) = v isa AbstractVector ? "[" * join(string.(v), ",") * "]" : string(v)
    return "{" * join(("\"$k\":$(val(v))" for (k, v) in d), ",") * "}"
end
