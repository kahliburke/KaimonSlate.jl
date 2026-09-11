# ── Cell debugger (shared: worker process AND in-process engine) ───────────────────────────────────────────────
# Step a cell's code one line at a time, on whichever kernel the notebook runs on.
# Included by BOTH worker.jl and engine.jl: a notebook gets the same stepper
# whether its cells evaluate in a spawned worker or in the server process. The
# worker path wraps these in `__slate_debug_*` gate tools, and that RPC path is
# transport-agnostic, so a remote region costs nothing extra.
#
# Nothing is ever paused. JuliaInterpreter reifies the frame as a data structure,
# so between steps the cell is not running-and-blocked, it is a value in a Ref.
# That keeps the debugger clear of the rule against holding a notebook lock
# across a worker round trip: there is no held lock and no blocked task.
#
# The interpreter is reached through Revise, which is already loaded on both paths
# and which depends on it, so no package is added to the notebook's environment
# (or to every remote provision) for a feature most sessions never use.

# ── reaching the interpreter ──────────────────────────────────────────────────

const _JI = Ref{Union{Nothing,Module}}(nothing)

function _ji()
    _JI[] === nothing || return _JI[]
    # Every read of these bindings goes through `invokelatest`, including the `isdefined` check.
    #
    # `@eval(Main, import …)` creates the binding in a NEWER world than this method is running in,
    # so reading it directly is a world-age violation: Julia 1.12 warns ("may malfunction under
    # Revise") and later versions will make it an error. It is not only the import — `Main.Revise`
    # is loaded by whoever started the session, which is also after this code was compiled.
    _has(mod, name) = Base.invokelatest(isdefined, mod, name)
    _get(mod, name) = Base.invokelatest(getfield, mod, name)
    m = try
        _has(Main, :Revise) ? _get(_get(Main, :Revise), :JuliaInterpreter) : nothing
    catch
        nothing
    end
    m === nothing && (m = try
        _has(Main, :JuliaInterpreter) || @eval(Main, import JuliaInterpreter)
        _get(Main, :JuliaInterpreter)
    catch
        nothing
    end)
    m === nothing && error("the cell debugger needs JuliaInterpreter, which normally arrives with " *
                           "Revise; add it to this notebook's environment to debug here")
    return (_JI[] = m)
end

# ── session ───────────────────────────────────────────────────────────────────

mutable struct _DebugSession
    cell::String
    frame::Any                      # current innermost frame, or nothing once finished
    rest::Vector{Any}               # remaining top-level (module, expr) pairs
    ns::Module
    saved_compiled::Set{Module}     # compiled_modules is global; restore it on stop
    interpret::Set{Module}
    finished::Bool
    result::Any
    error::Any
    steps::Int
    writes::Vector{Symbol}          # names this cell assigns at top level (see _toplevel_writes)
    before::Set{Symbol}             # namespace contents at start, to spot what the cell adds
    at_breakpoint::Bool             # the last step stopped ON a breakpoint, not by finishing
    marks::Vector{Any}              # the JuliaInterpreter breakpoints this session set
    watches::Vector{Any}            # armed breakpoints that only RECORD (see `_arm!`)
    want_marks::Vector{Any}         # what was ASKED for, since marks and watches share a line
    want_watches::Vector{Any}       #   slot and have to be composed rather than armed twice
    # expression → the values it took, in execution order. A watch answers a question the stepper
    # cannot: not "what is it now" but "what has it been", which is the shape of a divergence.
    traces::Dict{String,Vector{Float64}}
    # Which of `writes` this session has actually executed. Tracked per top-level statement, so
    # "fresh" is a fact about what has run rather than a guess from whether a value changed —
    # re-running a cell and getting the same answer must not read as stale.
    thunk_writes::Vector{Vector{Symbol}}   # writes of each REMAINING statement, parallel to `rest`
    current_writes::Vector{Symbol}         # writes of the statement being stepped now
    assigned::Set{Symbol}                  # writes whose statement has completed
end

const _DEBUG = Ref{Union{Nothing,_DebugSession}}(nothing)

"""
Modules whose code is stepped rather than run compiled.

Everything else in the session runs at native speed. The set is the cell's own
namespace plus whatever Revise is already tracking, which is exactly the code the
user is working on. That is the whole of the configuration: the equivalent
feature elsewhere asks you to predict, up front, which modules you will care
about, and then punishes a wrong guess with breakpoints that never fire.
"""
function _interpret_set(ns::Module)
    keep = Set{Module}([ns])
    # A module defined in a cell is a distinct module object, so the notebook's
    # own submodules have to be added explicitly or stepping stops at their door.
    try
        for n in names(ns; all = true)
            isdefined(ns, n) || continue
            m = getfield(ns, n)
            m isa Module && m !== ns && parentmodule(m) === ns && push!(keep, m)
        end
    catch
    end
    try
        # `invokelatest` for the same reason as in `_ji`: Revise is loaded by whoever started the
        # session, so its binding belongs to a world later than this method's.
        R = Base.invokelatest(getfield, Main, :Revise)
        for (id, pkgdata) in Base.invokelatest(getfield, R, :pkgdatas)
            m = get(Base.loaded_modules, id, nothing)
            m === nothing && continue
            base = try; R.basedir(pkgdata); catch; ""; end
            _is_user_source(base) && push!(keep, m)
        end
    catch
    end
    return keep
end

"""
Source the user could plausibly be editing.

Revise watches far more than you are working on, stdlibs included, and
interpreting `Compiler` or `REPL` because Revise happens to track them makes
stepping slow and the call stack unreadable. Registered packages live in a
read-only depot and stdlibs ship with Julia; anything outside both is either a
dev'd package or the project's own source.
"""
function _is_user_source(path::AbstractString)
    isempty(path) && return false
    p = try; abspath(path); catch; return false; end
    try
        startswith(p, abspath(Sys.STDLIB)) && return false
    catch
    end
    for d in DEPOT_PATH
        try
            startswith(p, abspath(joinpath(d, "packages"))) && return false
        catch
        end
    end
    return true
end

"Point the interpreter at `keep` only; returns the previous set so it can be restored."
function _scope_interpreter!(keep::Set{Module})
    ji = _ji()
    saved = copy(ji.compiled_modules)
    empty!(ji.compiled_modules)
    for m in values(Base.loaded_modules)
        m in keep || push!(ji.compiled_modules, m)
    end
    return saved
end

function _restore_interpreter!(saved::Set{Module})
    ji = _ji()
    empty!(ji.compiled_modules)
    union!(ji.compiled_modules, saved)
    nothing
end

# ── frame reporting ───────────────────────────────────────────────────────────
#
# Wire shapes are NamedTuples, not Dicts. They ride the gate unchanged (their type
# comes from Base, so it is the same on both sides of a worker boundary — a struct
# defined here would be `SlateWorker.X` in a worker and `ReportEngine.X` in the
# server and fail to deserialize), and the fields are typed and always present, so
# a viewer never has to guess whether a key exists.
#
# `scope` rather than `where`: `where` is a keyword and cannot name a field.

"""
One variable, summarized.

`fresh` says the value was produced by THIS session. It is always true of a frame local, which
exists only because the frame assigned it, and the question only bites for a cell's module
bindings: those survive the last ordinary run, so at the start of a session every one of them
already holds a value, and a reader cannot tell last run's answer from this run's. The first
specialist to use this pane said so unprompted — it called them "stale values from a previous
run" and had to work around the doubt.
"""
const DebugLocal = @NamedTuple{name::String, type::String, size::String, repr::String, fresh::Bool}

"""
One frame in the call stack. `src` indexes `DebugState.sources`, or 0 when there is no text for it.

An index rather than the text itself: a recursive stack is the same method twenty times over, and
a frame is cheap to send only if its source is sent once.
"""
const DebugFrame = @NamedTuple{file::String, line::Int, scope::String, src::Int}

"""
The text of one method (or cell), and the line of `file` its first line is.

Shipped as text because `file` names a path on the machine the kernel runs on — reading it where
the viewer happens to be shows a different file, or none.
"""
const DebugSource = @NamedTuple{file::String, first::Int, text::String}

"""
What one watch has seen so far, small enough to ride in every state payload.

The series itself can be a hundred thousand samples; that belongs in a chart, and is fetched with
`debug_traces`. These are what a reader decides on — still climbing, or turned, and how far.
"""
const DebugTrace = @NamedTuple{expr::String, n::Int, first::Float64, last::Float64,
                               min::Float64, max::Float64}

"""
Everything needed to render a paused frame.

Every field is always present. `finished` says whether the run is over, and when
it is, `result` holds the value and the frame fields are empty rather than absent.

`source` is the text of the method being executed, with `srcfirst` the line of
`file` its first line corresponds to. It is shipped rather than read locally
because the file is on whichever machine the kernel runs on, which in general is
not the one rendering it. It is empty for a frame whose code came from a cell —
the server holds the notebook and fills that in, so a remote worker never needs
to have been told the notebook's text.
"""
const DebugState = @NamedTuple{
    cell::String,
    finished::Bool,
    steps::Int,
    interpreting::Vector{String},
    file::String,
    line::Int,
    scope::String,
    in_cell::Bool,
    at_breakpoint::Bool,
    source::String,
    srcfirst::Int,
    sources::Vector{DebugSource},
    locals::Vector{DebugLocal},
    bindings::Vector{DebugLocal},
    stack::Vector{DebugFrame},
    result::Union{DebugLocal,Nothing},
    error::Union{String,Nothing},
    traces::Vector{DebugTrace},
}

"The answer to evaluating an expression in a paused frame."
const DebugEval = @NamedTuple{ok::Bool, value::Union{DebugLocal,Nothing}, error::Union{String,Nothing}}

"""
One local, summarized.

Values are never sent: a frame on a compute node may hold tens of gigabytes, and
the point of building this against a remote region first was to make that
impossible to forget. The summary carries what a reader needs to decide whether
to ask for more.
"""
function _local_summary(name, value; fresh::Bool = true)::DebugLocal
    t = try; string(typeof(value)); catch; "?"; end
    sz = try
        value isa AbstractArray ? string(size(value)) : ""
    catch
        ""
    end
    rep = try
        r = repr(value; context = IOContext(devnull, :limit => true, :compact => true))
        length(r) > 200 ? r[1:200] * "…" : r
    catch e
        "<repr failed: $(sprint(showerror, e))>"
    end
    return (name = string(name), type = t, size = sz, repr = rep, fresh = fresh)
end

# Lowered code carries compiler temporaries and loop state with generated or empty
# names. They are noise in a variables pane.
_is_user_local(n) = (s = string(n); !isempty(s) && !startswith(s, "#") && s != "_")

function _frame_locals(fr)::Vector{DebugLocal}
    ji = _ji()
    out = DebugLocal[]
    try
        for v in ji.locals(fr)
            _is_user_local(v.name) || continue
            push!(out, _local_summary(v.name, v.value))
        end
    catch
    end
    return out
end

"""
The paused frame's locals, by name, for code that needs the VALUES rather than a summary.

Published into the notebook's namespace under a fixed name so a live watch can reach them from
ordinary source text: only the NAMES can go into generated source, since a value has no source
form, so the source says `u = __dbg_frame[:u]` and the value arrives through here at run time.
That keeps a frame-scoped watch on the same capture path as any other cell — nothing about
plotting or rendering has to know the debugger exists.
"""
const FRAME_BINDING = :__dbg_frame

function _frame_local_values(fr)
    d = Dict{Symbol,Any}()
    fr === nothing && return d
    ji = _ji()
    try
        for v in ji.locals(fr)
            _is_user_local(v.name) || continue
            d[Symbol(v.name)] = v.value
        end
    catch
    end
    return d
end

"""
    debug_frame_locals!() -> Vector{String}

Publish the paused frame's locals into the namespace and answer which names are available.

Called before a live watch runs, so the watch's generated `let` binds names that exist. A name
that has gone out of scope simply stops being offered rather than becoming a stale value.
"""
function debug_frame_locals!()
    s = _DEBUG[]
    s === nothing && return String[]
    d = _frame_local_values(s.frame)
    try
        Core.eval(s.ns, :(const $(FRAME_BINDING) = $d))
    catch
        return String[]
    end
    return sort!(String[String(k) for k in keys(d)])
end

_frame_scope(fr) = try
    sc = _ji().scopeof(fr)
    sc isa Method ? string(sc.module, ".", sc.name) : string(sc)
catch
    "?"
end

function _frame_position(fr)
    file, line = try
        _ji().whereis(fr)
    catch
        ("?", 0)
    end
    return (string(file), Int(line))
end

"""
The text of the method this frame is running, and the line `file` numbers its first
line as — `("", 0)` when there is none to give.

Shipped as text on purpose. `file` names a path on the machine the kernel runs on;
reading it where the viewer happens to be would show a different file, or none. The
lookup goes through CodeTracking (Revise's own record of where definitions came
from), so a method from a dev'd package that has been edited since it loaded reports
the source that is actually running.
"""
function _frame_source(fr)
    m = try; _ji().scopeof(fr); catch; nothing; end
    m isa Method || return ("", 0)
    # Through JuliaInterpreter, which depends on CodeTracking and is already required for any of
    # this to run. Reaching it through Revise instead made frame source quietly vanish wherever
    # Revise happened not to be loaded, which is every process that is not a notebook worker.
    d = try
        getfield(_ji(), :CodeTracking).definition(String, m)
    catch
        nothing
    end
    d === nothing && return ("", 0)
    txt, first = d
    return (String(txt), Int(first))
end

"""
The names a cell assigns at top level.

Collected from the parse rather than from the namespace, so a binding appears in the
pane before the line that assigns it has run — the point of stepping is to watch it
arrive. Deliberately shallow: the fixed points are the cell's own statements, and a
global written from inside a loop body still turns up through the namespace diff.
"""
function _toplevel_writes(ex)::Vector{Symbol}
    out = Symbol[]
    _target!(t) = begin
        t isa Symbol && return push!(out, t)
        t isa Expr || return
        if t.head === :tuple || t.head === :parameters   # a, b = f()
            foreach(_target!, t.args)
        elseif t.head === :(::)                          # x::Int = 1
            isempty(t.args) || _target!(t.args[1])
        end
        return
    end
    _stmt!(e) = begin
        e isa Expr || return
        if e.head === :toplevel || e.head === :block
            foreach(_stmt!, e.args)
        elseif e.head === :(=)
            lhs = e.args[1]
            # `f(x) = …` declares f, not x.
            (lhs isa Expr && lhs.head === :call) ? _target!(lhs.args[1]) : _target!(lhs)
        elseif e.head === :const || e.head === :global
            foreach(_stmt!, e.args)
        elseif e.head === :function && !isempty(e.args)
            sig = e.args[1]
            (sig isa Expr && sig.head === :call) ? _target!(sig.args[1]) : _target!(sig)
        elseif e.head === :struct && length(e.args) >= 2
            n = e.args[2]
            _target!(n isa Expr && n.head === :<: ? n.args[1] : n)
        end
        return
    end
    _stmt!(ex)
    return unique!(out)
end

"The parser's complaint about an unfinished expression anywhere in `ex`, or `nothing`."
function _incomplete(ex)
    ex isa Expr || return nothing
    ex.head === :incomplete && return isempty(ex.args) ? "the cell is unfinished" : string(ex.args[1])
    for a in ex.args
        m = _incomplete(a)
        m === nothing || return m
    end
    return nothing
end

_is_user_binding(n::Symbol) = (s = string(n); !startswith(s, "#") && !startswith(s, "__slate"))

"""
A module binding's current value, as `Some(v)`, or `nothing` if it is not assigned yet.

`invokelatest` wraps the WHOLE access, `isdefined` included. The interpreter creates a global in a
newer world than this function was compiled in, so reading it at the stale world says "not defined"
for one more step — which showed up as every value in the pane lagging the line that assigned it.
"""
_binding_value(ns::Module, n::Symbol) =
    Base.invokelatest(() -> isdefined(ns, n) ? Some(getfield(ns, n)) : nothing)

# Same reason: a name the cell has just bound is missing from a stale-world `names`.
_ns_names(ns::Module) = try
    Base.invokelatest(names, ns; all = true)
catch
    Symbol[]
end

"""
The cell's own module-level bindings, summarized like locals.

A cell's top-level assignments become globals of the notebook's namespace, not
locals of the frame, so without this the pane is empty for exactly the frame a
reader starts on. Both the names the cell declares and anything else that appeared
in the namespace since the session began; a declared name that has not been
assigned yet is reported with an empty type, which is how a viewer tells "waiting"
from "assigned nothing".
"""
function _module_bindings(s::_DebugSession)::Vector{DebugLocal}
    out = DebugLocal[]
    seen = Set{Symbol}()
    fresh = Symbol[]
    for n in _ns_names(s.ns)
        (n in s.before || !_is_user_binding(n)) && continue
        n in s.writes || push!(fresh, n)
    end
    for n in Iterators.flatten((s.writes, sort!(fresh)))
        (n in seen || !_is_user_binding(n)) && continue
        push!(seen, n)
        v = _binding_value(s.ns, n)
        push!(out, v === nothing ? (name = string(n), type = "", size = "", repr = "", fresh = false) :
                                   _local_summary(n, something(v); fresh = n in s.assigned))
    end
    return out
end

"""
The frame stack, outermost first, together with the source of every frame in it.

Every frame gets its text, not just the innermost one: "why was this called with that?" is a
question about the CALLER, and answering it from a line number alone means reading the file by
hand on whichever machine it lives on. Sources are pooled and referenced by index, so a recursive
stack costs one copy, and the pool is capped — a runaway recursion should not turn one step into
a megabyte.
"""
function _frame_stack(fr)
    ji = _ji()
    out = DebugFrame[]
    sources = DebugSource[]
    seen = Dict{Tuple{String,Int},Int}()
    f = fr
    depth = 0
    while f !== nothing && depth < 64
        depth += 1
        file, line = _frame_position(f)
        idx = 0
        if length(sources) < 16
            txt, first = _frame_source(f)
            if !isempty(txt) && first > 0
                key = (file, first)
                idx = get(seen, key, 0)
                if idx == 0
                    push!(sources, (file = file, first = first, text = txt))
                    idx = length(sources)
                    seen[key] = idx
                end
            end
        end
        pushfirst!(out, (file = file, line = line, scope = _frame_scope(f), src = idx))
        f = try; ji.caller(f); catch; nothing; end
    end
    return (stack = out, sources = sources)
end

function _state(s::_DebugSession)::DebugState
    interp = sort!([string(nameof(m)) for m in s.interpret])
    err = s.error === nothing ? nothing : sprint(showerror, s.error)
    if s.finished || s.frame === nothing
        return (cell = s.cell, finished = true, steps = s.steps, interpreting = interp,
                file = "", line = 0, scope = "", in_cell = false, at_breakpoint = false,
                source = "", srcfirst = 0, sources = DebugSource[],
                locals = DebugLocal[], bindings = _module_bindings(s), stack = DebugFrame[],
                result = err === nothing ? _local_summary("result", s.result) : nothing,
                error = err, traces = _trace_summaries(s))
    end
    file, line = _frame_position(s.frame)
    src, srcfirst = _frame_source(s.frame)
    st = _frame_stack(s.frame)
    return (cell = s.cell, finished = false, steps = s.steps, interpreting = interp,
            file = file, line = line, scope = _frame_scope(s.frame),
            # Specifically the cell being stepped, not merely "some cell": a function
            # defined in another cell reports `cell:<that one>`, and treating that as
            # in-cell makes a viewer highlight a line belonging to different source.
            in_cell = (file == "cell:" * s.cell),
            at_breakpoint = s.at_breakpoint,
            source = src, srcfirst = srcfirst, sources = st.sources,
            locals = _frame_locals(s.frame), bindings = _module_bindings(s),
            stack = st.stack,
            result = nothing, error = err, traces = _trace_summaries(s))
end

# ── breakpoints ───────────────────────────────────────────────────────────────
#
# JuliaInterpreter matches a file breakpoint against a frame's source file by
# `endswith`, and a cell's code is parsed with the filename `cell:<id>`. So one
# mechanism covers both halves of a notebook: a line of the cell being stepped, and
# a line of a method — whether that method came from a package file or from another
# cell, which reports `cell:<that one>` and matches just the same.
#
# The set is owned by the CALLER and pushed whole. There is no add/remove verb
# because a breakpoint list is small, the browser already holds the authoritative
# copy, and reconciling two of them across a machine boundary is a bug farm.
#
# Like `compiled_modules`, JuliaInterpreter's breakpoint list is process-global.
# Everything this session sets is remembered in `marks` and removed on stop, so a
# region worker that goes back to the warm pool goes back unmarked.

"""
One armed line: the file as the frame reports it, the line within that file, and an optional
predicate that has to hold for it to fire (`""` = fire every time).

The predicate is what makes a long run reachable. Instability that starts at step 4,700 cannot be
found by stepping 4,700 times, and a line breakpoint inside the loop stops on the first
iteration — which is the one that is fine. `maximum(abs, du) > 1e3` stops on the one that is not.
"""
const DebugMark = @NamedTuple{file::String, line::Int, cond::String}

"""
Is the frame sitting on a breakpoint someone armed?

Asked of the frame rather than read off `debug_command`'s return, which hands back a
`BreakpointRef` for its own reasons too — stepping INTO a call is implemented as a
synthetic one, so trusting that reported a breakpoint on every `into`.
"""
function _on_breakpoint(fr)
    fr === nothing && return false
    try
        bps = fr.framecode.breakpoints
        pc = fr.pc
        (pc >= 1 && pc <= length(bps) && isassigned(bps, pc)) || return false
        return bps[pc].isactive
    catch
        return false
    end
end

function _clear_marks!(s::_DebugSession)
    ji = _ji()
    for bp in s.marks
        try; ji.remove(bp); catch; end
    end
    empty!(s.marks)
    return nothing
end

"""
Arm exactly `marks` and nothing else.

Applied to already-compiled code immediately and to anything compiled later, so a
breakpoint inside a function the cell has not called yet still fires when it does.
"""
function _set_marks!(s::_DebugSession, marks::Vector{DebugMark})
    s.want_marks = copy(marks)
    _arm!(s)
end

"""
Compile a mark's predicate into the form JuliaInterpreter wants, or `nothing` for an
unconditional one.

Paired with the session's namespace rather than left bare: a bare `Expr` is resolved in `Main`
(`JuliaInterpreter._unpack`), where a notebook's own bindings do not exist. The frame's locals
come from the frame either way.

Wrapped so it cannot throw or return a non-`Bool`. The predicate runs on EVERY execution of that
line, and `shouldbreak` asserts `::Bool` on the result, so an expression that errors on some
iteration would abort the run rather than decline to stop — which is worse than not firing. A
predicate that never holds is the cost of that, hence the parse check at arm time below.
"""
function _mark_condition(s::_DebugSession, cond::AbstractString)
    isempty(strip(cond)) && return nothing
    ex = try
        Meta.parse(strip(cond))
    catch
        return nothing
    end
    (ex isa Expr && ex.head === :incomplete) && return nothing
    return (s.ns, :(try; ($ex) === true; catch; false; end))
end

"One watched line: sample `expr` every time `file:line` runs."
const DebugWatch = @NamedTuple{file::String, line::Int, expr::String}

"How many samples one watch keeps. A long run must not turn a diagnostic into a memory problem."
const WATCH_CAP = 200_000

"""
Record one sample, from inside a running frame.

Reached by VALUE from the compiled predicate rather than by name: the predicate is evaluated in
the notebook's namespace, where this function is not in scope under any name, and interpolating
the function object sidesteps the question entirely.

Non-numbers are skipped rather than stored: a trace is for plotting, and the question a watch
answers ("what has this been") is a numeric one. Anything that throws is skipped too — a watch
must never be able to break the run it is observing.
"""
function _watch_push!(store::Vector{Float64}, v)
    try
        x = Float64(v)
        length(store) < WATCH_CAP && push!(store, x)
    catch
    end
    return nothing
end

"""
Arm exactly `watches`, replacing whatever was set.

A watch is a breakpoint whose predicate has a side effect and then declines to stop. The predicate
runs in the frame at every execution of its line, which is precisely the sampling point wanted,
and returning `false` means the run never pauses. So this needs no interpreter machinery of its
own beyond what a conditional breakpoint already uses.
"""
function _set_watches!(s::_DebugSession, watches::Vector{DebugWatch})
    s.want_watches = copy(watches)
    _arm!(s)
end

"""
Arm every mark and watch, composing the ones that share a line.

JuliaInterpreter keeps ONE breakpoint per statement, so arming a watch and a mark at the same
`file:line` does not give you both — the second silently replaces the first, and whichever lost
stops working. That is not hypothetical: a watch on the line a predicate was armed on left the
predicate disarmed and the run went to completion without stopping.

So the two are built together. Each line gets a single condition that records every watch on it
and then answers with the mark's predicate, which is the behaviour wanted anyway: sample every
pass, stop on the pass that matters.
"""
function _arm!(s::_DebugSession)
    ji = _ji()
    for bp in s.marks;   try; ji.remove(bp); catch; end; end
    for bp in s.watches; try; ji.remove(bp); catch; end; end
    empty!(s.marks); empty!(s.watches)

    # (file, line) → the record-calls for it, and the mark predicate if one is armed there.
    recs = Dict{Tuple{String,Int},Vector{Expr}}()
    for w in s.want_watches
        w.line > 0 && !isempty(w.file) && !isempty(strip(w.expr)) || continue
        ex = try; Meta.parse(strip(w.expr)); catch; continue; end
        (ex isa Expr && ex.head === :incomplete) && continue
        store = get!(() -> Float64[], s.traces, String(w.expr))
        # The expression is evaluated INSIDE the try, not passed as an argument to a function that
        # catches: an argument is evaluated at the call site, so a watch on a name that does not
        # exist yet threw out of the condition and took the run down with it.
        push!(get!(() -> Expr[], recs, (String(w.file), Int(w.line))),
              :(try; $(_watch_push!)($store, $ex); catch; end))
    end

    lines = Set{Tuple{String,Int}}(keys(recs))
    for m in s.want_marks
        m.line > 0 && !isempty(m.file) || continue
        push!(lines, (String(m.file), Int(m.line)))
    end
    markcond = Dict((String(m.file), Int(m.line)) => m.cond for m in s.want_marks)

    for key in sort!(collect(lines))
        file, line = key
        body = Expr(:block, get(recs, key, Expr[])...)
        # What the composed condition finally ANSWERS, which is three different cases and not two:
        #   a mark with a predicate  → that predicate
        #   a mark without one       → `true`, stop every time
        #   watches only             → `false`, sample and never stop
        # Treating "no predicate" as "do not stop" disarmed every plain breakpoint.
        pred = _mark_condition(s, get(markcond, key, ""))
        push!(body.args, pred !== nothing ? pred[2] : haskey(markcond, key))
        bp = try; ji.breakpoint(file, line, (s.ns, body)); catch; nothing; end
        bp === nothing && continue
        haskey(markcond, key) ? push!(s.marks, bp) : push!(s.watches, bp)
    end
    return nothing
end

_watches_from(files::Vector{String}, lines::Vector{Int}, exprs::Vector{String}) =
    DebugWatch[(file = files[i], line = lines[i], expr = exprs[i])
               for i in 1:min(length(files), length(lines), length(exprs))]

"""
    debug_watch!(; watch_files, watch_lines, watch_exprs) -> DebugState

Replace the watched expressions. Existing traces for an expression that is still watched are kept,
so adding a second watch mid-run does not discard what the first has already collected.
"""
function debug_watch!(; watch_files::Vector{String} = String[],
                        watch_lines::Vector{Int} = Int[],
                        watch_exprs::Vector{String} = String[])::DebugState
    s = _DEBUG[]
    s === nothing && return _error_state("", "no debug session")
    bad = findfirst(e -> !isempty(_mark_cond_error(e)), watch_exprs)
    bad === nothing || return _error_state("",
        "watch expression does not parse: $(_mark_cond_error(watch_exprs[bad]))")
    for k in collect(keys(s.traces))                 # drop traces nobody is watching any more
        k in watch_exprs || delete!(s.traces, k)
    end
    _set_watches!(s, _watches_from(watch_files, watch_lines, watch_exprs))
    return _state(s)
end

"The samples each watched expression has collected so far — the full series, for plotting."
debug_traces() = (s = _DEBUG[]; s === nothing ? Dict{String,Vector{Float64}}() : deepcopy(s.traces))

"Per-watch summaries for a state payload, in the order the watches were declared."
function _trace_summaries(s::_DebugSession)
    out = DebugTrace[]
    for (k, xs) in sort!(collect(s.traces); by = first)
        isempty(xs) ?
            push!(out, (expr = k, n = 0, first = NaN, last = NaN, min = NaN, max = NaN)) :
            push!(out, (expr = k, n = length(xs), first = xs[1], last = xs[end],
                        min = minimum(xs), max = maximum(xs)))
    end
    return out
end

"Does this predicate parse? Reported at arm time, since a broken one is silent afterwards."
function _mark_cond_error(cond::AbstractString)
    isempty(strip(cond)) && return ""
    ex = try
        Meta.parse(strip(cond))
    catch e
        return sprint(showerror, e)
    end
    (ex isa Expr && ex.head === :incomplete) && return "incomplete expression"
    return ""
end

# The wire form is two parallel vectors of scalars rather than a vector of pairs: it
# is what survives the gate with the least ceremony (the `table_page` convention).
_marks_from(files::Vector{String}, lines::Vector{Int}, conds::Vector{String} = String[]) =
    DebugMark[(file = files[i], line = lines[i],
               cond = i <= length(conds) ? conds[i] : "")
              for i in 1:min(length(files), length(lines))]

# ── stepping ──────────────────────────────────────────────────────────────────

# `debug_command` advances one lowered expression, so several consecutive steps
# can sit on one source line. A step the user asked for should move somewhere
# visible, so advance until the position changes or the frame does.
function _advance!(s::_DebugSession, cmd::Symbol; max_micro::Int = 500,
                   skip::Union{Nothing,Tuple{String,Int}} = nothing)
    ji = _ji()
    start = (_frame_position(s.frame)..., objectid(s.frame))
    micro = 0
    s.at_breakpoint = false
    while true
        ret = try
            ji.debug_command(s.frame, cmd, true)
        catch e
            s.error = e
            s.finished = true
            s.frame = nothing
            return
        end
        micro += 1
        if ret === nothing
            # This top-level thunk is done; move to the next statement in the cell. Its writes
            # have landed now, which is what makes them this session's rather than last run's.
            s.result = try; ji.get_return(s.frame); catch; nothing; end
            union!(s.assigned, s.current_writes)
            _next_thunk!(s)
            return
        end
        s.frame = ret[1]
        s.steps += 1
        # Landing on an armed breakpoint ends the step, whatever was asked for — otherwise
        # `continue` walks straight through every one it hits.
        now = (_frame_position(s.frame)..., objectid(s.frame))
        s.at_breakpoint = _on_breakpoint(s.frame)
        # `skip` is the position the caller has already seen and wants to get past. A breakpoint
        # inside a loop is hit once per iteration, so plain `continue` lands on the same line over
        # and over; this walks through those without disarming anything, and still stops at a
        # DIFFERENT breakpoint or at the end.
        if s.at_breakpoint && skip !== nothing && (now[1], now[2]) == skip
            s.at_breakpoint = false
            micro >= max_micro && return
            continue
        end
        s.at_breakpoint && return
        (now != start || micro >= max_micro) && return
    end
end

function _next_thunk!(s::_DebugSession)
    ji = _ji()
    while !isempty(s.rest)
        (m, ex) = popfirst!(s.rest)
        # Kept in step with `rest` so the statement now being stepped knows what it will bind.
        s.current_writes = isempty(s.thunk_writes) ? Symbol[] : popfirst!(s.thunk_writes)
        fr = try; ji.Frame(m, ex); catch e; s.error = e; nothing; end
        s.error === nothing || (s.finished = true; s.frame = nothing; return)
        # A statement with no frame to build (a bare LineNumberNode) still counts as passed.
        fr === nothing && (union!(s.assigned, s.current_writes); continue)
        s.frame = fr
        return
    end
    s.current_writes = Symbol[]
    s.finished = true
    s.frame = nothing
    return
end

# ── RPC verbs ─────────────────────────────────────────────────────────────────

"A terminal state carrying only an explanation — same shape as any other, so a
viewer renders it without a special case."
_error_state(cell::AbstractString, msg::AbstractString)::DebugState =
    (cell = String(cell), finished = true, steps = 0, interpreting = String[],
     file = "", line = 0, scope = "", in_cell = false, at_breakpoint = false,
     source = "", srcfirst = 0, sources = DebugSource[],
     locals = DebugLocal[], bindings = DebugLocal[], stack = DebugFrame[],
     result = nothing, error = String(msg), traces = DebugTrace[])


"""
    debug_start!(ns; cell = cell, source = source) -> DebugState

Build a frame for the cell's code without running it. Returns the state before
the first line executes, so the caller sees the starting point rather than a
result.
"""
function debug_start!(ns::Module; cell::String = "", source::String = "",
                      mark_files::Vector{String} = String[],
                      mark_lines::Vector{Int} = Int[],
                      mark_conds::Vector{String} = String[],
                      watch_files::Vector{String} = String[],
                      watch_lines::Vector{Int} = Int[],
                      watch_exprs::Vector{String} = String[])::DebugState
    debug_stop!()
    ji = _ji()
    ex = try
        Meta.parseall(source; filename = "cell:$cell")
    catch e
        return _error_state(cell, sprint(showerror, e))
    end
    # An unfinished cell — a `function` with no `end`, an open paren — does NOT throw: `parseall`
    # hands back an `:incomplete` node and keeps going. Left alone, ExprSplitter builds a frame for
    # a cell that cannot run, and the session dies on the first step instead of at the door.
    inc = _incomplete(ex)
    inc === nothing || return _error_state(cell, inc)
    interpret = _interpret_set(ns)
    saved = _scope_interpreter!(interpret)
    pairs = Any[]
    try
        for p in ji.ExprSplitter(ns, ex)
            push!(pairs, p)
        end
    catch e
        _restore_interpreter!(saved)
        return _error_state(cell, sprint(showerror, e))
    end
    before = Set{Symbol}(_ns_names(ns))
    # What each top-level statement binds, in the order they will run — so a binding can be
    # reported as this session's only once the statement that writes it has actually finished.
    per_thunk = Vector{Symbol}[_toplevel_writes(p[2]) for p in pairs]
    s = _DebugSession(cell, nothing, pairs, ns, saved, interpret, false, nothing, nothing, 0,
                      _toplevel_writes(ex), before, false, Any[], Any[], Any[], Any[],
                      Dict{String,Vector{Float64}}(),
                      per_thunk, Symbol[], Set{Symbol}())
    # Armed before the first frame is built, so `continue` from the very first step honors them.
    _set_marks!(s, _marks_from(mark_files, mark_lines, mark_conds))
    _set_watches!(s, _watches_from(watch_files, watch_lines, watch_exprs))
    _next_thunk!(s)
    _DEBUG[] = s
    return _state(s)
end

"""
    debug_step!(mode) -> DebugState

`next` stays in this frame, `into` descends into an interpreted call, `out`
finishes the current frame, `continue` runs the rest of the cell.
"""
function debug_step!(; mode::String = "next")::DebugState
    s = _DEBUG[]
    s === nothing && return _error_state("", "no debug session — call start first")
    s.finished && return _state(s)
    # `:finish`, not `:so` — `so` is Debugger.jl's REPL key for this; JuliaInterpreter's
    # own command set is n / s / si / c / finish / until, and an unknown one throws.
    cmd = mode == "next"     ? :n      :
          mode == "into"     ? :s      :
          mode == "out"      ? :finish :
          mode == "continue" ? :c      :
          mode == "past"     ? :c      : nothing
    # Checked here rather than left to the interpreter: `_advance!` treats a throw as the run
    # ending, so an unrecognized verb would tear down a live session. Answer with the state as it
    # stands instead — nothing moved, and `steps` says so.
    cmd === nothing && return _state(s)
    if cmd === :c
        # `past` means "I have seen this one" — the line being stood on is skipped for the rest of
        # this step, so a breakpoint inside a loop does not stop on every iteration. The mark is
        # not disarmed: it still catches the next run, and a different breakpoint still stops this
        # one. Without it, getting out of a loop meant clearing the breakpoint and setting it again.
        skip = mode == "past" && s.frame !== nothing ? _frame_position(s.frame) : nothing
        # Run to the end of the cell — but each top-level statement is its own frame, so
        # "continue" has to walk from one to the next rather than stopping at the first
        # boundary. A breakpoint ends the walk: that is the whole point of setting one.
        while !s.finished
            _advance!(s, :c; skip = skip)
            s.at_breakpoint && break
        end
    else
        _advance!(s, cmd)
    end
    return _state(s)
end

"Current state without advancing."
function debug_frame()::DebugState
    s = _DEBUG[]
    s === nothing && return _error_state("", "no debug session")
    return _state(s)
end

"""
    debug_eval_expr(expr) -> DebugEval

Evaluate an expression in the paused frame's scope. The frame's locals are bound
first, so a probe sees exactly what the code sees at that line.
"""
function debug_eval_expr(; expr::String = "")::DebugEval
    s = _DEBUG[]
    s === nothing && return (ok = false, value = nothing, error = "no debug session")
    s.frame === nothing && return (ok = false, value = nothing, error = "session has finished")
    try
        val = _ji().eval_code(s.frame, expr)
        return (ok = true, value = _local_summary("value", val), error = nothing)
    catch e
        return (ok = false, value = nothing, error = sprint(showerror, e))
    end
end

"""
    debug_marks!(; mark_files, mark_lines) -> DebugState

Replace the session's breakpoints with exactly this set, without advancing. Answers
with the current state so a caller gets one shape back from every verb.
"""
function debug_marks!(; mark_files::Vector{String} = String[],
                        mark_lines::Vector{Int} = Int[],
                        mark_conds::Vector{String} = String[])::DebugState
    s = _DEBUG[]
    s === nothing && return _error_state("", "no debug session")
    bad = findfirst(c -> !isempty(_mark_cond_error(c)), mark_conds)
    bad === nothing || return _error_state("",
        "breakpoint condition does not parse: $(_mark_cond_error(mark_conds[bad]))")
    _set_marks!(s, _marks_from(mark_files, mark_lines, mark_conds))
    return _state(s)
end

"Abandon the session and put the interpreter's scope and breakpoint list back the way they were."
function debug_stop!()
    s = _DEBUG[]
    s === nothing && return (stopped = false, steps = 0)
    # Watches are process-global breakpoints like marks, so a session disarms what it armed —
    # otherwise a region worker returning to the warm pool carries them into the next notebook.
    try; s.want_marks = Any[]; s.want_watches = Any[]; _arm!(s); catch; end
    try; _restore_interpreter!(s.saved_compiled); catch; end
    _DEBUG[] = nothing
    return (stopped = true, steps = s.steps)
end
