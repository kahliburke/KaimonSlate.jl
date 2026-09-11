# ── Cell debugger: HTTP surface ───────────────────────────────────────────────────────────────────
#
# The stepper itself lives in worker_debug.jl, on whichever kernel the cell runs on
# (see `ReportEngine.debug_start!` and friends). This file is the hub's side: route
# a browser's stepping verbs to that kernel, and shape the reply for the viewer.
#
# Two things happen here and nowhere else.
#
# The SIDE is resolved once, at start, and remembered. A `region=`-tagged cell steps
# on its region's worker, which may be a machine on the other side of an SSH tunnel;
# every later verb has to reach that same worker, and the frame is the session, so a
# step sent to a different kernel would silently start over. Nothing else about the
# path is remote-aware — a region kernel is a GateKernel like any other.
#
# And CELL SOURCE is filled in here. A frame's `file` is a path on the kernel's
# machine; for code that came from a cell it reads `cell:<id>`, which is not a path
# at all and exists on no filesystem. The worker deliberately doesn't know the
# notebook's text, so the server — which does — supplies it. That also answers the
# case a remote can't: stepping into a function defined in a DIFFERENT cell.

# One session per notebook: the interpreter's scope is process-global (see
# `_scope_interpreter!`), so two at once on one kernel would fight over it.
#
# Which means a debugging agent and the person watching it share ONE session, and `owner` decides
# who it belongs to. A human's session is not an agent's to end or to take over — an agent that
# wants either has to ask, and wait for an answer. The reverse does not hold: a person may do
# whatever they like to a session an agent started, because it is their notebook.
struct DebugSession
    cell::String
    side::String       # region name; "" = this notebook's own kernel
    owner::String      # "human", or "agent:<id>"
end

const HUMAN = "human"
_is_agent(who::AbstractString) = startswith(who, "agent:")

const _DEBUG_LIVE = Dict{String,DebugSession}()   # nb.id → the session, while there is one
const _DEBUG_LOCK = ReentrantLock()

# Breakpoints outlive a session, because that is the order the work happens in: you mark a line,
# THEN start. They are kept per notebook here rather than in a kernel, so they survive a restart,
# a switch to a region, and the session they were set for.
#
# `file` is whatever a frame reports: `cell:<id>` for notebook code, a real path for a package.
# The server never interprets it — the kernel matches it against its own frames, which is the only
# place that can be done, because the path belongs to that machine.
const _DEBUG_MARKS = Dict{String,Set{Tuple{String,Int}}}()   # nb.id → {(file, line)}

_marks(nb::LiveNotebook) = lock(_DEBUG_LOCK) do
    sort!(collect(get(_DEBUG_MARKS, nb.id, Set{Tuple{String,Int}}())))
end

# Split for the wire: parallel scalar vectors ride the gate with the least ceremony.
function _marks_wire(nb::LiveNotebook)
    ms = _marks(nb)
    return (files = String[m[1] for m in ms], lines = Int[m[2] for m in ms])
end

const _NO_SESSION = DebugSession("", "", "")

_debug_session(nb::LiveNotebook) = lock(_DEBUG_LOCK) do
    get(_DEBUG_LIVE, nb.id, _NO_SESSION)
end

_debug_remember!(nb::LiveNotebook, cell::AbstractString, side::AbstractString, owner::AbstractString) =
    lock(_DEBUG_LOCK) do
        _DEBUG_LIVE[nb.id] = DebugSession(String(cell), String(side), String(owner))
    end

_debug_forget!(nb::LiveNotebook) = lock(_DEBUG_LOCK) do; delete!(_DEBUG_LIVE, nb.id); end

"Drop a closed notebook's breakpoints — the ids are reused when the same file is reopened."
forget_debug!(id::AbstractString) = lock(_DEBUG_LOCK) do
    delete!(_DEBUG_MARKS, String(id)); delete!(_DEBUG_LIVE, String(id))
end

"""
May `who` disturb this notebook's session — end it, or start a different one over it?

Yes when there is nothing running, when they own it, or when they are a person. No only in the
one case that matters: an agent reaching for a session a human is using. It has to ask (see
[`request_consent`](@ref)), the same way Kaimon's own debug tools will not resume out from under
someone who is still looking around.
"""
function may_disturb(nb::LiveNotebook, who::AbstractString)
    s = _debug_session(nb)
    isempty(s.cell) && return true
    s.owner == String(who) && return true
    return !_is_agent(who)
end

"The source of the cell a frame's pseudo-file names, or `nothing` when it isn't one."
function _cell_source(nb::LiveNotebook, file::AbstractString)
    startswith(file, "cell:") || return nothing
    id = chopprefix(String(file), "cell:")
    i = findfirst(c -> c.id == id, nb.report.cells)
    return i === nothing ? nothing : nb.report.cells[i].source
end

_local_json(v) = Dict{String,Any}("name" => v.name, "type" => v.type, "size" => v.size,
                                  "repr" => v.repr, "fresh" => v.fresh)

# A refusal is answered as a terminal debug state, not an HTTP error: the viewer already renders
# "the session ended, here is why", and giving it a second failure shape to handle earns nothing.
_debug_refuse(nb::LiveNotebook, cell::AbstractString, msg::AbstractString) =
    _json(_debug_json(nb, ReportEngine._error_state(cell, msg), ""))

"""
Shape a `DebugState` for the browser.

`source`/`srcfirst` are whatever the kernel could give; when the frame is a cell's
own code the kernel sends nothing and the notebook's copy goes in here instead,
starting at line 1. `side`/`where` say which machine this is happening on — the
answer is never implied by the notebook, because a single notebook can be stepping
code on a compute node while the rest of it runs locally.
"""
function _debug_json(nb::LiveNotebook, st, side::AbstractString)
    src, first = String(st.source), Int(st.srcfirst)
    if isempty(src)
        cs = _cell_source(nb, st.file)
        cs === nothing || (src = cs; first = 1)
    end
    # Every frame's source, not just the innermost — "why was this called with that?" is a
    # question about the caller. The kernel pools them by (file, first) so a recursive stack
    # ships one copy; cell pseudo-files it could not resolve are filled in from the notebook
    # here, which is the only place that knows them.
    srcs = Dict{String,Any}[]
    have = Dict{Tuple{String,Int},Int}()
    for s in st.sources
        push!(srcs, Dict{String,Any}("file" => s.file, "first" => s.first, "text" => s.text))
        have[(s.file, s.first)] = length(srcs)
    end
    frames = Dict{String,Any}[]
    for f in st.stack
        i = f.src
        if i == 0                                   # no method text: a cell's own top level
            cs = _cell_source(nb, f.file)
            if cs !== nothing
                i = get(have, (f.file, 1), 0)
                if i == 0
                    push!(srcs, Dict{String,Any}("file" => f.file, "first" => 1, "text" => cs))
                    i = length(srcs); have[(f.file, 1)] = i
                end
            end
        end
        push!(frames, Dict{String,Any}("file" => f.file, "line" => f.line, "scope" => f.scope, "src" => i))
    end
    return Dict{String,Any}(
        "cell" => st.cell, "finished" => st.finished, "steps" => st.steps,
        "interpreting" => collect(String, st.interpreting),
        "file" => st.file, "line" => st.line, "scope" => st.scope, "in_cell" => st.in_cell,
        "at_breakpoint" => st.at_breakpoint,
        "source" => src, "srcfirst" => first,
        "marks" => [Dict{String,Any}("file" => f, "line" => l) for (f, l) in _marks(nb)],
        "locals" => [_local_json(v) for v in st.locals],
        "bindings" => [_local_json(v) for v in st.bindings],
        "stack" => frames, "sources" => srcs,
        "result" => st.result === nothing ? nothing : _local_json(st.result),
        "error" => st.error,
        "side" => String(side), "where" => _side_label(nb, side),
        # Who is driving, and anything waiting on an answer. Both are shown, because a session
        # someone else is steering — or one stalled on a question — has to be legible as that.
        "owner" => _debug_session(nb).owner,
        "asks" => asks_json(nb),
    )
end

# Stepping is a gate round-trip that runs user code, so it takes the notebook's eval
# mutex exactly as a cell run does — never nb.lock, which a concurrent teardown needs
# (see the nb.lock protocol). Nothing is held across the round trip but this mutex,
# and the frame is a value on the far side rather than a blocked task, so there is no
# paused evaluation for a close to wait on.
_debug_on(nb::LiveNotebook, side::AbstractString, f) =
    lock(_eval_mutex(nb)) do
        f(_side_kernel!(nb, side))
    end

"""
Push the session to every open page.

The debugger has more than one driver: a reader clicking Next, and — once the debugging agent
lands — a specialist stepping on its own. A surface that only updated in response to its own
clicks would show nothing at all while something else drove, so every verb pushes, and the
browser applies what it is told rather than what it asked for.
"""
function _broadcast_debug(nb::LiveNotebook, payload::Dict{String,Any})
    try
        _broadcast(nb, "debug:" * JSON.json(payload))
    catch
    end
    return nothing
end

# Answer the caller AND push the same payload, so the page that asked and the pages that didn't
# end up in the same state. Called by the VERBS, not by the routes: an agent reaches them over
# MCP and never touches a route, and a session only it could see would be the opposite of the
# point. Returns its argument so a verb can end `return _pushed(nb, j)`.
function _pushed(nb::LiveNotebook, j::Dict{String,Any})
    _broadcast_debug(nb, j)
    return j
end

"""
    stop_debug!(nb; serialize = true)

End the notebook's debug session if it has one. Called on close and kernel restart as
well as from the UI, and that is not housekeeping: the interpreter's compiled-module
scope is process-global (`_scope_interpreter!`), so a session left open on a region
worker that merely DETACHES would hand the next notebook to adopt it an interpreter
still scoped to this one's modules.

`serialize=false` skips the eval mutex, for teardown paths where an in-flight
evaluation may still be draining and waiting for it could wedge the close. Stopping
only restores a global and drops a reference, so it is safe to run beside an eval —
unlike a step, which executes user code.
"""
function stop_debug!(nb::LiveNotebook; serialize::Bool = true, by::AbstractString = HUMAN, force::Bool = false)
    s = _debug_session(nb)
    isempty(s.cell) && return false
    # An agent may not close a session it does not own without being told it can. `force` is for
    # the callers that are not a decision at all — notebook close, kernel restart — where the
    # session is going away whatever anyone thinks.
    if !force && !may_disturb(nb, by) &&
       !request_consent(nb, DEBUG_ROLE, by, "may I end the debug session?")
        return false
    end
    _debug_forget!(nb)
    try
        serialize ? _debug_on(nb, s.side, k -> ReportEngine.debug_stop!(k, nb.report)) :
                    ReportEngine.debug_stop!(_side_kernel!(nb, s.side), nb.report)
    catch e
        @debug "debug: stop failed (session dropped anyway)" exception = e
    end
    _broadcast_debug(nb, Dict{String,Any}("session" => false, "marks" => _marks_json(nb)))
    return true
end


# ── the verbs ─────────────────────────────────────────────────────────────────────────────────────
#
# Written as functions on the notebook, not inline in the routes, because the browser is not the
# only caller: the debugging agent drives the same session through MCP. One implementation means a
# specialist and a reader cannot end up with different semantics for `step`.

_marks_json(nb::LiveNotebook) = [Dict{String,Any}("file" => f, "line" => l) for (f, l) in _marks(nb)]

"""
    start_debug!(nb, cell; source) -> Dict

Begin stepping `cell`. `source` overrides the cell's saved text — the browser sends its editor's
current contents, so you step what you are looking at rather than what was last written to disk.
"""
function start_debug!(nb::LiveNotebook, cid::AbstractString; source::AbstractString = "", by::AbstractString = HUMAN)
    i = findfirst(c -> c.id == cid, nb.report.cells)
    i === nothing && return _debug_json(nb, ReportEngine._error_state(cid, "there is no cell '$cid' to step"), "")
    cell = nb.report.cells[i]
    ReportEngine.is_code_kind(cell.kind) ||
        return _debug_json(nb, ReportEngine._error_state(cid, "only a code cell can be stepped"), "")
    src = isempty(source) ? cell.source : String(source)
    # Starting is not gated: anyone may open a session, and an agent deciding to start one is
    # ordinary work. What is gated is ENDING someone else's — so the question belongs to
    # `stop_debug!`, which asks only when there is really something of theirs to end. A refusal
    # there stops the start too, because the session in progress is still in progress.
    if !stop_debug!(nb; by = by) && !isempty(_debug_session(nb).cell)
        return _debug_json(nb, ReportEngine._error_state(cid, "the session in progress was left as it was"), "")
    end
    _, side = _region_route(nb, cell)
    mk = _marks_wire(nb)
    st = _debug_on(nb, side, k ->
        ReportEngine.debug_start!(k, nb.report; cell = String(cid), source = src,
                                  mark_files = mk.files, mark_lines = mk.lines))
    st.error === nothing && _debug_remember!(nb, cid, side, by)
    return _pushed(nb, _debug_json(nb, st, side))
end

"""
`next` | `into` | `out` | `continue`.

Stepping is not gated on ownership. Two drivers on one session is confusing, but it is the
person's notebook and their own hands should always work; an agent stepping a session a human
owns is how you take the controls back from it mid-thought.
"""
function step_debug!(nb::LiveNotebook, mode::AbstractString = "next")
    s = _debug_session(nb)
    isempty(s.cell) && return _debug_json(nb, ReportEngine._error_state("", "this notebook has no debug session"), "")
    st = _debug_on(nb, s.side, k -> ReportEngine.debug_step!(k, nb.report; mode = String(mode)))
    st.finished && _debug_forget!(nb)
    return _pushed(nb, _debug_json(nb, st, s.side))
end

"The current frame without advancing. `session` says whether there is one at all."
function frame_debug(nb::LiveNotebook)
    s = _debug_session(nb)
    isempty(s.cell) &&
        return Dict{String,Any}("session" => false, "marks" => _marks_json(nb), "asks" => asks_json(nb))
    st = _debug_on(nb, s.side, k -> ReportEngine.debug_frame(k, nb.report))
    j = _debug_json(nb, st, s.side); j["session"] = true
    return j
end

"Evaluate in the paused frame — where the values are, which may be another machine."
function eval_debug(nb::LiveNotebook, expr::AbstractString)
    s = _debug_session(nb)
    isempty(s.cell) &&
        return Dict{String,Any}("ok" => false, "value" => nothing, "error" => "this notebook has no debug session")
    ev = _debug_on(nb, s.side, k -> ReportEngine.debug_eval_expr(k, nb.report; expr = String(expr)))
    r = Dict{String,Any}("ok" => ev.ok, "error" => ev.error, "expr" => String(expr),
                         "value" => ev.value === nothing ? nothing : _local_json(ev.value))
    # An evaluation moves no frame, but it is still something that happened in the session —
    # pushed so a reader watching an agent work sees the questions it asked, not only its answers.
    _broadcast_debug(nb, Dict{String,Any}("probe" => r))
    return r
end

"""
    mark_debug!(nb, file, line; on) -> Dict

Arm or clear a breakpoint. `on === nothing` toggles, which is what a gutter click wants. Allowed
with no session running: marking a line and then starting is the normal order of the work.
"""
function mark_debug!(nb::LiveNotebook, file::AbstractString, line::Integer; on::Union{Bool,Nothing} = nothing)
    (isempty(file) || line <= 0) && return Dict{String,Any}("ok" => false,
                                                            "error" => "a breakpoint needs a file and a line",
                                                            "marks" => _marks_json(nb))
    armed = lock(_DEBUG_LOCK) do
        set = get!(() -> Set{Tuple{String,Int}}(), _DEBUG_MARKS, nb.id)
        key = (String(file), Int(line))
        want = on === nothing ? !(key in set) : on
        want ? push!(set, key) : delete!(set, key)
        want
    end
    s = _debug_session(nb)
    if !isempty(s.cell)          # live session: re-arm now, else it waits for the next start
        mk = _marks_wire(nb)
        _debug_on(nb, s.side, k ->
            ReportEngine.debug_marks!(k, nb.report; mark_files = mk.files, mark_lines = mk.lines))
    end
    r = Dict{String,Any}("ok" => true, "on" => armed, "file" => String(file), "line" => Int(line),
                         "marks" => _marks_json(nb))
    _broadcast_debug(nb, Dict{String,Any}("marks" => r["marks"]))
    return r
end

# ── the debugger, as a specialist role ────────────────────────────────────────────────────────────
#
# Everything above is the debugger APPLICATION: the stepping session, who owns it, and the verbs
# that drive it. What follows is only its registration as one kind of specialist — the summoning,
# briefing, asking, paging and signing-off all live in server_specialists.jl and know nothing about
# debugging. A profiler or a data-explorer is another `Specialist` value and nothing else.

const DEBUG_ROLE = "debugger"

"The verbs a debugging specialist may call. This list IS its job description."
const DEBUG_VERBS = String["dbg_start", "dbg_step", "dbg_frame", "dbg_eval",
                           "dbg_break", "dbg_ask", "dbg_done"]

const DEBUG_BRIEF = """
You are a debugging specialist working inside a Slate notebook, alongside the person who called
you in. You are not a general assistant and this is not a notebook-authoring turn: you have one
job, which is to find out why a piece of code does what it does.

Your tools are the debugger and nothing else — start a session on a cell, step (next / into / out
/ continue), read the frame, evaluate an expression where the frame is, set a breakpoint, ask,
and finish. You cannot edit files, run shell commands or browse. You do not need to.

How to work:

- Look before you step. Reading the frame costs nothing and tells you the line, its source, the
  call stack, every local, and the cell's module bindings.
- Form a hypothesis and test it by evaluating in the paused frame's own scope. That is the fastest
  instrument you have; use it far more than you step.
- On a loop, set a breakpoint and continue. Stepping through iterations is how a session dies of
  old age.
- Starting a cell again re-runs it from the top — that is how you watch a block a second time.
- The values you see are SUMMARIES. A frame may be on another machine holding far more than could
  be sent. If a summary is not enough, evaluate something that answers your question there
  (a length, a count, a slice, a predicate) rather than asking for the whole value.
- A binding marked as the previous run's has not been reassigned yet in this session. Do not read
  it as the current state.

What you do not know: why this notebook exists, what the person is ultimately trying to do, or
what "correct" means here. When the next move turns on any of that, ASK and WAIT. It blocks until
someone answers, and asking a specific question is not an interruption — it is the reason you are
narrow.

The session may belong to the person. If you try to take one that is theirs you will be asked, and
they may say no; that is not an error, and you should carry on looking rather than insisting.
Their hands always work, so the frame can move under you — re-read it if you are surprised.

When you have an answer, or you have run out of ideas, or going further would not help, finish and
say what you found. Deciding you are done is yours to make. Say what is true, including "I could
not work it out" — a wrong confident answer costs more than an honest empty one.

Be brief in chat. Say what you are about to look at and why, then look.
"""

"What the subject cell's upstream neighbours are, so a specialist starts oriented."
function _cell_context(nb::LiveNotebook, cid::AbstractString)
    i = findfirst(c -> c.id == cid, nb.report.cells)
    i === nothing && return ""
    cell = nb.report.cells[i]
    io = IOBuffer()
    println(io, "Cell `", cid, "`", isempty(_cell_region(cell)) ? "" : " (runs on region " * _cell_region(cell) * ")", ":")
    println(io, "```julia\n", rstrip(cell.source), "\n```")
    # What it does NOW — the error if it has one, else its value. Both fields are nullable.
    o = cell.output
    txt(x) = x === nothing ? "" : String(x)
    if o !== nothing && !isempty(txt(o.exception))
        println(io, "\nIt currently fails with:\n```\n", first(txt(o.exception), 1200), "\n```")
    elseif o !== nothing && !isempty(txt(o.value_repr))
        println(io, "\nIt currently evaluates to: `", first(txt(o.value_repr), 300), "`")
    end
    ups = String[]
    for c in nb.report.cells
        c.id == cid && break
        isempty(intersect(c.writes, cell.reads)) || push!(ups, c.id)
    end
    isempty(ups) || println(io, "\nIts inputs come from: ", join(ups, ", "),
                            " — a function defined in one of those reports its file as `cell:<that id>`.")
    return String(take!(io))
end

"The opening turn for a debugging specialist: this notebook, this cell, right now."
function debug_briefing(nb::LiveNotebook, cid::AbstractString, task::AbstractString)
    io = IOBuffer()
    println(io, "Notebook `", nb.id, "` (", basename(nb.path), ").")
    println(io)
    println(io, _cell_context(nb, cid))
    s = _debug_session(nb)
    if !isempty(s.cell)
        println(io, "\nThere is already a session on cell `", s.cell, "`, owned by ", s.owner,
                s.owner == HUMAN ? " — ask before taking it." : ".")
    end
    ms = _marks(nb)
    isempty(ms) || println(io, "\nBreakpoints already set: ",
                           join([string(f, ":", l) for (f, l) in ms], ", "))
    println(io)
    println(io, isempty(strip(task)) ?
        "Find out what this cell actually does, and report anything that looks wrong." : strip(task))
    return String(take!(io))
end

register_specialist!(Specialist(DEBUG_ROLE; brief = DEBUG_BRIEF, verbs = DEBUG_VERBS,
                                briefing = debug_briefing))

# ── routes (called from `_make_router`) ───────────────────────────────────────────────────────────

function _register_debug_routes!(router, h::Hub)
    # Thin: the verbs already push, so a route only has to turn the answer into a response.
    HTTP.register!(router, "POST", "/api/{id}/debug/start", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        _json(start_debug!(nb, String(get(b, "cell", "")); source = String(get(b, "source", ""))))
    end))
    HTTP.register!(router, "POST", "/api/{id}/debug/step", req -> _withnb(h, req, nb ->
        _json(step_debug!(nb, String(get(_body(req), "mode", "next"))))))
    # Read-only, so it answers the asker without telling everyone.
    HTTP.register!(router, "GET", "/api/{id}/debug/frame", req -> _withnb(h, req, nb -> _json(frame_debug(nb))))
    HTTP.register!(router, "POST", "/api/{id}/debug/eval", req -> _withnb(h, req, nb ->
        _json(eval_debug(nb, String(get(_body(req), "expr", ""))))))
    HTTP.register!(router, "POST", "/api/{id}/debug/stop", req -> _withnb(h, req, nb ->
        _json(Dict{String,Any}("stopped" => stop_debug!(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/debug/mark", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        on = haskey(b, "on") ? (get(b, "on", true) === true) : nothing
        _json(mark_debug!(nb, String(get(b, "file", "")), Int(get(b, "line", 0)); on = on))
    end))
    HTTP.register!(router, "GET", "/api/{id}/debug/marks", req -> _withnb(h, req, nb ->
        _json(Dict{String,Any}("marks" => _marks_json(nb)))))
    # Summon a specialist onto a cell. Answers as soon as it is briefed — the work happens in the
    # chat pane from there, which is the point of summoning one rather than requesting a report.
    HTTP.register!(router, "POST", "/api/{id}/debug/agent", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        cid = String(get(b, "cell", ""))
        isempty(cid) && (cid = _debug_session(nb).cell)
        isempty(cid) && return _json(Dict{String,Any}("ok" => false, "error" => "no cell to debug"))
        try
            _json(summon!(nb, DEBUG_ROLE; subject = cid, model = String(get(b, "model", "")),
                                   task = String(get(b, "task", ""))))
        catch e
            _json(Dict{String,Any}("ok" => false, "error" => first(sprint(showerror, e), 300)))
        end
    end))
    # What the specialist was told: standing brief, allowed tools, opening turn.
    HTTP.register!(router, "GET", "/api/{id}/debug/brief", req -> _withnb(h, req, nb ->
        _json(brief_of(nb, DEBUG_ROLE))))
    # Answer an agent's question or consent request — this is what unblocks its turn.
    HTTP.register!(router, "POST", "/api/{id}/debug/answer", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        ok = answer_ask!(nb, String(get(b, "id", "")), String(get(b, "text", "")))
        _json(Dict{String,Any}("ok" => ok, "asks" => asks_json(nb)))
    end))
    return router
end
