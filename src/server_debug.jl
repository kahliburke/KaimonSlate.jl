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
# Keyed by `(file, line)` with the predicate as the VALUE, not part of the key: a line is one
# breakpoint whether or not it carries a condition, so editing the predicate changes that mark
# instead of arming a second one on the same line.
const _DEBUG_MARKS = Dict{String,Dict{Tuple{String,Int},String}}()   # nb.id → {(file,line) => cond}

# Watches live beside marks and outlive a session the same way: you decide what to plot before you
# start, and re-running the cell should keep plotting it.
const _DEBUG_WATCHES = Dict{String,Dict{Tuple{String,Int},String}}()  # nb.id → {(file,line) => expr}

# A LIVE watch is the other half of the idea, and it has no line: it is a piece of the notebook
# re-evaluated every time the session stops, so its output tracks the run. `source` is either Julia
# text or `cell:<id>`, naming a cell whose source is fetched at each evaluation — so a chart you
# already wrote becomes a live view by pointing at it, and editing that cell updates what you see.
#
# These evaluate in the notebook's NAMESPACE rather than the paused frame. What makes them useful
# is reading the values the stepped cell is building, and a cell's top-level writes land in the
# namespace as each statement completes — so a referenced chart redraws as the run progresses.
# Frame locals are the scratchpad's job, and a sampled watch's.
const _DEBUG_LIVE_WATCH = Dict{String,Vector{String}}()      # nb.id → [source]

_live_watches(nb::LiveNotebook) = lock(_DEBUG_LOCK) do
    copy(get(_DEBUG_LIVE_WATCH, nb.id, String[]))
end

"""
Bind the paused frame's locals around `src`, so a watch written against them resolves.

Only the NAMES appear in the generated source: a value has no source form, so it arrives at run
time through the dict the kernel published. Notebook globals still resolve; a local of the same
name shadows one, which is the scoping a reader expects from the line they are stopped on.

With no frame — no session, or a finished one — this is the identity, and the watch falls back to
namespace scope rather than failing. A chart over accumulated results is still worth seeing after
the run ends.
"""
function _wrap_frame_scope(src::AbstractString, names::Vector{String})
    isempty(names) && return String(src)
    binds = join(["$(n) = $(ReportEngine.FRAME_BINDING)[:$(n)]" for n in names], ", ")
    return "let " * binds * "\n" * String(src) * "\nend"
end

"Resolve a live watch to the Julia it should run: literal text, or the named cell's source."
function _live_source(nb::LiveNotebook, spec::AbstractString)
    startswith(spec, "cell:") || return String(spec)
    id = chopprefix(String(spec), "cell:")
    i = findfirst(c -> c.id == id, nb.report.cells)
    return i === nothing ? "" : String(nb.report.cells[i].source)
end

"""
    live_watch!(nb, source; on) -> Dict

Add or remove a live watch. `source` is Julia, or `cell:<id>` to track a cell.
"""
function live_watch!(nb::LiveNotebook, source::AbstractString; on::Union{Bool,Nothing} = nothing)
    src = String(strip(source))
    isempty(src) && return Dict{String,Any}("ok" => false, "error" => "a live watch needs an expression or a cell",
                                            "live" => _live_watches(nb))
    lock(_DEBUG_LOCK) do
        v = get!(() -> String[], _DEBUG_LIVE_WATCH, nb.id)
        want = on === nothing ? !(src in v) : on
        want ? (src in v || push!(v, src)) : filter!(!=(src), v)
    end
    r = Dict{String,Any}("ok" => true, "live" => _live_watches(nb))
    _broadcast_debug(nb, Dict{String,Any}("live" => r["live"]))
    return r
end

"""
How a live watch's run turned out: `ok`, `unavailable`, or `error`.

`unavailable` is what a watch looks like from a frame where its names do not exist, which happens
constantly while stepping and is not worth a red box. Julia reports exactly that as an
`UndefVarError`, so it is separable from a genuine mistake in the expression.
"""
function _live_status(out)
    ex = try; out.exception; catch; nothing; end
    ex === nothing && return ("ok", "")
    txt = string(ex)
    occursin("UndefVarError", txt) && return ("unavailable", first(txt, 200))
    return ("error", first(txt, 200))
end

"""
Re-evaluate every live watch and push the results.

Runs after a step, on the notebook's eval mutex exactly as a cell does — a live watch is ordinary
notebook code and must not race the stepper's own round trip. Each result is broadcast as a cell,
so the browser renders it with the SAME pipeline a cell's output uses: a plot is a plot, an echart
is an echart, a table is a table. Nothing here knows what a chart is.
"""
function refresh_live_watches!(nb::LiveNotebook)
    specs = _live_watches(nb)
    isempty(specs) && return nothing
    s = _debug_session(nb)
    # Locals are published ONCE per refresh, not once per watch: they are the same frame for all
    # of them, and the round trip is the expensive part.
    names = isempty(s.cell) ? String[] :
        (try; _debug_on(nb, s.side, k -> ReportEngine.debug_frame_locals!(k, nb.report)); catch; String[]; end)
    for (i, spec) in enumerate(specs)
        src = _live_source(nb, spec)
        isempty(strip(src)) && continue
        # A CELL reference is notebook code and names notebook globals, so it runs as written. A
        # CUSTOM expression is the one you write to look at locals, so it gets the frame — which
        # is the whole reason for writing one instead of pointing at a cell.
        run_src = startswith(spec, "cell:") ? src : _wrap_frame_scope(src, names)
        cell = Cell(string("__dbglive", i), CODE, src)   # show what was WRITTEN, not the wrapper
        ReportEngine.mark_running!(cell)
        out = try
            lock(_eval_mutex(nb)) do
                ReportEngine.eval_capture(nb.kernel, nb.report, run_src, "dbglive")
            end
        catch e
            # A watch that cannot run is ordinary, not a fault: it must never take the session
            # with it. The stepper is what matters here and it is not this watch's business.
            _broadcast_debug(nb, Dict{String,Any}("livecell" => Dict{String,Any}(
                "spec" => spec, "status" => "error", "why" => first(sprint(showerror, e), 200))))
            continue
        end
        ReportEngine.mark_result!(cell, out)
        # The SAME payload a scratch cell rides on, so the browser renders it with the cell
        # renderer rather than anything this feature invents. A plot is a plot because nothing
        # here decided otherwise.
        # Three states, not two, and the difference is the point. An expression naming something
        # that is not in THIS frame is the normal condition of stepping — you walk into a method
        # where `u` does not exist — so it reports as unavailable and the tile goes quiet. A real
        # error is shown. Neither may leave the previous render on screen looking current: a stale
        # chart presented as live is worse than an empty one.
        status, why = _live_status(out)
        _broadcast_debug(nb, Dict{String,Any}("livecell" => Dict{String,Any}(
            "spec" => spec, "status" => status, "why" => why,
            "cell" => status == "ok" ? scratch_cell_json(cell) : nothing)))
    end
    return nothing
end

_watches(nb::LiveNotebook) = lock(_DEBUG_LOCK) do
    d = get(_DEBUG_WATCHES, nb.id, Dict{Tuple{String,Int},String}())
    [(k[1], k[2], v) for (k, v) in sort!(collect(d); by = first)]
end

function _watches_wire(nb::LiveNotebook)
    ws = _watches(nb)
    return (files = String[w[1] for w in ws], lines = Int[w[2] for w in ws],
            exprs = String[w[3] for w in ws])
end

_watches_json(nb::LiveNotebook) =
    [Dict{String,Any}("file" => f, "line" => l, "expr" => e) for (f, l, e) in _watches(nb)]

_marks(nb::LiveNotebook) = lock(_DEBUG_LOCK) do
    d = get(_DEBUG_MARKS, nb.id, Dict{Tuple{String,Int},String}())
    [(k[1], k[2], v) for (k, v) in sort!(collect(d); by = first)]
end

# Split for the wire: parallel scalar vectors ride the gate with the least ceremony.
function _marks_wire(nb::LiveNotebook)
    ms = _marks(nb)
    return (files = String[m[1] for m in ms], lines = Int[m[2] for m in ms],
            conds = String[m[3] for m in ms])
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
    delete!(_DEBUG_MARKS, String(id)); delete!(_DEBUG_WATCHES, String(id))
    delete!(_DEBUG_LIVE, String(id))
end

"""
May `who` disturb this notebook's session — end it, or start a different one over it?

Yes when there is nothing running, when they own it, or when they are a person: it is their
notebook. Yes also for the ORCHESTRATOR that summoned the specialist holding it, because
supervising includes deciding the work is finished — an agent that can start a specialist but not
stop one is not supervising it, only launching it. That is the one case where an agent may end
another's session, and it exists only because `summon!` recorded who summoned whom.

No for any other agent, which is the case that matters: one reaching for a session a human is
using. It has to ask (see [`request_consent`](@ref)), the same way Kaimon's own debug tools will
not resume out from under someone who is still looking around.
"""
function may_disturb(nb::LiveNotebook, who::AbstractString)
    s = _debug_session(nb)
    isempty(s.cell) && return true
    s.owner == String(who) && return true
    _is_agent(who) || return true
    # The session's owner is the specialist; this asks whether `who` is the agent that summoned it.
    return !isempty(s.owner) && orchestrator_of(nb, DEBUG_ROLE) == String(who)
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
        "marks" => _marks_json(nb), "watches" => _watches_json(nb),
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
        # Summaries only. The series drives the chart and is fetched separately; putting it here
        # would push a hundred thousand samples through every step.
        "live" => _live_watches(nb),
        "traces" => [Dict{String,Any}("expr" => t.expr, "n" => t.n, "first" => t.first,
                                      "last" => t.last, "min" => t.min, "max" => t.max)
                     for t in (hasproperty(st, :traces) ? st.traces : [])],
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
    _broadcast_debug(nb, Dict{String,Any}("session" => false, "marks" => _marks_json(nb),
                                          "watches" => _watches_json(nb)))
    return true
end


# ── the verbs ─────────────────────────────────────────────────────────────────────────────────────
#
# Written as functions on the notebook, not inline in the routes, because the browser is not the
# only caller: the debugging agent drives the same session through MCP. One implementation means a
# specialist and a reader cannot end up with different semantics for `step`.

_marks_json(nb::LiveNotebook) =
    [Dict{String,Any}("file" => f, "line" => l, "cond" => c) for (f, l, c) in _marks(nb)]

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
    wt = _watches_wire(nb)
    st = _debug_on(nb, side, k ->
        ReportEngine.debug_start!(k, nb.report; cell = String(cid), source = src,
                                  mark_files = mk.files, mark_lines = mk.lines,
                                  mark_conds = mk.conds,
                                  watch_files = wt.files, watch_lines = wt.lines,
                                  watch_exprs = wt.exprs))
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
    r = _pushed(nb, _debug_json(nb, st, s.side))
    # After the frame is published, not before: the tiles should follow the step rather than delay
    # it, and a watch that takes a second to draw must not make the step feel like it took one.
    # Detached for the same reason — nothing about stepping waits on a watch.
    @async try; refresh_live_watches!(nb); catch; end
    return r
end

"The current frame without advancing. `session` says whether there is one at all."
function frame_debug(nb::LiveNotebook)
    s = _debug_session(nb)
    isempty(s.cell) &&
        return Dict{String,Any}("session" => false, "marks" => _marks_json(nb),
                                "watches" => _watches_json(nb), "asks" => asks_json(nb))
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
    watch_debug!(nb, file, line; expr) -> Dict

Sample `expr` every time `file:line` runs, without stopping. An empty `expr` clears the watch.

Separate from a breakpoint even when they share a line: one asks to be interrupted, the other asks
to be shown a history, and you usually want both on the same line — sample every pass, stop on the
pass that matters.
"""
function watch_debug!(nb::LiveNotebook, file::AbstractString, line::Integer;
                      expr::AbstractString = "")
    (isempty(file) || line <= 0) && return Dict{String,Any}("ok" => false,
                                                            "error" => "a watch needs a file and a line",
                                                            "watches" => _watches_json(nb))
    lock(_DEBUG_LOCK) do
        d = get!(() -> Dict{Tuple{String,Int},String}(), _DEBUG_WATCHES, nb.id)
        key = (String(file), Int(line))
        isempty(strip(expr)) ? delete!(d, key) : (d[key] = String(strip(expr)))
    end
    s = _debug_session(nb)
    if !isempty(s.cell)          # live session: re-arm now, else it waits for the next start
        wt = _watches_wire(nb)
        _debug_on(nb, s.side, k ->
            ReportEngine.debug_watch!(k, nb.report; watch_files = wt.files,
                                      watch_lines = wt.lines, watch_exprs = wt.exprs))
    end
    r = Dict{String,Any}("ok" => true, "file" => String(file), "line" => Int(line),
                         "expr" => String(strip(expr)), "watches" => _watches_json(nb))
    _broadcast_debug(nb, Dict{String,Any}("watches" => r["watches"]))
    return r
end

"The samples each watched expression has collected, as plain arrays the browser can plot."
function traces_debug(nb::LiveNotebook)
    s = _debug_session(nb)
    isempty(s.cell) && return Dict{String,Any}("ok" => true, "traces" => Dict{String,Any}())
    tr = try
        _debug_on(nb, s.side, k -> ReportEngine.debug_traces(k, nb.report))
    catch e
        return Dict{String,Any}("ok" => false, "error" => sprint(showerror, e))
    end
    return Dict{String,Any}("ok" => true, "traces" => tr)
end

"""
    mark_debug!(nb, file, line; on, cond) -> Dict

Arm or clear a breakpoint. `on === nothing` toggles, which is what a gutter click wants. Allowed
with no session running: marking a line and then starting is the normal order of the work.
"""
function mark_debug!(nb::LiveNotebook, file::AbstractString, line::Integer;
                     on::Union{Bool,Nothing} = nothing, cond::Union{String,Nothing} = nothing)
    (isempty(file) || line <= 0) && return Dict{String,Any}("ok" => false,
                                                            "error" => "a breakpoint needs a file and a line",
                                                            "marks" => _marks_json(nb))
    armed = lock(_DEBUG_LOCK) do
        d = get!(() -> Dict{Tuple{String,Int},String}(), _DEBUG_MARKS, nb.id)
        key = (String(file), Int(line))
        # Setting a condition arms the line if it was not armed: asking for a predicate is asking
        # to stop there, and a predicate on a line nobody is watching would do nothing.
        want = on !== nothing ? on : cond !== nothing ? true : !haskey(d, key)
        want ? (d[key] = cond === nothing ? get(d, key, "") : String(cond)) : delete!(d, key)
        want
    end
    s = _debug_session(nb)
    if !isempty(s.cell)          # live session: re-arm now, else it waits for the next start
        mk = _marks_wire(nb)
        _debug_on(nb, s.side, k ->
            ReportEngine.debug_marks!(k, nb.report; mark_files = mk.files, mark_lines = mk.lines,
                                      mark_conds = mk.conds))
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
                           "dbg_break", "dbg_watch", "dbg_ask", "dbg_choose", "dbg_done"]

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
  old age. That breakpoint is hit on EVERY iteration, so once you have seen what the line does,
  use `past` rather than continuing onto it again and again; it leaves the breakpoint armed. Once you have seen what that line does,  continues without stopping on it again,
  so you do not have to clear the breakpoint and set it back.
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
say what you found. Deciding you are done is yours to make — and if an orchestrator summoned you,
it may also decide, since it can see a goal you cannot. Say what is true, including "I could
not work it out" — a wrong confident answer costs more than an honest empty one.

Be brief in chat. Say what you are about to look at and why, then look.
"""

"""
The subject cell and where its inputs come from, so a specialist starts oriented.

Not `_cell_context` (server_export.jl), which builds the same idea for a CHAT turn: that one opens
by explaining that the user clicked ✨ and tells the agent which of `slate_read` / `slate_view` to
reach for, and a specialist has neither. Same question, different reader.
"""
function _specialist_cell_context(nb::LiveNotebook, cid::AbstractString)
    cells = nb.report.cells
    i = findfirst(c -> c.id == cid, cells)
    i === nothing && return ""
    cell = cells[i]
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
    # The whole upstream cone, not just cells it reads from directly: a function it calls may be
    # defined two cells back, and stepping into that reports `cell:<that id>` as its file.
    byid = Dict(c.id => c for c in cells)
    up = Set{String}(); frontier = String[cid]
    while !isempty(frontier)
        c = get(byid, pop!(frontier), nothing); c === nothing && continue
        for d in c.deps
            (d == cid || d in up) && continue
            push!(up, d); push!(frontier, d)
        end
    end
    if !isempty(up)
        println(io, "\nIts inputs come from these cells, whose code it can step into. A function",
                " defined in one reports its file as `cell:<that id>`:")
        for c in cells
            c.id in up || continue
            println(io, "  [`", c.id, "`] ", replace(strip(first(split(c.source, "\n"))), r"\s+" => " "))
        end
    end
    return String(take!(io))
end

"The opening turn for a debugging specialist: this notebook, this cell, right now."
function debug_briefing(nb::LiveNotebook, cid::AbstractString, task::AbstractString)
    io = IOBuffer()
    println(io, "Notebook `", nb.id, "` (", basename(nb.path), ").")
    println(io)
    println(io, _specialist_cell_context(nb, cid))
    s = _debug_session(nb)
    if !isempty(s.cell)
        println(io, "\nThere is already a session on cell `", s.cell, "`, owned by ", s.owner,
                s.owner == HUMAN ? " — ask before taking it." : ".")
    end
    ms = _marks(nb)
    isempty(ms) || println(io, "\nBreakpoints already set: ",
                           join([isempty(c) ? string(f, ":", l) : string(f, ":", l, " when ", c)
                                 for (f, l, c) in ms], ", "))
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
        cond = haskey(b, "cond") ? String(get(b, "cond", "")) : nothing
        _json(mark_debug!(nb, String(get(b, "file", "")), Int(get(b, "line", 0)); on = on, cond = cond))
    end))
    HTTP.register!(router, "POST", "/api/{id}/debug/watch", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        _json(watch_debug!(nb, String(get(b, "file", "")), Int(get(b, "line", 0));
                           expr = String(get(b, "expr", ""))))
    end))
    HTTP.register!(router, "GET", "/api/{id}/debug/traces", req -> _withnb(h, req, nb ->
        _json(traces_debug(nb))))
    HTTP.register!(router, "POST", "/api/{id}/debug/live", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        on = haskey(b, "on") ? (get(b, "on", true) === true) : nothing
        r = live_watch!(nb, String(get(b, "source", "")); on = on)
        # Draw the new one immediately rather than waiting for the next step: adding a watch is
        # itself a request to see it.
        get(r, "ok", false) === true && @async (try; refresh_live_watches!(nb); catch; end)
        _json(r)
    end))
    # Agent roles + the policy over them. Global rather than per-notebook: a specialist's verbs and
    # whether a generalist may step are facts about this installation, not about one document.
    HTTP.register!(router, "GET", "/api/agent-roles", _ ->
        _json(Dict{String,Any}("roles" => specialist_roles_json(),
                               "debug_specialist_only" => debug_specialist_only(),
                               "checker_on" => checker_on())))
    HTTP.register!(router, "POST", "/api/agent-roles", req -> begin
        b = _body(req)
        haskey(b, "debug_specialist_only") &&
            set_debug_specialist_only!(get(b, "debug_specialist_only", false) === true)
        haskey(b, "checker_on") && set_checker_on!(get(b, "checker_on", false) === true)
        _json(Dict{String,Any}("ok" => true, "roles" => specialist_roles_json(),
                               "debug_specialist_only" => debug_specialist_only(),
                               "checker_on" => checker_on()))
    end)
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
