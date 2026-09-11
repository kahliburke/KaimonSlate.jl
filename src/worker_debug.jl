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
    m = try
        getfield(getfield(Main, :Revise), :JuliaInterpreter)
    catch
        try
            @eval(Main, import JuliaInterpreter)
            getfield(Main, :JuliaInterpreter)
        catch
            nothing
        end
    end
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
        R = getfield(Main, :Revise)
        for (id, pkgdata) in R.pkgdatas
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

"""
One local, summarized.

Values are never sent: a frame on a compute node may hold tens of gigabytes, and
the point of building this against a remote region first was to make that
impossible to forget. The summary carries what a reader needs to decide whether
to ask for more.
"""
function _local_summary(name, value)
    t = try; string(typeof(value)); catch; "?"; end
    sz = try
        value isa AbstractArray ? string(size(value)) : ""
    catch
        ""
    end
    rep = try
        s = repr(value; context = IOContext(devnull, :limit => true, :compact => true))
        length(s) > 200 ? s[1:200] * "…" : s
    catch e
        "<repr failed: $(sprint(showerror, e))>"
    end
    Dict{String,Any}("name" => string(name), "type" => t, "size" => sz, "repr" => rep)
end

# Lowered code carries compiler temporaries and loop state with generated or empty
# names. They are noise in a variables pane.
_is_user_local(n) = (s = string(n); !isempty(s) && !startswith(s, "#") && s != "_")

function _frame_locals(fr)
    ji = _ji()
    out = Dict{String,Any}[]
    try
        for v in ji.locals(fr)
            _is_user_local(v.name) || continue
            push!(out, _local_summary(v.name, v.value))
        end
    catch
    end
    out
end

_frame_where(fr) = try
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
    (string(file), Int(line))
end

"The frame stack, outermost first, so a UI can render a call stack."
function _frame_stack(fr)
    ji = _ji()
    out = Dict{String,Any}[]
    f = fr
    while f !== nothing
        file, line = _frame_position(f)
        pushfirst!(out, Dict{String,Any}("file" => file, "line" => line, "where" => _frame_where(f)))
        f = try; ji.caller(f); catch; nothing; end
    end
    out
end

function _state(s::_DebugSession)
    st = Dict{String,Any}("cell" => s.cell, "finished" => s.finished, "steps" => s.steps,
                          "interpreting" => sort!([string(nameof(m)) for m in s.interpret]))
    if s.error !== nothing
        st["error"] = sprint(showerror, s.error)
    end
    if s.finished || s.frame === nothing
        st["result"] = s.error === nothing ? _local_summary("result", s.result) : nothing
        return st
    end
    file, line = _frame_position(s.frame)
    st["file"] = file
    st["line"] = line
    st["where"] = _frame_where(s.frame)
    # Specifically the cell being stepped, not merely "some cell": a function defined
    # in another cell reports `cell:<that one>`, and treating that as in-cell makes a
    # viewer highlight a line number that belongs to a different source.
    st["in_cell"] = (file == "cell:" * s.cell)
    st["locals"] = _frame_locals(s.frame)
    st["stack"] = _frame_stack(s.frame)
    return st
end

# ── stepping ──────────────────────────────────────────────────────────────────

# `debug_command` advances one lowered expression, so several consecutive steps
# can sit on one source line. A step the user asked for should move somewhere
# visible, so advance until the position changes or the frame does.
function _advance!(s::_DebugSession, cmd::Symbol; max_micro::Int = 500)
    ji = _ji()
    start = (_frame_position(s.frame)..., objectid(s.frame))
    micro = 0
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
            # This top-level thunk is done; move to the next statement in the cell.
            s.result = try; ji.get_return(s.frame); catch; nothing; end
            _next_thunk!(s)
            return
        end
        s.frame = ret[1]
        s.steps += 1
        now = (_frame_position(s.frame)..., objectid(s.frame))
        (now != start || micro >= max_micro) && return
    end
end

function _next_thunk!(s::_DebugSession)
    ji = _ji()
    while !isempty(s.rest)
        (m, ex) = popfirst!(s.rest)
        fr = try; ji.Frame(m, ex); catch e; s.error = e; nothing; end
        s.error === nothing || (s.finished = true; s.frame = nothing; return)
        fr === nothing && continue
        s.frame = fr
        return
    end
    s.finished = true
    s.frame = nothing
    return
end

# ── RPC verbs ─────────────────────────────────────────────────────────────────

"""
    debug_start!(ns; cell = cell, source = source) -> Dict

Build a frame for the cell's code without running it. Returns the state before
the first line executes, so the caller sees the starting point rather than a
result.
"""
function debug_start!(ns::Module; cell::String = "", source::String = "")
    debug_stop!()
    ji = _ji()
    ex = try
        Meta.parseall(source; filename = "cell:$cell")
    catch e
        return Dict{String,Any}("cell" => cell, "finished" => true,
                                "error" => sprint(showerror, e))
    end
    interpret = _interpret_set(ns)
    saved = _scope_interpreter!(interpret)
    pairs = Any[]
    try
        for p in ji.ExprSplitter(ns, ex)
            push!(pairs, p)
        end
    catch e
        _restore_interpreter!(saved)
        return Dict{String,Any}("cell" => cell, "finished" => true,
                                "error" => sprint(showerror, e))
    end
    s = _DebugSession(cell, nothing, pairs, ns, saved, interpret, false, nothing, nothing, 0)
    _next_thunk!(s)
    _DEBUG[] = s
    return _state(s)
end

"""
    debug_step!(mode) -> Dict

`next` stays in this frame, `into` descends into an interpreted call, `out`
finishes the current frame, `continue` runs the rest of the cell.
"""
function debug_step!(; mode::String = "next")
    s = _DEBUG[]
    s === nothing && return Dict{String,Any}("error" => "no debug session — call start first")
    s.finished && return _state(s)
    cmd = mode == "into"     ? :s  :
          mode == "out"      ? :so :
          mode == "continue" ? :c  : :n
    if cmd === :c
        # Run to the end, honoring the same interpret scope.
        while !s.finished
            _advance!(s, :c)
        end
    else
        _advance!(s, cmd)
    end
    return _state(s)
end

"Current state without advancing."
function debug_frame()
    s = _DEBUG[]
    s === nothing && return Dict{String,Any}("error" => "no debug session")
    return _state(s)
end

"""
    debug_eval_expr(expr) -> Dict

Evaluate an expression in the paused frame's scope. The frame's locals are bound
first, so a probe sees exactly what the code sees at that line.
"""
function debug_eval_expr(; expr::String = "")
    s = _DEBUG[]
    s === nothing && return Dict{String,Any}("error" => "no debug session")
    s.frame === nothing && return Dict{String,Any}("error" => "session has finished")
    ji = _ji()
    try
        val = ji.eval_code(s.frame, expr)
        return Dict{String,Any}("ok" => true, "value" => _local_summary("value", val))
    catch e
        return Dict{String,Any}("ok" => false, "error" => sprint(showerror, e))
    end
end

"Abandon the session and put the interpreter's scope back the way it was."
function debug_stop!()
    s = _DEBUG[]
    s === nothing && return Dict{String,Any}("stopped" => false)
    try; _restore_interpreter!(s.saved_compiled); catch; end
    _DEBUG[] = nothing
    return Dict{String,Any}("stopped" => true, "steps" => s.steps)
end
