# ── Cell profiler (shared: worker process AND in-process engine) ───────────────────────────────
# Profile one cell in whichever process runs it, so a region cell is sampled on its node and only
# the result crosses the wire. Included by worker.jl and engine.jl like worker_debug.jl.
#
# Two verbs. PREPARE compiles the cell's code without running it: the body becomes a function of
# the globals it reads, and `precompile` at the types of their current values compiles every call
# whose target is known at compile time. A PROFILE is armed for a cell, and its next ordinary run
# (`run_capture`, `_profiled`) is sampled: the run is the real one, so its output, bindings and
# memo entry are what any run would leave.
#
# The result is a tree keyed by SOURCE LINE, rooted at the cell's own lines: each node is one line
# of one function, so a function bar in the view is the run of sibling nodes sharing its function,
# split by line. Runtime dispatch, GC and compilation are marked on the line they happened under.

import Profile

const _PROF_LOCK = ReentrantLock()                 # the sample buffer is process-wide: one at a time
const _PROF_ARMED = Dict{String,Any}()             # cell id → its options, for its next run
const _PROF_RESULT = Dict{String,Any}()            # cell id → the last profile of it
const _PROF_STATE_LOCK = ReentrantLock()           # guards the two dicts above

# The tasks of the other cells running in this process while one is profiled, as task ids: their
# samples are theirs. The worker, which runs cells concurrently, sets this; the engine runs one at a time.
const _PROF_OTHER_TASKS = Ref{Any}(() -> UInt[])

# By default a sample every millisecond into a buffer of `_PROF_BUFFER` instruction pointers. A
# sample is its stack depth plus six words, so this holds a few minutes of one busy thread.
const _PROF_DELAY = 0.001
const _PROF_BUFFER = 4_000_000

"""
How a cell is profiled. `mode`: `cpu` (sampled on-CPU time), `wall` (every task, waiting ones
too), `alloc` (allocations, by bytes) or `gpu` (`cpu` plus CUDA.jl's record of the device's work).
`delay_ms` and `buffer` set the sampler; `trace` records what compiled during the run and which
calls were dispatched at runtime; `alloc_rate` is the share of allocations recorded.
"""
struct ProfOpts
    mode::String
    delay_ms::Float64
    buffer::Int
    trace::Bool
    alloc_rate::Float64
end

"Profile the next run of `cell` (see `ProfOpts`)."
function profile_arm!(cell::AbstractString, mode::AbstractString = "cpu"; delay_ms::Real = 1.0,
                      buffer::Integer = _PROF_BUFFER, trace::Bool = true, alloc_rate::Real = 0.001)
    o = ProfOpts(String(mode) in ("cpu", "wall", "alloc", "gpu") ? String(mode) : "cpu",
                 clamp(Float64(delay_ms), 0.1, 100.0), clamp(Int(buffer), 100_000, 100_000_000), trace,
                 clamp(Float64(alloc_rate), 1e-4, 1.0))
    # The last result goes now, so whatever `profile_result` returns after this run is this run's.
    lock(_PROF_STATE_LOCK) do; _PROF_ARMED[String(cell)] = o; delete!(_PROF_RESULT, String(cell)); end
    return true
end

profile_disarm!(cell::AbstractString) =
    (lock(_PROF_STATE_LOCK) do; delete!(_PROF_ARMED, String(cell)); end; true)

"The last profile taken of `cell`, or `nothing`."
profile_result(cell::AbstractString) = lock(_PROF_STATE_LOCK) do; get(_PROF_RESULT, String(cell), nothing); end

_profile_take(cid::AbstractString) = lock(_PROF_STATE_LOCK) do; pop!(_PROF_ARMED, String(cid), nothing); end

# Where in the sample buffer each statement of a profiled cell began, with its line. The buffer
# fills in the order samples are taken, so its length is a clock every thread's samples share: a
# sample on any thread falls in the statement running when it was taken.
function _prof_mark(line::Int)
    tls = task_local_storage()
    m = get(tls, :slate_prof_marks, nothing)
    m === nothing || push!(m, (Int(ccall(:jl_profile_len_data, Csize_t, ())), line))
    # Tracing waits for the first statement, so the cell's own parsing and printing are not in it.
    if get(tls, :slate_prof_trace, false) === true
        tls[:slate_prof_trace] = :on
        _trace_on()
    end
    return nothing
end

# Called by `run_capture` around a cell's evaluation. Unarmed, it is the evaluation.
function _profiled(f, cid::AbstractString; mod::Union{Module,Nothing} = nothing)
    o = _profile_take(cid)
    o === nothing && return f()
    return lock(_PROF_LOCK) do
        # The sample buffer is the process's: one a cell's own code started is not cleared from
        # under it. The cell runs unprofiled and the profile says why.
        if o.mode != "alloc" && ccall(:jl_profile_is_running, Cint, ()) != 0
            v = f()
            lock(_PROF_STATE_LOCK) do
                _PROF_RESULT[String(cid)] = Dict{String,Any}("cell" => String(cid), "mode" => o.mode, "at" => time(),
                    "error" => "a profile was already running in this process (the cell's own?); this run was not profiled")
            end
            return v
        end
        # CUDA is loaded before the clock starts, so its loading is not counted as the cell's.
        cuda = o.mode == "gpu" ? _cuda_module() : nothing
        saved = _profile_settings()
        Base.cumulative_compile_timing(true)
        c0 = Base.cumulative_compile_time_ns()[1]; g0 = Base.gc_num().total_time; t0 = time_ns()
        task = UInt(pointer_from_objref(current_task()))
        others = delete!(Set{UInt}(_PROF_OTHER_TASKS[]()), task)
        traced = Dict{String,Any}()
        gpu = Dict{String,Any}()
        facts() = (; opts = o, ms = (time_ns() - t0) / 1e6,
                     compile_ms = (Base.cumulative_compile_time_ns()[1] - c0) / 1e6,
                     gc_ms = (Base.gc_num().total_time - g0) / 1e6)
        marks = Tuple{Int,Int}[]
        store!(fx, err) = begin
            union!(others, _PROF_OTHER_TASKS[]()); delete!(others, task)
            r = o.mode == "alloc" ? _alloc_build(String(cid), task, fx; error = err, others = others) :
                                    _profile_build(String(cid), task, fx; error = err, others = others, marks = marks)
            merge!(r, traced)
            _trace_keep!(r, mod)
            isempty(gpu) || (r["gpu"] = gpu)
            lock(_PROF_STATE_LOCK) do; _PROF_RESULT[String(cid)] = r; end
        end
        run = o.trace ? () -> _traced(f, traced) : f
        local v
        task_local_storage(:slate_profiling, true)   # `_eval_cell_source` compiles the cell's statements
        task_local_storage(:slate_prof_marks, marks)
        done() = (Base.cumulative_compile_timing(false);
                  delete!(task_local_storage(), :slate_profiling); delete!(task_local_storage(), :slate_prof_marks))
        try
            if o.mode == "alloc"
                Profile.Allocs.clear()
                v = Profile.Allocs.@profile sample_rate = o.alloc_rate run()
            else
                Profile.clear(); Profile.init(n = o.buffer, delay = o.delay_ms / 1000)
                # GPU work is mostly the host waiting on the device, which a CPU-time sampler barely
                # sees (on Linux it ticks with the process's CPU time), so GPU mode samples wall time.
                v = o.mode == "wall" ? Profile.@profile_walltime(run()) :
                    o.mode == "gpu" ? _with_gpu(() -> Profile.@profile_walltime(run()), gpu, cuda) : Profile.@profile(run())
            end
        catch e
            fx = facts(); done()
            try; store!(fx, sprint(showerror, e)); catch; end
            _profile_release!(saved)
            rethrow()
        end
        fx = facts(); done()
        try
            store!(fx, nothing)
        catch e
            @warn "slate profile: could not build the profile" cell = cid exception = (e, catch_backtrace())
        end
        _profile_release!(saved)
        v
    end
end

# The sampler's settings before a profile, read without allocating a buffer: 0 entries means
# `Profile` has not set one up yet.
_profile_settings() = (Int(ccall(:jl_profile_maxlen_data, Csize_t, ())), ccall(:jl_profile_delay_nsec, UInt64, ()) / 1e9)

# Afterwards the samples go and the sampler is set back as it was, so the cell's own `@profile`
# later gets the buffer it would have had. Never set up before: `Profile`'s default.
function _profile_release!(saved)
    Profile.clear()
    n, delay = saved
    if n > 0
        Profile.init(n = n, delay = delay)
    elseif isdefined(Profile, :default_init)
        Profile.default_init()
    else
        Profile.init(n = 10_000_000, delay = _PROF_DELAY)
    end
    try; Profile.Allocs.clear(); catch; end
    return nothing
end

# ── what compiled, and what dispatched at runtime ───────────────────────────────────────────────
# Julia reports both when asked (`@trace_compile`, `@trace_dispatch`): a compiled method with how
# long it took, and each signature a call had to be dispatched on at runtime.
#
# The runtime writes them to whatever its stderr was the first time it traced, kept in a static for
# the life of the process. So the first trace is taken with that stderr pointed at a file this
# process keeps open, and the real stderr is put back at once: from then on tracing writes only
# there, only while a profiled run has it on, and a run reads what was added during it. Nothing is
# redirected while the cell runs. If something traced before the profiler did, the static holds the
# real stderr and the lists come back empty.
const _TRACE_PRIMED = Threads.Atomic{Bool}(false)
const _TRACE_IO = Ref{Any}(nothing)
const _TRACE_PATH = Ref("")

_trace_on() = (ccall(:jl_force_trace_compile_timing_enable, Cvoid, ()); ccall(:jl_force_trace_dispatch_enable, Cvoid, ()))
_trace_off() = (ccall(:jl_force_trace_dispatch_disable, Cvoid, ()); ccall(:jl_force_trace_compile_timing_disable, Cvoid, ()))

function _prime_trace!()
    _TRACE_PRIMED[] && return
    path, io = mktemp()
    uv = cglobal(:jl_uv_stderr, Ptr{Cvoid})
    old = unsafe_load(uv)
    unsafe_store!(uv, io.handle)
    try
        _trace_on()
        # A fresh function, called through the runtime: one compile and one dispatch, so both
        # statics are set while the runtime's stderr is the file.
        Base.invokelatest(Core.eval(@__MODULE__, :(x -> x + 1)), 1)
    finally
        _trace_off()
        unsafe_store!(uv, old)
    end
    flush(io); truncate(io, 0); seekstart(io)
    _TRACE_IO[] = io; _TRACE_PATH[] = path
    _TRACE_PRIMED[] = true
    return
end

function _traced(f, out::Dict{String,Any})
    _prime_trace!()
    io = _TRACE_IO[]
    flush(io); truncate(io, 0); seekstart(io)
    tls = task_local_storage()
    tls[:slate_prof_trace] = true          # turned on by the first statement (`_prof_mark`)
    try
        return f()
    finally
        get(tls, :slate_prof_trace, false) === :on && _trace_off()
        delete!(tls, :slate_prof_trace)
        flush(io)
        _read_trace!(out, _TRACE_PATH[])
        truncate(io, 0); seekstart(io)
    end
end

# A method of the profiler or the worker: its signature starts with its function's type.
const _OWN_SIG = r"^Tuple\{(?:typeof\()?(?:Core\.)?(?:SlateWorker|ReportEngine|KaimonSlate|KaimonGate)\."

# Tracing is process-wide, so the lists also hold what other work in the process compiled and
# dispatched during the run (documentation lookups, serializing results). Kept: signatures whose
# modules all appear in the cell's own profile, or are Base, Core or the notebook's.
function _trace_keep!(r::Dict{String,Any}, mod)
    haskey(r, "compiled") || return r
    seen = Set{String}(String(x) for x in get(r, "strings", String[]))
    union!(seen, ("Base", "Core", "Main"))
    mod === nothing || union!(seen, split(string(mod), '.'))
    ok(sig) = all(m -> m.captures[1] in seen, eachmatch(r"(?<![\w.])([A-Z][A-Za-z0-9_]*)\.", sig))
    for (k, n) in (("compiled", "compiled_n"), ("dispatched", "dispatched_n"))
        before = r[k]
        r[k] = filter(x -> ok(String(x[1])), before)
        r[n] = max(0, r[n] - (length(before) - length(r[k])))
    end
    return r
end

function _read_trace!(out::Dict{String,Any}, path::AbstractString)
    compiled = Dict{String,Vector{Float64}}(); dispatched = Dict{String,Int}()   # signature → [count, ms]
    for l in eachline(path)
        m = match(r"^#=\s*([\d.]+)\s*ms\s*=#\s*precompile\((.*)\)(?:\s*#.*)?$", l)
        # The profiler's and the worker's own calls are not the cell's, and a line two threads wrote
        # into at once is not a signature.
        count(==('{'), l) == count(==('}'), l) && count(==('('), l) == count(==(')'), l) || continue
        if m !== nothing
            occursin(_OWN_SIG, m.captures[2]) && continue
            c = get!(() -> [0.0, 0.0], compiled, String(m.captures[2]))
            c[1] += 1; c[2] += parse(Float64, m.captures[1])
        elseif (m2 = match(r"^precompile\((.*)\)(?:\s*#.*)?$", l)) !== nothing
            occursin(_OWN_SIG, m2.captures[1]) && continue
            dispatched[String(m2.captures[1])] = get(dispatched, String(m2.captures[1]), 0) + 1
        end
    end
    # The same method compiled on several threads at once is one entry, with how often and how long.
    rows = sort!(collect(compiled); by = x -> -x[2][2])
    out["compiled"] = [[s, round(c[2]; digits = 2), Int(c[1])] for (s, c) in Iterators.take(rows, 300)]
    out["compiled_n"] = length(compiled)
    out["dispatched"] = [[s, n] for (s, n) in Iterators.take(sort!(collect(dispatched); by = x -> -x[2]), 300)]
    out["dispatched_n"] = length(dispatched)
    return out
end

# ── the GPU ─────────────────────────────────────────────────────────────────────────────────────
const _CUDA_ID = Base.PkgId(Base.UUID("052768ef-5323-5732-b1bb-66c8b64840ba"), "CUDA")

# CUDA.jl, loaded if it is not yet (a fresh worker, before the cell's own `using CUDA`) and the
# notebook's environment has it, so its profiler can wrap the whole run. `nothing` without it.
function _cuda_module()
    m = get(Base.loaded_modules, _CUDA_ID, nothing)
    m === nothing || return m
    return try; Base.require(_CUDA_ID); catch; nothing; end
end

# `f` under CUDA.jl's own profiler: the device's kernels and copies, summed by name, land in `out`.
# Without CUDA it is `f`, and `out` says why. The cell's own error is the run's; if the profiler
# fails before the cell starts, the cell runs without it.
function _with_gpu(f, out::Dict{String,Any}, m)
    m === nothing && (out["error"] = "CUDA is not in this notebook's environment"; return f())
    val = Ref{Any}(nothing); started = Ref(false); finished = Ref(false)
    body = () -> (started[] = true; val[] = f(); finished[] = true; nothing)
    res = try
        Base.invokelatest(Core.eval, Main,
            Expr(:macrocall, GlobalRef(m, Symbol("@profile")), LineNumberNode(0), Expr(:call, body)))
    catch e
        started[] && !finished[] && rethrow()
        out["error"] = first(sprint(showerror, e), 300)
        return started[] ? val[] : f()
    end
    try
        # CUDA.jl hands its device trace back as columns by name (a NamedTuple of vectors).
        dev = Base.invokelatest(getproperty, res, :device)
        col(k) = Base.invokelatest(getproperty, dev, k)
        names = String.(col(:name))
        dur = Float64.(col(:stop)) .- Float64.(col(:start))
        agg = Dict{String,Vector{Float64}}()
        for (n, d) in zip(names, dur)
            a = get!(() -> [0.0, 0.0], agg, n); a[1] += 1; a[2] += d
        end
        rows = sort!([(n, a[1], a[2]) for (n, a) in agg]; by = x -> -x[3])
        out["kernels"] = [[n, Int(c), round(t * 1000; digits = 3)] for (n, c, t) in Iterators.take(rows, 200)]
        out["device_ms"] = round(sum(dur; init = 0.0) * 1000; digits = 3)
    catch e
        out["error"] = "could not read CUDA's profile: " * first(sprint(showerror, e), 200)
    end
    return val[]
end

# ── samples ─────────────────────────────────────────────────────────────────────────────────────
# `Profile.fetch(include_meta = true)` is a flat buffer of blocks: a sample's instruction pointers,
# leaf first, then its metadata (thread, task, clock, sleep state), then two zeros. `Profile`'s own
# offsets and block-end test read it, so this holds across Julia versions that keep them.

struct _Sample
    ips::UnitRange{Int}
    thread::UInt
    task::UInt
    clock::UInt
    awake::Bool
end

function _profile_samples(data::Vector{UInt})
    out = _Sample[]
    start = 1
    for i in eachindex(data)
        Profile.is_block_end(data, i) || continue
        ipend = i - Profile.nmeta - 2
        sleeping = data[i - Profile.META_OFFSET_SLEEPSTATE] == 2   # stored as state + 1
        push!(out, _Sample(start:ipend, data[i - Profile.META_OFFSET_THREADID],
                           data[i - Profile.META_OFFSET_TASKID], data[i - Profile.META_OFFSET_CPUCYCLECLOCK],
                           !sleeping))
        start = i + 1
    end
    return out
end

# ── frames ──────────────────────────────────────────────────────────────────────────────────────

const _DISPATCH_C = ("jl_apply_generic", "ijl_apply_generic", "jl_invoke", "ijl_invoke")
_gc_c(f::AbstractString) = startswith(f, "jl_gc_") || startswith(f, "ijl_gc_") || startswith(f, "gc_") ||
                           startswith(f, "_jl_gc") || f == "jl_safepoint_wait_gc"
_compile_c(f::AbstractString) = any(p -> startswith(f, p),
    ("jl_compile", "ijl_compile", "jl_type_infer", "ijl_type_infer", "jl_generate_fptr", "ijl_generate_fptr",
     "jl_emit_", "jl_add_to_ee", "jl_codegen", "jl_expand", "ijl_expand", "jl_macroexpand", "ijl_macroexpand",
     "jl_lower", "ijl_lower", "fl_", "jl_fl_", "jl_parse", "ijl_parse"))

# A frame's file. Compiled top-level code reports a cell's as `./cell:<id>`.
_ffile(fr) = (f = string(fr.file); startswith(f, "./cell:") ? f[3:end] : f)

function _frame_module(fr)
    li = fr.linfo
    try
        li isa Core.CodeInstance && (li = li.def)
        li isa Core.MethodInstance && (li = li.def)
        li isa Method && return li.module
        li isa Module && return li
    catch
    end
    return nothing
end

# What a frame belongs to, for colour and folding: this cell, another cell of the notebook, or the
# top module of the package (Base and Core read as Base). A frame with no method falls back to its
# path.
function _frame_pkg(fr, cellfile::AbstractString)
    f = _ffile(fr)
    f == cellfile && return "cell"
    startswith(f, "cell:") && return "notebook"
    m = _frame_module(fr)
    if m !== nothing
        r = Base.moduleroot(m)
        _in_compiler(m) && return "Compiler"
        (r === Base || r === Core) && return "Base"
        return string(nameof(r))
    end
    occursin("/stdlib/", f) && (m2 = match(r"/stdlib/(?:v[\d.]+/)?([A-Za-z0-9_]+)/", f); m2 !== nothing) && return m2.captures[1]
    m3 = match(r"/(?:packages|dev)/([A-Za-z0-9_]+)/", f); m3 !== nothing && return m3.captures[1]
    (startswith(f, "./") || occursin("/base/", f)) && return "Base"
    return "?"
end

_compiler_pkg(pkg::AbstractString) = pkg == "Compiler"

# Inference and codegen, wherever this Julia keeps them (`Core.Compiler`, or a `Compiler` module).
function _in_compiler(m::Module)
    while true
        nameof(m) === :Compiler && return true
        p = parentmodule(m)
        p === m && return false
        m = p
    end
end

# The process's own work, never the cell's: the gate, the telemetry and blob channels, file
# watching. A sample from one of these with no frame of the cell is the worker going about its day.
const _INFRA_PKGS = ("KaimonGate", "ZMQ", "SlateWorker", "KaimonSlate", "Revise", "FileWatching",
                     "Sockets", "HTTP")

# A package the user is working on rather than one installed for them: loaded from anywhere but a
# depot's `packages/` or Julia's own tree (a `dev`ed or path package). The view does not fold these.
_user_pkg(pkg::AbstractString, file::AbstractString) =
    !(pkg in ("cell", "notebook", "Base", "Compiler", "?", "")) && isabspath(file) &&
    !occursin("/packages/", file) && !occursin("/share/julia/", file) && !occursin("/stdlib/", file)

# Where a task waits for work it handed to others: the caller of the first of these is where that
# work is drawn.
const _WAIT_FNS = (:threading_run, :wait, :_wait, :_wait2, :fetch, :sync_end, :take!, :wait_forever)

# ── the tree ────────────────────────────────────────────────────────────────────────────────────

const _K_LINE, _K_COMPILE, _K_GC, _K_OTHER, _K_SYNTH = 0, 1, 2, 3, 4

mutable struct _ProfTree
    strings::Vector{String}
    sidx::Dict{String,Int}
    parent::Vector{Int}; file::Vector{Int}; line::Vector{Int}; func::Vector{Int}; pkg::Vector{Int}
    kind::Vector{Int}; total::Vector{Int}; self::Vector{Int}
    dispatch::Vector{Int}; gc::Vector{Int}; compile::Vector{Int}
    child::Dict{Tuple{Int,Int,Int,Int,Int},Int}      # (parent, file, line, func, kind) → node
end
_ProfTree() = _ProfTree(String[], Dict{String,Int}(), Int[], Int[], Int[], Int[], Int[], Int[], Int[], Int[],
                        Int[], Int[], Int[], Dict{Tuple{Int,Int,Int,Int,Int},Int}())

_str!(t::_ProfTree, s::AbstractString) = get!(t.sidx, String(s)) do
    push!(t.strings, String(s)); length(t.strings)
end

function _node!(t::_ProfTree, parent::Int, file::AbstractString, line::Int, func::AbstractString,
                pkg::AbstractString, kind::Int)
    f, fn = _str!(t, file), _str!(t, func)
    return get!(t.child, (parent, f, line, fn, kind)) do
        push!(t.parent, parent); push!(t.file, f); push!(t.line, line); push!(t.func, fn)
        push!(t.pkg, _str!(t, pkg)); push!(t.kind, kind)
        push!(t.total, 0); push!(t.self, 0); push!(t.dispatch, 0); push!(t.gc, 0); push!(t.compile, 0)
        length(t.parent)
    end
end

# One profile's tree being built, and what the samples said beside it.
mutable struct _Acc
    t::_ProfTree
    cellfile::String
    lines::Dict{Tuple{Int,Int},Vector{Int}}    # (file, line) → [incl, self, dispatch, gc, compile]
    pkgfile::Dict{String,String}                # package → a file of it, to tell the user's own
    seen::Set{Tuple{Int,Int}}
    path::Vector{Int}; pathfn::Vector{Symbol}   # the line nodes the last path went through
    alloc::Bool                                 # stacks of allocations, which end in the allocator
end
_Acc(t, cellfile; alloc = false) = _Acc(t, cellfile, Dict{Tuple{Int,Int},Vector{Int}}(), Dict{String,String}(),
                                        Set{Tuple{Int,Int}}(), Int[], Symbol[], alloc)
_lrow(a::_Acc, key) = get!(() -> zeros(Int, 5), a.lines, key)

"""
    _add!(acc, frames, start, cur, w) -> Int

Add one stack, `frames` root first, below node `cur`, from `frames[start]` on, with weight `w` (a
sample, or an allocation's bytes). Every node above `cur` holds it too. The runtime's own frames
are not nodes: under a dispatch they mark the line above them, and garbage collection or
compilation end the path in a node of their own. Returns the node the path ended in.
"""
function _add!(a::_Acc, frames, start::Int, cur::Int, w::Int)
    t = a.t
    empty!(a.seen); empty!(a.path); empty!(a.pathfn)
    x = cur
    while x > 0
        t.total[x] += w
        if t.kind[x] == _K_LINE
            key = (t.file[x], t.line[x])
            key in a.seen || (push!(a.seen, key); _lrow(a, key)[1] += w)
        end
        x = t.parent[x]
    end
    leaf = (0, 0)
    mark!(k) = leaf[1] > 0 && (_lrow(a, leaf)[k] += w)
    for j in start:length(frames)
        fr = frames[j]
        if fr.from_c
            fn = string(fr.func)
            if fn in _DISPATCH_C
                t.dispatch[cur] += w; mark!(3)
            elseif _gc_c(fn)
                a.alloc && continue          # the allocation itself, not a collection
                t.gc[cur] += w; mark!(4)
                cur = _node!(t, cur, "", 0, "garbage collection", "", _K_GC); t.total[cur] += w
                break
            elseif _compile_c(fn)
                t.compile[cur] += w; mark!(5)
                cur = _node!(t, cur, "", 0, "compilation", "", _K_COMPILE); t.total[cur] += w
                break
            end
            continue
        end
        pkg = _frame_pkg(fr, a.cellfile)
        haskey(a.pkgfile, pkg) || (a.pkgfile[pkg] = _ffile(fr))
        # A task switched out in the scheduler is waiting (a wall-time sample of one): the path
        # ends where the scheduler's own frames begin, under the call that waits.
        if pkg == "Base" && _parked_tail(frames, j)
            cur = _node!(t, cur, "", 0, "waiting", "", _K_SYNTH); t.total[cur] += w
            break
        end
        if _compiler_pkg(pkg)
            t.compile[cur] += w; mark!(5)
            cur = _node!(t, cur, "", 0, "compilation", "", _K_COMPILE); t.total[cur] += w
            break
        end
        file = _ffile(fr); ln = Int(fr.line)
        cur = _node!(t, cur, file, ln, string(fr.func), pkg, _K_LINE)
        t.total[cur] += w
        push!(a.path, cur); push!(a.pathfn, fr.func)
        key = (_str!(t, file), ln)
        key in a.seen || (push!(a.seen, key); _lrow(a, key)[1] += w)
        leaf = key
    end
    t.self[cur] += w
    leaf[1] > 0 && (_lrow(a, leaf)[2] += w)
    return cur
end

const _PARKED_FNS = (:wait, :_wait, :_wait2, :try_yieldto, :yieldto, :poptask, :wait_forever, :task_get_next)
# From `j` on, nothing but the scheduler's waiting and the runtime under it. A parked task's stack
# ends inside its `wait`, so that is enough.
_parked_tail(frames, j) =
    frames[j].func in _PARKED_FNS && all(k -> frames[k].from_c || frames[k].func in _PARKED_FNS, j:length(frames))

# Only the runtime and Base's scheduler from `start` on, waiting in it: a task with nothing to do.
const _SCHED_FNS = (:wait, :poptask, :task_get_next, :try_yieldto, :wait_forever, :yield)
_scheduling(frames, start, cellfile) =
    !any(j -> (fr = frames[j]; fr.from_c ? (_gc_c(string(fr.func)) || _compile_c(string(fr.func))) :
                                           !(_frame_pkg(fr, cellfile) in ("Base", "Compiler"))), start:length(frames)) &&
    any(j -> frames[j].func in _SCHED_FNS || occursin("task_get_next", string(frames[j].func)), start:length(frames))

# A task another cell started: its outermost notebook code (`frames` root first) is another cell's.
# A helper from another cell called by this one is further in. Only a parked one is left out (a
# background loop a cell left behind, which wall time samples every tick): a running one may be
# this cell's work handed to a function another cell defined, which looks the same.
function _other_cells(frames, cellfile)
    i = findfirst(fr -> startswith(_ffile(fr), "cell:"), frames)
    return i !== nothing && _ffile(frames[i]) != cellfile
end
_parked(frames) = !isempty(frames) && (j = findlast(fr -> !fr.from_c, frames); j !== nothing && _parked_tail(frames, j))

# Where work running now belongs in the cell: the call its task last waited in during this
# statement, else the statement's line, else the cell.
function _statement_node(t, root, cellfile, graft, graftat, stmt0, marks, mi)
    graft > 0 && graftat >= stmt0 && return graft
    mi > 0 && marks[mi][2] > 0 && return _node!(t, root, cellfile, marks[mi][2], "top-level scope", "cell", _K_LINE)
    return root
end

# Where a stack outside the cell's own code starts saying something: past the task entry, and on
# the cell's task past the evaluation machinery that brought it there (`_eval_cell_source`, `eval`).
# The runtime's frames stay, so compiling and collecting are recognised.
function _outside_start(frames, cellfile)
    ev = findlast(fr -> fr.func === :_eval_cell_source, frames)
    # Not evaluating yet (parsing the cell, say): past the last of the worker's own frames.
    ev === nothing && (ev = findlast(fr -> !fr.from_c && _frame_pkg(fr, cellfile) in _INFRA_PKGS, frames))
    s = ev === nothing ? 1 : ev + 1
    while s <= length(frames) && !frames[s].from_c &&
          (frames[s].func === :eval || _frame_pkg(frames[s], cellfile) in _INFRA_PKGS)
        s += 1
    end
    return s
end

"""
    _profile_build(cid, task, facts; error, others, marks) -> Dict

Turn the sample buffer into the line-keyed tree for cell `cid`, whose evaluation ran on `task`.

Which samples are the cell's: those of its task, and those of any other task that is not another
cell's (`others`), not the worker's own, and not a thread waiting for work. Work the cell hands to
other tasks belongs under the call that handed it out; a task waiting on that work leaves no
samples, so it goes where the cell's task last was in the same statement (inside the `@threads`
loop, the `fetch`), or else on the statement's line, which `marks` give by buffer position: the
buffer fills in the order samples are taken. In wall-time mode a waiting task is sampled too, and
its waiting is time like any other.
"""
function _profile_build(cid::String, task::UInt, facts; error = nothing, others::Set{UInt} = Set{UInt}(),
                        marks::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[])
    wall = facts.opts.mode in ("wall", "gpu")
    data = Profile.fetch(include_meta = true, limitwarn = false)   # a full buffer is reported as `buffer_full`
    lidict = Profile.getdict(data)
    cellfile = "cell:" * cid
    t = _ProfTree(); a = _Acc(t, cellfile)
    root = _node!(t, 0, cellfile, 0, "cell " * cid, "cell", _K_SYNTH)
    toplevel = 0; spare = 0
    dropped = Dict{String,Int}("idle" => 0, "other cells" => 0, "worker" => 0)
    kept = 0; threads = Set{UInt}()
    tl_thread = UInt[]; tl_clock = UInt[]; tl_node = Int[]
    frames = Base.StackTraces.StackFrame[]
    graft = 0; graftat = 0; mi = 0
    samples = _profile_samples(data)
    # The run's span on the sampler's clock, from every sample (idle ones too), for the timeline.
    cspan = isempty(samples) ? (UInt(0), UInt(0)) : extrema(s -> s.clock, samples)
    for s in samples
        while mi < length(marks) && marks[mi + 1][1] < first(s.ips); mi += 1; end
        stmt0 = mi == 0 ? 0 : marks[mi][1]
        (s.awake || wall) || (dropped["idle"] += 1; continue)
        s.task in others && (dropped["other cells"] += 1; continue)
        empty!(frames)
        for k in s.ips   # leaf first; each ip may expand to several inlined frames, innermost first
            append!(frames, get(lidict, data[k], Base.StackTraces.StackFrame[]))
        end
        reverse!(frames)                                  # root first
        own = s.task == task
        cidx = own ? findfirst(fr -> _ffile(fr) == cellfile, frames) : nothing
        if own && cidx !== nothing
            cur = root; start = cidx
        elseif own
            start = _outside_start(frames, cellfile)
            if all(fr -> fr.from_c, frames)
                # Interrupted inside the runtime where the stack cannot be unwound (thread-local
                # lookups, memory copies): only the innermost frame or two were recorded. Which
                # statement was running is still known.
                cur = _node!(t, _statement_node(t, root, cellfile, graft, graftat, stmt0, marks, mi),
                             "", 0, "runtime (stack not recorded)", "", _K_SYNTH)
                start = length(frames) + 1
            elseif _scheduling(frames, start, cellfile)
                # The cell's task waiting on work it handed out: its thread runs the scheduler
                # meanwhile, as the same task. Shown as waiting, under the call that waits.
                cur = _node!(t, _statement_node(t, root, cellfile, graft, graftat, stmt0, marks, mi),
                             "", 0, "waiting", "", _K_SYNTH)
                start = length(frames) + 1
            elseif mi > 0 && marks[mi][2] > 0
                # A statement the interpreter runs (a `using`, a definition) leaves no frame of its
                # own, but which one was running is known.
                cur = _node!(t, root, cellfile, marks[mi][2], "top-level scope", "cell", _K_LINE)
            else
                toplevel == 0 && (toplevel = _node!(t, root, cellfile, 0, "top level", "cell", _K_SYNTH))
                cur = toplevel
            end
        else
            any(fr -> !fr.from_c && _frame_pkg(fr, cellfile) in _INFRA_PKGS, frames) &&
                (dropped["worker"] += 1; continue)
            _other_cells(frames, cellfile) && _parked(frames) && (dropped["other cells"] += 1; continue)
            # From the first frame of real work: past the task entry and Base's scheduling. A thread
            # with nothing else on it is waiting for work.
            start = findfirst(fr -> !fr.from_c && !(_frame_pkg(fr, cellfile) in ("Base", "Compiler")), frames)
            start === nothing && (dropped["idle"] += 1; continue)
            if graft > 0 && graftat >= stmt0
                cur = graft
            elseif mi > 0 && marks[mi][2] > 0
                cur = _node!(t, root, cellfile, marks[mi][2], "top-level scope", "cell", _K_LINE)
            else
                spare == 0 && (spare = _node!(t, root, "", 0, "other threads", "", _K_SYNTH))
                cur = spare
            end
        end
        kept += 1; push!(threads, s.thread)
        leafnode = _add!(a, frames, start, cur, 1)
        push!(tl_thread, s.thread); push!(tl_clock, s.clock); push!(tl_node, leafnode)
        # Where work handed out now would hang: the frame that waits for it, else the cell's line.
        if own && cidx !== nothing && !isempty(a.path)
            w = findfirst(in(_WAIT_FNS), a.pathfn)
            graft = w === nothing ? a.path[1] : a.path[max(1, w - 1)]; graftat = first(s.ips)
        end
    end
    r, tree = _profile_result(a, cid, facts, kept; error, unit = "samples")
    # Compile time from the cell's own samples: the process counter also counts what other work in
    # the process compiled meanwhile.
    cs = sum((t.total[i] for i in eachindex(t.kind) if t.kind[i] == _K_COMPILE); init = 0)
    r["compile_ms"] = kept > 0 ? round(facts.ms * cs / kept; digits = 1) : 0.0
    r["compile_ms_process"] = round(facts.compile_ms; digits = 1)
    r["dropped"] = dropped; r["threads"] = length(threads)
    r["buffer_full"] = try; Profile.is_buffer_full(); catch; false; end
    r["timeline"] = _timeline(tl_thread, tl_clock, tl_node, tree.map, facts.ms, facts.opts.delay_ms, cspan)
    return r
end

"""
    _alloc_build(cid, task, facts; error, others) -> Dict

The allocations a profile recorded (a sampled share of them), as the same line-keyed tree weighted
by bytes, with a table of what was allocated: type, count and bytes, scaled back up by the share.
"""
function _alloc_build(cid::String, task::UInt, facts; error = nothing, others::Set{UInt} = Set{UInt}())
    res = Profile.Allocs.fetch()
    cellfile = "cell:" * cid
    t = _ProfTree(); a = _Acc(t, cellfile; alloc = true)
    root = _node!(t, 0, cellfile, 0, "cell " * cid, "cell", _K_SYNTH)
    toplevel = 0; spare = 0
    dropped = Dict{String,Int}("other cells" => 0, "worker" => 0)
    kept = 0; bytes = 0
    types = Dict{String,Vector{Int}}()
    frames = Base.StackTraces.StackFrame[]
    for al in res.allocs
        tk = UInt(al.task)
        tk in others && (dropped["other cells"] += 1; continue)
        empty!(frames); append!(frames, al.stacktrace); reverse!(frames)
        own = tk == task
        cidx = findfirst(fr -> _ffile(fr) == cellfile, frames)
        if cidx !== nothing
            cur = root; start = cidx
        elseif own
            start = _outside_start(frames, cellfile)
            toplevel == 0 && (toplevel = _node!(t, root, cellfile, 0, "top level", "cell", _K_SYNTH))
            cur = toplevel
        else
            any(fr -> !fr.from_c && _frame_pkg(fr, cellfile) in _INFRA_PKGS, frames) &&
                (dropped["worker"] += 1; continue)
            start = something(findfirst(fr -> !fr.from_c, frames), 1)
            spare == 0 && (spare = _node!(t, root, "", 0, "other threads", "", _K_SYNTH))
            cur = spare
        end
        kept += 1; bytes += al.size
        _add!(a, frames, start, cur, Int(al.size))
        ty = types[string(al.type)] = get(types, string(al.type), [0, 0])
        ty[1] += 1; ty[2] += al.size
    end
    r, _ = _profile_result(a, cid, facts, bytes; error, unit = "bytes")
    k = 1 / facts.opts.alloc_rate
    r["allocs"] = kept; r["dropped"] = dropped; r["threads"] = 0
    r["alloc_rate"] = facts.opts.alloc_rate
    r["types"] = [[ty, round(Int, c * k), round(Int, b * k)]
                  for (ty, (c, b)) in Iterators.take(sort!(collect(types); by = x -> -x[2][2]), 200)]
    return r
end

function _profile_result(a::_Acc, cid::String, facts, total::Int; error = nothing, unit = "samples")
    tree = _profile_prune(a.t, total)
    L = a.lines
    return Dict{String,Any}(
        "cell" => cid, "mode" => facts.opts.mode, "unit" => unit, "samples" => total,
        "duration_ms" => round(facts.ms; digits = 1),
        "compile_ms" => round(facts.compile_ms; digits = 1), "gc_ms" => round(facts.gc_ms; digits = 1),
        "delay_ms" => facts.opts.delay_ms, "error" => error, "at" => time(),
        "strings" => tree.strings, "nodes" => tree.nodes,
        "mine" => sort!([p for (p, f) in a.pkgfile if _user_pkg(p, f)]),
        "lines" => Dict{String,Any}(
            "file" => [k[1] for k in keys(L)], "line" => [k[2] for k in keys(L)],
            "incl" => [v[1] for v in values(L)], "self" => [v[2] for v in values(L)],
            "dispatch" => [v[3] for v in values(L)], "gc" => [v[4] for v in values(L)],
            "compile" => [v[5] for v in values(L)])), tree
end

# Every kept sample in time order, for the timeline: its thread (numbered from 1), when (ms from the
# first sample, scaled from the sampler's clock to the run's length) and the node it ended in. A
# long run is thinned to about `_TL_MAX` samples, every `step`-th of each thread's.
const _TL_MAX = 150_000
function _timeline(thread, clock, node, map, ms, delay, cspan = (minimum(clock; init = UInt(0)), maximum(clock; init = UInt(0))))
    n = length(node)
    n == 0 && return Dict{String,Any}("thread" => Int[], "t" => Float64[], "node" => Int[], "step_ms" => delay)
    step = max(1, cld(n, _TL_MAX))
    seen = Dict{UInt,Int}()
    ix = [i for i in 1:n if (seen[thread[i]] = get(seen, thread[i], -1) + 1) % step == 0]
    c0, c1 = cspan
    span = c1 > c0 ? Float64(c1 - c0) : 1.0
    tids = sort!(unique(thread)); tnum = Dict(t => i for (i, t) in enumerate(tids))
    return Dict{String,Any}(
        "thread" => [tnum[thread[i]] for i in ix],
        "t" => [round((clock[i] - c0) / span * ms; digits = 2) for i in ix],
        "node" => [map[node[i]] for i in ix],
        "step_ms" => delay * step)
end

# Below this share of the samples a node is folded into an "other" sibling, so a deep library
# stack sent from a compute node stays small. The line table is not pruned: it is one row per line.
const _PROF_KEEP = 0.001

# Also returns, for every node built, the node it is shown as: itself, or the "other" it folded into.
function _profile_prune(t::_ProfTree, kept::Int)
    n = length(t.parent)
    floor_ = max(1, ceil(Int, _PROF_KEEP * kept))
    keep = falses(n); n >= 1 && (keep[1] = true)
    for i in 2:n
        keep[i] = t.total[i] >= floor_ && keep[t.parent[i]]   # parents precede children
    end
    newid = zeros(Int, n)
    cols = Dict{String,Vector{Int}}(k => Int[] for k in
        ("parent", "file", "line", "func", "pkg", "kind", "total", "self", "dispatch", "gc", "compile"))
    other = Dict{Int,Int}()        # kept parent (new id) → its "other" node (new id)
    add!(p, f, l, fn, pk, k, tot, sf, d, g, c) = begin
        push!(cols["parent"], p); push!(cols["file"], f); push!(cols["line"], l); push!(cols["func"], fn)
        push!(cols["pkg"], pk); push!(cols["kind"], k); push!(cols["total"], tot); push!(cols["self"], sf)
        push!(cols["dispatch"], d); push!(cols["gc"], g); push!(cols["compile"], c)
        length(cols["parent"])
    end
    oname = _str!(t, "(other)"); empty_ = _str!(t, "")
    map = zeros(Int, n)
    for i in 1:n
        if keep[i]
            newid[i] = add!(i == 1 ? 0 : newid[t.parent[i]], t.file[i], t.line[i], t.func[i], t.pkg[i],
                            t.kind[i], t.total[i], t.self[i], t.dispatch[i], t.gc[i], t.compile[i])
            map[i] = newid[i]
        elseif keep[t.parent[i]]
            p = newid[t.parent[i]]
            o = get!(other, p) do
                add!(p, empty_, 0, oname, empty_, _K_OTHER, 0, 0, 0, 0, 0)
            end
            cols["total"][o] += t.total[i]
            cols["self"][o] += t.total[i]   # nothing below it is kept, so all of it is its own
            map[i] = o
        else
            map[i] = map[t.parent[i]]      # under a folded node: shown as what that folded into
        end
    end
    return (; strings = t.strings, nodes = cols, map)
end

# ── prepare: compile without running ────────────────────────────────────────────────────────────

# Statements that only mean something at top level: they define things, so they stay out of the
# wrapper and still run normally when the cell does.
function _toplevel_only(ex)
    ex isa Expr || return false
    ex.head in (:function, :macro, :struct, :abstract, :primitive, :module, :using, :import, :export,
                :const, :global, :public) && return true
    ex.head === :(=) && ex.args[1] isa Expr && ex.args[1].head in (:call, :where) && return true
    if ex.head === :macrocall
        m = ex.args[1]
        name = m isa Symbol ? m : m isa GlobalRef ? m.name : (m isa Expr && m.head === :. ? m.args[end] : nothing)
        name isa QuoteNode && (name = name.value)
        return name in (Symbol("@doc"), Symbol("@kwdef"), Symbol("@enum"), Symbol("@bind"), Symbol("@md_str"))
    end
    ex.head === :string && return false
    return false
end

"""
    profile_prepare!(mod; cell, source, reads) -> Dict

Compile `source` (cell `cell`) where it runs, without running it. The statements that can live in
a function become `__slate_prof_<cell>(reads...)`, and `precompile` at the types of the reads'
current values compiles every call inference can resolve. What it cannot reach is what the run
dispatches at runtime, which the profile then shows as compilation on the line that caused it.
"""
function profile_prepare!(mod::Module; cell::AbstractString, source::AbstractString,
                          reads::Vector{String} = String[])
    out = Dict{String,Any}("cell" => String(cell), "ok" => false, "compile_ms" => 0.0,
                           "args" => String[], "skipped" => Int[], "error" => nothing)
    ex = try
        Meta.parseall(String(source); filename = "cell:" * String(cell))
    catch e
        out["error"] = "could not parse the cell: " * sprint(showerror, e); return out
    end
    bad = findfirst(a -> Meta.isexpr(a, (:error, :incomplete)), ex.args)
    if bad !== nothing
        out["error"] = "could not parse the cell: " * first(sprint(show, ex.args[bad].args[1]), 300); return out
    end
    body = Any[]; line = 0
    for a in ex.args
        a isa LineNumberNode && (line = a.line; push!(body, a); continue)
        if _toplevel_only(a)
            push!(out["skipped"], line)
        else
            push!(body, a)
        end
    end
    names = Symbol[Symbol(r) for r in reads if Base.invokelatest(isdefined, mod, Symbol(r))]
    out["args"] = String.(names)
    fname = Symbol("__slate_prof_", replace(String(cell), r"[^A-Za-z0-9_]" => "_"))
    fdef = Expr(:function, Expr(:call, fname, names...), Expr(:block, body..., nothing))
    Base.cumulative_compile_timing(true)
    c0 = Base.cumulative_compile_time_ns()[1]
    f = nothing; tt = ()
    try
        Core.eval(mod, fdef)
        f = Base.invokelatest(getfield, mod, fname)
        tt = Tuple(Core.Typeof(Base.invokelatest(getfield, mod, n)) for n in names)
        out["ok"] = precompile(f, tt)
        out["ok"] || (out["error"] = "the cell's code could not be compiled at the current types")
    catch e
        out["error"] = "the cell could not be compiled as a function: " * first(sprint(showerror, e), 300)
    finally
        out["compile_ms"] = round((Base.cumulative_compile_time_ns()[1] - c0) / 1e6; digits = 1)
        Base.cumulative_compile_timing(false)
    end
    f === nothing || (out["static"] = _static_check(f, tt, "cell:" * String(cell); mod = mod, source = String(source)))
    return out
end

# ── the static check ────────────────────────────────────────────────────────────────────────────
# JET's optimization analysis of the same function at the same types: where a call has to be
# dispatched at runtime, and which variables a closure captures in a box, found without running
# anything. Only when the notebook's environment has JET: it is the notebook's to opt into, so it
# is never added for it, and its version is the one the notebook resolved.
const _JET_ID = Base.PkgId(Base.UUID("c3a54625-cd67-489e-a8e7-0a5a0ff4e31b"), "JET")

function _jet_module()
    m = get(Base.loaded_modules, _JET_ID, nothing)
    m === nothing || return m
    Base.locate_package(_JET_ID) === nothing && return nothing
    return try; Base.require(_JET_ID); catch; nothing; end
end

const _JET_KIND = Dict("RuntimeDispatchReport" => "dispatch", "CapturedVariableReport" => "captured",
                       "OptimizationFailureReport" => "not optimized")

_mi_name(mi) = try; string(mi.def.name); catch; ""; end

"""
    _static_check(f, tt, cellfile; mod, source) -> Dict

JET's `report_opt` of `f` at `tt`, as one finding per line of the reader's own code (this cell,
another cell, a package being worked on). Each report is placed at the innermost frame of its call
chain in that code, which is where a fix would go. A report inside a library, reached from the
line, is counted there as `lib` with the call it ends in: code that passes `Any` around makes many
of those, and they are the line's consequence rather than separate problems.
"""
function _static_check(f, tt, cellfile::AbstractString; mod::Union{Module,Nothing} = nothing, source::AbstractString = "")
    out = Dict{String,Any}("available" => false, "findings" => Any[], "n" => 0, "error" => nothing)
    J = _jet_module()
    J === nothing && (out["why"] = "JET is not in this notebook's environment"; return out)
    out["available"] = true
    t0 = time_ns()
    try
        reps = Base.invokelatest(J.get_reports, Base.invokelatest(J.report_opt, f, tt))
        raw = Dict{String,Any}[]
        for r in reps
            kind = get(_JET_KIND, string(nameof(typeof(r))), string(nameof(typeof(r))))
            msg = try; Base.invokelatest(sprint, J.print_report_message, r); catch; kind; end
            sig = try
                Base.invokelatest(sprint, (io, x) -> J.print_signature(io, x, J.PrintConfig()), r.sig)
            catch
                ""
            end
            frames = [(_ffile(fr), Int(fr.line), _mi_name(fr.linfo), _frame_pkg(fr, cellfile)) for fr in r.vst]
            isempty(frames) && continue
            k = something(findlast(x -> x[4] in ("cell", "notebook") || _user_pkg(x[4], x[1]), frames), 1)
            push!(raw, Dict{String,Any}("kind" => kind, "msg" => msg, "sig" => sig, "file" => frames[k][1],
                                        "line" => frames[k][2], "func" => frames[k][3], "mine" => k == length(frames),
                                        "call" => frames[end][3],
                                        "frames" => [[x[1], x[2], x[3], x[4]] for x in frames[1:min(end, 16)]]))
        end
        mod === nothing || _static_tidy!(raw, mod, cellfile, source)
        out["n"] = length(raw)
        out["findings"] = _static_lines(raw)
    catch e
        out["error"] = "JET could not check the cell: " * first(sprint(showerror, e), 300)
    end
    out["ms"] = round((time_ns() - t0) / 1e6; digits = 1)
    return out
end

# Reports in the cell's terms: without the notebook module's name in front of every function, and
# a captured variable on the line that first assigns it (JET places it on the function's first).
function _static_tidy!(raw::Vector, mod::Module, cellfile::AbstractString, source::AbstractString)
    pre = string(mod) * "."
    lines = split(source, '\n')
    for g in raw
        g["sig"] = replace(replace(g["sig"], pre => ""), r"([^\s(),:]+)::typeof\(\1\)\(" => s"\1(")
        g["kind"] == "captured" && g["file"] == cellfile || continue
        m = match(r"`([^`]+)`", g["msg"]); m === nothing && continue
        g["line"] = _capture_line(lines, g["line"], (m.captures[1],))
    end
    return raw
end

# Where a captured variable is assigned: the first line from `from` on that assigns one of `vars`,
# else `from`. JET reports a capture on the first line of the function that boxes it.
function _capture_line(lines, from::Integer, vars)
    for v in vars
        isempty(v) && continue
        re = Regex("(?<![\\w.])" * replace(String(v), r"([^\w])" => s"\\\1") * "\\s*[-+*/^]?=(?!=)")
        k = findnext(l -> occursin(re, l), lines, max(1, from))
        k === nothing || return k
    end
    return from
end

# One finding per line: what kinds were found there, the distinct signatures (the line's own first),
# and how many more came from inside the library calls it makes.
function _static_lines(raw::Vector)
    by = Dict{Tuple{String,Int},Dict{String,Any}}()
    for r in raw
        g = get!(by, (r["file"], r["line"])) do
            Dict{String,Any}("file" => r["file"], "line" => r["line"], "func" => r["func"], "kinds" => Dict{String,Int}(),
                             "count" => 0, "own" => 0, "lib" => 0, "sigs" => String[], "libsigs" => String[],
                             "calls" => String[], "frames" => r["frames"])
        end
        g["kinds"][r["kind"]] = get(g["kinds"], r["kind"], 0) + 1
        g["count"] += 1
        if r["mine"]
            g["own"] += 1
            r["sig"] in g["sigs"] || push!(g["sigs"], r["sig"])
        else
            g["lib"] += 1
            r["sig"] in g["libsigs"] || push!(g["libsigs"], r["sig"])
            r["call"] in g["calls"] || push!(g["calls"], r["call"])
        end
    end
    out = collect(values(by))
    for g in out
        ks = g["kinds"]
        g["kind"] = haskey(ks, "captured") ? "captured" : first(sort!(collect(keys(ks)); by = k -> -ks[k]))
        g["mine"] = g["own"] > 0
        g["sig"] = isempty(g["sigs"]) ? (isempty(g["libsigs"]) ? "" : g["libsigs"][1]) : g["sigs"][1]
        g["sigs"] = g["sigs"][1:min(end, 12)]; g["libsigs"] = g["libsigs"][1:min(end, 12)]
        g["calls"] = g["calls"][1:min(end, 8)]
    end
    sort!(out; by = g -> (!g["mine"], g["file"], g["line"]))
    return out[1:min(end, 200)]
end

# ── source for drill-down ───────────────────────────────────────────────────────────────────────

"""
    profile_source(file) -> Dict

The text of `file` on this machine, for the view's code pane: a frame in a package is shown from
the depot this process loaded it from, so a region shows the version it ran. Base's relative paths
(`./array.jl`) resolve through `Base.find_source_file`.
"""
function profile_source(file::AbstractString)
    f = String(file)
    p = isfile(f) ? f : something(Base.find_source_file(f), "")
    isempty(p) && return Dict{String,Any}("file" => f, "path" => "", "text" => "", "error" => "no such file here")
    text = try; read(p, String); catch e; return Dict{String,Any}("file" => f, "path" => p, "text" => "",
                                                                    "error" => sprint(showerror, e)); end
    return Dict{String,Any}("file" => f, "path" => p, "text" => text, "error" => nothing)
end
