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
const _PROF_ARMED = Dict{String,String}()          # cell id → mode, for its next run
const _PROF_RESULT = Dict{String,Any}()            # cell id → the last profile of it
const _PROF_STATE_LOCK = ReentrantLock()           # guards the two dicts above

# The tasks of the other cells running in this process while one is profiled, as task ids: their
# samples are theirs. The worker, which runs cells concurrently, sets this; the engine runs one at a time.
const _PROF_OTHER_TASKS = Ref{Any}(() -> UInt[])

# Samples every millisecond into a buffer of `_PROF_BUFFER` instruction pointers. A sample is its
# stack depth plus six words, so this holds a few minutes of one busy thread at typical depths.
const _PROF_DELAY = 0.001
const _PROF_BUFFER = 4_000_000

"Profile the next run of `cell` (`mode`: \"cpu\", the only one so far)."
profile_arm!(cell::AbstractString, mode::AbstractString = "cpu") =
    (lock(_PROF_STATE_LOCK) do; _PROF_ARMED[String(cell)] = String(mode); end; true)

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
    mode = _profile_take(cid)
    mode === nothing && return f()
    return lock(_PROF_LOCK) do
        Profile.clear()
        Profile.init(n = _PROF_BUFFER, delay = _PROF_DELAY)
        Base.cumulative_compile_timing(true)
        c0 = Base.cumulative_compile_time_ns()[1]; g0 = Base.gc_num().total_time; t0 = time_ns()
        task = UInt(pointer_from_objref(current_task()))
        others = delete!(Set{UInt}(_PROF_OTHER_TASKS[]()), task)
        facts() = (; mode, ms = (time_ns() - t0) / 1e6,
                     compile_ms = (Base.cumulative_compile_time_ns()[1] - c0) / 1e6,
                     gc_ms = (Base.gc_num().total_time - g0) / 1e6)
        store!(fx, err) = (union!(others, _PROF_OTHER_TASKS[]()); delete!(others, task);
                           r = _profile_build(String(cid), task, fx; error = err, others = others, marks = marks);
                           lock(_PROF_STATE_LOCK) do; _PROF_RESULT[String(cid)] = r; end)
        local v
        task_local_storage(:slate_profiling, true)   # `_eval_cell_source` compiles the cell's statements
        marks = Tuple{Int,Int}[]
        task_local_storage(:slate_prof_marks, marks)
        try
            v = Profile.@profile f()
        catch e
            fx = facts(); Base.cumulative_compile_timing(false)
            delete!(task_local_storage(), :slate_profiling); delete!(task_local_storage(), :slate_prof_marks)
            try; store!(fx, sprint(showerror, e)); catch; end
            _profile_release!()
            rethrow()
        end
        fx = facts(); Base.cumulative_compile_timing(false)
        delete!(task_local_storage(), :slate_profiling); delete!(task_local_storage(), :slate_prof_marks)
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
_profile_release!() = (Profile.clear(); Profile.init(n = 1000, delay = _PROF_DELAY); nothing)

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

"""
    _profile_build(cid, task, facts; error) -> Dict

Turn the sample buffer into the line-keyed tree for cell `cid`, whose evaluation ran on `task`.

Which samples are the cell's: those of its task, and those of any task whose stack runs this
cell's code (a `Threads.@threads` body, a spawned closure). Dropped, and counted by reason: idle
threads, samples inside another cell, and the worker's own tasks. A sample of a task the cell did
not obviously start, doing work that is not the worker's, is kept under "other threads": library
code the cell set running on a thread pool lands there.
"""
function _profile_build(cid::String, task::UInt, facts; error = nothing, others::Set{UInt} = Set{UInt}(),
                        marks::Vector{Tuple{Int,Int}} = Tuple{Int,Int}[])
    data = Profile.fetch(include_meta = true)
    lidict = Profile.getdict(data)
    cellfile = "cell:" * cid
    t = _ProfTree()
    root = _node!(t, 0, cellfile, 0, "cell " * cid, "cell", _K_SYNTH)
    toplevel = 0; spare = 0
    dropped = Dict{String,Int}("idle" => 0, "other cells" => 0, "worker" => 0)
    kept = 0; threads = Set{UInt}()
    lines = Dict{Tuple{Int,Int},Vector{Int}}()    # (file, line) → [incl, self, dispatch, gc, compile]
    frames = Base.StackTraces.StackFrame[]
    seen = Set{Tuple{Int,Int}}()
    pkgfile = Dict{String,String}()               # package → a file of it, to tell the user's own
    path = Int[]; pathfn = Symbol[]               # the line nodes this sample went through
    # Work the cell hands to other tasks is the cell's, and belongs under the call that handed it
    # out. A task waiting for that work leaves no samples, so it goes where the cell's own task last
    # was in the same statement (inside the `@threads` loop, the `fetch`), or else on the
    # statement's line. Samples are in the order they were taken, which is what `marks` index.
    graft = 0; graftat = 0; mi = 0
    for s in _profile_samples(data)
        while mi < length(marks) && marks[mi + 1][1] < first(s.ips); mi += 1; end
        stmt0 = mi == 0 ? 0 : marks[mi][1]
        s.awake || (dropped["idle"] += 1; continue)
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
            # The cell's task outside its code: parsing, lowering and compiling its statements,
            # below the evaluation machinery that brought it there.
            ev = findlast(fr -> fr.func === :_eval_cell_source, frames)
            start = ev === nothing ? 1 : ev + 1
            # The runtime's own frames stay: compiling and collecting are recognised and marked below.
            while start <= length(frames) && !frames[start].from_c && (frames[start].func === :eval ||
                                              _frame_pkg(frames[start], cellfile) in _INFRA_PKGS)
                start += 1
            end
            toplevel == 0 && (toplevel = _node!(t, root, cellfile, 0, "top level", "cell", _K_SYNTH))
            cur = toplevel
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
        # Everything above where this sample starts holds it too, lines included.
        empty!(seen); empty!(path); empty!(pathfn)
        a = cur
        while a > 0
            t.total[a] += 1
            if t.kind[a] == _K_LINE
                key = (t.file[a], t.line[a])
                key in seen || (push!(seen, key); get!(() -> zeros(Int, 5), lines, key)[1] += 1)
            end
            a = t.parent[a]
        end
        leafline = (0, 0)
        for j in start:length(frames)
            fr = frames[j]
            if fr.from_c
                fn = string(fr.func)
                if fn in _DISPATCH_C
                    t.dispatch[cur] += 1
                    leafline[1] > 0 && (get!(() -> zeros(Int, 5), lines, leafline)[3] += 1)
                elseif _gc_c(fn)
                    t.gc[cur] += 1
                    leafline[1] > 0 && (get!(() -> zeros(Int, 5), lines, leafline)[4] += 1)
                    cur = _node!(t, cur, "", 0, "garbage collection", "", _K_GC); t.total[cur] += 1
                    break
                elseif _compile_c(fn)
                    t.compile[cur] += 1
                    leafline[1] > 0 && (get!(() -> zeros(Int, 5), lines, leafline)[5] += 1)
                    cur = _node!(t, cur, "", 0, "compilation", "", _K_COMPILE); t.total[cur] += 1
                    break
                end
                continue
            end
            pkg = _frame_pkg(fr, cellfile)
            haskey(pkgfile, pkg) || (pkgfile[pkg] = _ffile(fr))
            if _compiler_pkg(pkg)
                t.compile[cur] += 1
                leafline[1] > 0 && (get!(() -> zeros(Int, 5), lines, leafline)[5] += 1)
                cur = _node!(t, cur, "", 0, "compilation", "", _K_COMPILE); t.total[cur] += 1
                break
            end
            file = _ffile(fr); ln = Int(fr.line)
            cur = _node!(t, cur, file, ln, string(fr.func), pkg, _K_LINE)
            t.total[cur] += 1
            push!(path, cur); push!(pathfn, fr.func)
            key = (_str!(t, file), ln)
            if !(key in seen)
                push!(seen, key)
                get!(() -> zeros(Int, 5), lines, key)[1] += 1
            end
            leafline = key
        end
        t.self[cur] += 1
        leafline[1] > 0 && (get!(() -> zeros(Int, 5), lines, leafline)[2] += 1)
        # Where work handed out now would hang: the frame that waits for it, else the cell's line.
        if own && cidx !== nothing && !isempty(path)
            w = findfirst(in(_WAIT_FNS), pathfn)
            graft = w === nothing ? path[1] : path[max(1, w - 1)]; graftat = first(s.ips)
        end
    end
    tree = _profile_prune(t, kept)
    return Dict{String,Any}(
        "cell" => cid, "mode" => String(facts.mode), "samples" => kept, "dropped" => dropped,
        "threads" => length(threads), "duration_ms" => round(facts.ms; digits = 1),
        "compile_ms" => round(facts.compile_ms; digits = 1), "gc_ms" => round(facts.gc_ms; digits = 1),
        "delay_ms" => _PROF_DELAY * 1000, "error" => error, "at" => time(),
        "strings" => tree.strings, "nodes" => tree.nodes,
        "mine" => sort!([p for (p, f) in pkgfile if _user_pkg(p, f)]),
        "lines" => Dict{String,Any}(
            "file" => [k[1] for k in keys(lines)], "line" => [k[2] for k in keys(lines)],
            "incl" => [v[1] for v in values(lines)], "self" => [v[2] for v in values(lines)],
            "dispatch" => [v[3] for v in values(lines)], "gc" => [v[4] for v in values(lines)],
            "compile" => [v[5] for v in values(lines)]))
end

# Below this share of the samples a node is folded into an "other" sibling, so a deep library
# stack sent from a compute node stays small. The line table is not pruned: it is one row per line.
const _PROF_KEEP = 0.001

function _profile_prune(t::_ProfTree, kept::Int)
    n = length(t.parent)
    floor_ = max(1, ceil(Int, _PROF_KEEP * kept))
    keep = falses(n); keep[1] = n >= 1
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
    for i in 1:n
        if keep[i]
            newid[i] = add!(i == 1 ? 0 : newid[t.parent[i]], t.file[i], t.line[i], t.func[i], t.pkg[i],
                            t.kind[i], t.total[i], t.self[i], t.dispatch[i], t.gc[i], t.compile[i])
        elseif keep[t.parent[i]]
            p = newid[t.parent[i]]
            o = get!(other, p) do
                add!(p, empty_, 0, oname, empty_, _K_OTHER, 0, 0, 0, 0, 0)
            end
            cols["total"][o] += t.total[i]
            cols["self"][o] += t.total[i]   # nothing below it is kept, so all of it is its own
        end
    end
    return (; strings = t.strings, nodes = cols)
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
