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
    lock(_PROF_STATE_LOCK) do; _PROF_ARMED[String(cell)] = o; end
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
_prof_mark(line::Int) = (m = get(task_local_storage(), :slate_prof_marks, nothing);
                         m === nothing || push!(m, (Int(ccall(:jl_profile_len_data, Csize_t, ())), line)); nothing)

# Called by `run_capture` around a cell's evaluation. Unarmed, it is the evaluation.
function _profiled(f, cid::AbstractString)
    o = _profile_take(cid)
    o === nothing && return f()
    return lock(_PROF_LOCK) do
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
                v = o.mode == "wall" ? Profile.@profile_walltime(run()) :
                    o.mode == "gpu" ? _with_gpu(() -> Profile.@profile(run()), gpu) : Profile.@profile(run())
            end
        catch e
            fx = facts(); done()
            try; store!(fx, sprint(showerror, e)); catch; end
            _profile_release!()
            rethrow()
        end
        fx = facts(); done()
        try
            store!(fx, nothing)
        catch e
            @warn "slate profile: could not build the profile" cell = cid exception = (e, catch_backtrace())
        end
        _profile_release!()
        v
    end
end

# The sample buffer is only needed while a profile runs: shrunk back afterwards, so a worker that
# was profiled once does not keep it.
_profile_release!() = (Profile.clear(); Profile.init(n = 1000, delay = _PROF_DELAY);
                       try; Profile.Allocs.clear(); catch; end; nothing)

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
    _trace_on()
    try
        return f()
    finally
        _trace_off()
        flush(io)
        _read_trace!(out, _TRACE_PATH[])
        truncate(io, 0); seekstart(io)
    end
end

const _OWN_SIG = r"\b(?:SlateWorker|ReportEngine|KaimonSlate|KaimonGate)\."

function _read_trace!(out::Dict{String,Any}, path::AbstractString)
    compiled = Dict{String,Vector{Float64}}(); dispatched = Dict{String,Int}()   # signature → [count, ms]
    for l in eachline(path)
        m = match(r"^#=\s*([\d.]+)\s*ms\s*=#\s*precompile\((.*)\)(?:\s*#.*)?$", l)
        # The profiler's and the worker's own calls are not the cell's.
        occursin(_OWN_SIG, l) && continue
        if m !== nothing
            c = get!(() -> [0.0, 0.0], compiled, String(m.captures[2]))
            c[1] += 1; c[2] += parse(Float64, m.captures[1])
        elseif (m2 = match(r"^precompile\((.*)\)(?:\s*#.*)?$", l)) !== nothing
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

# `f` under CUDA.jl's own profiler, when the notebook has loaded CUDA: the device's kernels and
# copies, summed by name, land in `out`. Without CUDA it is `f`, and `out` says why.
function _with_gpu(f, out::Dict{String,Any})
    m = get(Base.loaded_modules, _CUDA_ID, nothing)
    m === nothing && (out["error"] = "CUDA is not loaded in this notebook"; return f())
    val = Ref{Any}(nothing)
    res = try
        Base.invokelatest(Core.eval, Main,
            Expr(:macrocall, GlobalRef(m, Symbol("@profile")), LineNumberNode(0), Expr(:call, () -> (val[] = f()))))
    catch e
        out["error"] = first(sprint(showerror, e), 300)
        return val[]
    end
    try
        dev = Base.invokelatest(getproperty, res, :device)
        names = String.(Base.invokelatest(getindex, dev, !, :name))
        dur = Float64.(Base.invokelatest(getindex, dev, !, :stop)) .- Float64.(Base.invokelatest(getindex, dev, !, :start))
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
end
_Acc(t, cellfile) = _Acc(t, cellfile, Dict{Tuple{Int,Int},Vector{Int}}(), Dict{String,String}(),
                         Set{Tuple{Int,Int}}(), Int[], Symbol[])
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

# Only the runtime and Base's scheduler from `start` on, waiting in it: a task with nothing to do.
const _SCHED_FNS = (:wait, :poptask, :task_get_next, :try_yieldto, :wait_forever, :yield)
_scheduling(frames, start, cellfile) =
    !any(j -> (fr = frames[j]; fr.from_c ? (_gc_c(string(fr.func)) || _compile_c(string(fr.func))) :
                                           !(_frame_pkg(fr, cellfile) in ("Base", "Compiler"))), start:length(frames)) &&
    any(j -> frames[j].func in _SCHED_FNS || occursin("task_get_next", string(frames[j].func)), start:length(frames))

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
    wall = facts.opts.mode == "wall"
    data = Profile.fetch(include_meta = true)
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
    for s in _profile_samples(data)
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
            else
                toplevel == 0 && (toplevel = _node!(t, root, cellfile, 0, "top level", "cell", _K_SYNTH))
                cur = toplevel
            end
        else
            any(fr -> !fr.from_c && _frame_pkg(fr, cellfile) in _INFRA_PKGS, frames) &&
                (dropped["worker"] += 1; continue)
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
    r["dropped"] = dropped; r["threads"] = length(threads)
    r["buffer_full"] = try; Profile.is_buffer_full(); catch; false; end
    r["timeline"] = _timeline(tl_thread, tl_clock, tl_node, tree.map, facts.ms, facts.opts.delay_ms)
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
    t = _ProfTree(); a = _Acc(t, cellfile)
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
# long run is thinned to `_TL_MAX` samples.
const _TL_MAX = 150_000
function _timeline(thread, clock, node, map, ms, delay)
    n = length(node)
    n == 0 && return Dict{String,Any}("thread" => Int[], "t" => Float64[], "node" => Int[], "step_ms" => delay)
    step = max(1, cld(n, _TL_MAX))
    ix = 1:step:n
    c0, c1 = minimum(clock), maximum(clock)
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
    return out
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
