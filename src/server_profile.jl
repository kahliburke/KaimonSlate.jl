# ── Cell profiler: the hub's side ──────────────────────────────────────────────────────────────
#
# The sampling and the tree are built where the cell runs (profile.jl, `ReportEngine.profile_*`):
# this file resolves that kernel, turns a Run into an ordinary forced run of the cell with a profile
# armed for it, and pushes what comes back to every open page. A region cell is profiled on its node
# by the same calls, since a region kernel is a GateKernel like any other.
#
# Everything here is asynchronous and pushed (`profile:` on the page socket): compiling a cell's
# packages for a prepare, or running a long cell, takes as long as it takes, and the dock follows
# the pushes rather than a request held open.

const _PROF_LAST = Dict{Tuple{String,String},Dict{String,Any}}()   # (nb, cell) → last pushed result
const _PROF_PREV = Dict{Tuple{String,String},Dict{String,Any}}()   # (nb, cell) → the one before it
const _PROF_HUB_LOCK = ReentrantLock()

_broadcast_profile(nb::LiveNotebook, payload::Dict{String,Any}) =
    (try; _broadcast(nb, "profile:" * JSON.json(_json_finite(payload))); catch; end; nothing)

function _profile_cell(nb::LiveNotebook, cid::AbstractString)
    i = findfirst(c -> c.id == cid, nb.report.cells)
    i === nothing && return nothing
    c = nb.report.cells[i]
    return c.kind == CODE ? c : nothing
end

# The cell's kernel, or why there is none to profile on. A region with no worker is not started
# here: the dock says so, and the worker panel's Start or a run of the cell brings one up.
function _profile_kernel(nb::LiveNotebook, side::AbstractString)
    return try
        (lock(_eval_mutex(nb)) do; _side_kernel!(nb, side); end, "")
    catch e
        e isa RegionWaiting ? (nothing, "the $(side) region has no worker yet: start it from its worker panel, or run the cell") :
                              (nothing, first(sprint(showerror, e), 300))
    end
end

function _profile_fail(nb::LiveNotebook, cid::AbstractString, side::AbstractString, why::AbstractString)
    _broadcast_profile(nb, Dict{String,Any}("kind" => "error", "cell" => String(cid), "side" => String(side),
                                            "error" => String(why)))
    return Dict{String,Any}("ok" => false, "error" => String(why))
end

"""
    prepare_profile!(nb, cid) -> Dict

Compile cell `cid`'s code where it runs, without running it, in the background. The page hears
`preparing`, then `prepared` with what was compiled.
"""
function prepare_profile!(nb::LiveNotebook, cid::AbstractString)
    cell = _profile_cell(nb, cid)
    cell === nothing && return Dict{String,Any}("ok" => false, "error" => "no code cell '$cid'")
    _, side = _region_route(nb, cell)
    src = cell.source; reads = String[String(r) for r in cell.reads]
    _broadcast_profile(nb, Dict{String,Any}("kind" => "preparing", "cell" => String(cid), "side" => side))
    Threads.@spawn try
        k, why = _profile_kernel(nb, side)
        k === nothing && return _profile_fail(nb, cid, side, why)
        r = lock(_eval_mutex(nb)) do
            ReportEngine.profile_prepare!(k, nb.report; cell = String(cid), source = src, reads = reads)
        end
        _broadcast_profile(nb, merge(Dict{String,Any}(r), Dict{String,Any}("kind" => "prepared", "side" => side)))
    catch e
        _profile_fail(nb, cid, side, first(sprint(showerror, e), 300))
    end
    return Dict{String,Any}("ok" => true)
end

"""
    profile_now!(nb, cid; mode) -> Dict

Profile cell `cid` and wait: arm a profile for it on its kernel, run it as its ▶ would (so its
output, bindings and memo entry are the run's), and push what came back. Returns that push.
"""
function profile_now!(nb::LiveNotebook, cid::AbstractString; mode::AbstractString = "cpu")
    cell = _profile_cell(nb, cid)
    cell === nothing && return Dict{String,Any}("kind" => "error", "error" => "no code cell '$cid'")
    _, side = _region_route(nb, cell)
    _broadcast_profile(nb, Dict{String,Any}("kind" => "running", "cell" => String(cid), "side" => side,
                                            "mode" => String(mode)))
    fail(why) = (_profile_fail(nb, cid, side, why);
                 Dict{String,Any}("kind" => "error", "cell" => String(cid), "error" => String(why)))
    try
        k, why = _profile_kernel(nb, side)
        k === nothing && return fail(why)
        lock(_eval_mutex(nb)) do
            ReportEngine.profile_arm!(k, nb.report; cell = String(cid), mode = String(mode))
        end
        t0 = time()
        lock(nb.lock) do; _force_cell!(nb, cid); end
        _eval!(nb; wait_for = cid)
        r = lock(_eval_mutex(nb)) do
            ReportEngine.profile_result(k, nb.report; cell = String(cid))
        end
        if r === nothing || Float64(get(r, "at", 0.0)) < t0
            try; lock(_eval_mutex(nb)) do; ReportEngine.profile_disarm!(k, nb.report; cell = String(cid)); end; catch; end
            c = _profile_cell(nb, cid)
            return fail("the cell did not run" * (c !== nothing && c.state == BLOCKED ? " (it is waiting: $(c.blocked))" : ""))
        end
        payload = Dict{String,Any}("kind" => "result", "cell" => String(cid), "side" => side,
                                   "source" => _profile_cell(nb, cid).source, "profile" => r)
        lock(_PROF_HUB_LOCK) do
            old = get(_PROF_LAST, (nb.id, String(cid)), nothing)
            old === nothing || (_PROF_PREV[(nb.id, String(cid))] = old)
            _PROF_LAST[(nb.id, String(cid))] = payload
        end
        _broadcast_profile(nb, payload)
        return payload
    catch e
        return fail(first(sprint(showerror, e), 300))
    end
end

"Profile cell `cid` in the background; the page follows the pushes (`profile_now!`)."
function run_profile!(nb::LiveNotebook, cid::AbstractString; mode::AbstractString = "cpu")
    _profile_cell(nb, cid) === nothing && return Dict{String,Any}("ok" => false, "error" => "no code cell '$cid'")
    Threads.@spawn profile_now!(nb, cid; mode = mode)
    return Dict{String,Any}("ok" => true)
end

"The last profile pushed for `cid`, for a dock opened after it was taken."
last_profile(nb::LiveNotebook, cid::AbstractString) =
    lock(_PROF_HUB_LOCK) do; get(_PROF_LAST, (nb.id, String(cid)), nothing); end

"""
    profile_source(nb, cid, file) -> Dict

The text of `file` for the profile's code pane. A cell's file (`cell:<id>`) is the notebook's own
text, which no kernel has; anything else is read on the machine the cell ran on.
"""
function profile_source(nb::LiveNotebook, cid::AbstractString, file::AbstractString)
    f = String(file)
    if startswith(f, "cell:")
        c = _profile_cell(nb, f[6:end])
        c === nothing && return Dict{String,Any}("file" => f, "text" => "", "error" => "no such cell")
        return Dict{String,Any}("file" => f, "path" => f, "text" => c.source, "error" => nothing)
    end
    cell = _profile_cell(nb, cid)
    cell === nothing && return Dict{String,Any}("file" => f, "text" => "", "error" => "no code cell '$cid'")
    _, side = _region_route(nb, cell)
    k, why = _profile_kernel(nb, side)
    k === nothing && return Dict{String,Any}("file" => f, "text" => "", "error" => why)
    return try
        Dict{String,Any}(lock(_eval_mutex(nb)) do; ReportEngine.profile_source(k, nb.report; file = f); end)
    catch e
        Dict{String,Any}("file" => f, "text" => "", "error" => first(sprint(showerror, e), 300))
    end
end

function _register_profile_routes!(router, h::Hub)
    HTTP.register!(router, "POST", "/api/{id}/profile/prepare", req -> _withnb(h, req, nb ->
        _json(prepare_profile!(nb, String(get(_body(req), "cell", ""))))))
    HTTP.register!(router, "POST", "/api/{id}/profile/run", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        _json(run_profile!(nb, String(get(b, "cell", "")); mode = String(get(b, "mode", "cpu"))))
    end))
    HTTP.register!(router, "GET", "/api/{id}/profile/last", req -> _withnb(h, req, nb -> begin
        q = HTTP.queryparams(HTTP.URI(req.target))
        p = last_profile(nb, String(get(q, "cell", "")))
        _json(_json_finite(p === nothing ? Dict{String,Any}("kind" => "none") : p))
    end))
    HTTP.register!(router, "POST", "/api/{id}/profile/agent", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        cid = String(get(b, "cell", ""))
        isempty(cid) && return _json(Dict{String,Any}("ok" => false, "error" => "no cell to profile"))
        try
            _json(summon!(nb, PROFILE_ROLE; subject = cid, model = String(get(b, "model", "")),
                          task = String(get(b, "task", ""))))
        catch e
            _json(Dict{String,Any}("ok" => false, "error" => first(sprint(showerror, e), 300)))
        end
    end))
    HTTP.register!(router, "GET", "/api/{id}/profile/source", req -> _withnb(h, req, nb -> begin
        q = HTTP.queryparams(HTTP.URI(req.target))
        _json(profile_source(nb, String(get(q, "cell", "")), String(get(q, "file", ""))))
    end))
end

# ── the profile as text, for the profiler specialist ───────────────────────────────────────────

struct _PNode
    id::Int; parent::Int; file::String; line::Int; func::String; pkg::String; kind::Int
    total::Int; self::Int; d::Int; g::Int; c::Int
end

function _pnodes(P::AbstractDict)
    S = P["strings"]; N = P["nodes"]; n = length(N["parent"])
    str(k) = k > 0 ? String(S[k]) : ""
    nodes = [_PNode(i, N["parent"][i], str(N["file"][i]), N["line"][i], str(N["func"][i]), str(N["pkg"][i]),
                    N["kind"][i], N["total"][i], N["self"][i], N["dispatch"][i], N["gc"][i], N["compile"][i])
             for i in 1:n]
    kids = [Int[] for _ in 1:n]
    for i in 2:n
        nodes[i].parent > 0 && push!(kids[nodes[i].parent], i)
    end
    return nodes, kids
end

_ppct(x) = x >= 0.1 ? string(round(Int, 100x), "%") : string(round(100x; digits = 1), "%")
_pms(x) = x >= 1000 ? string(round(x / 1000; digits = 2), " s") : string(round(Int, x), " ms")
# A file as the specialist should name it back: a cell's as it is, anything else by its last two parts.
_pshort(f::AbstractString) = startswith(f, "cell:") || isempty(f) ? String(f) : join(last(splitpath(f), 2), "/")
function _pmarks(d, g, c, T)
    m = String[]
    d > 0 && push!(m, "dispatch " * _ppct(d / T))
    c > 0 && push!(m, "compiling " * _ppct(c / T))
    g > 0 && push!(m, "GC " * _ppct(g / T))
    return isempty(m) ? "" : "  [" * join(m, ", ") * "]"
end
_pwhere(n::_PNode) = n.kind != 0 ? n.func : string(n.func, "  ", _pshort(n.file), ":", n.line,
                                                     n.pkg in ("cell", "notebook", "") ? "" : "  (" * n.pkg * ")")

function _cell_line_text(nb::LiveNotebook, file::AbstractString, line::Integer)
    startswith(file, "cell:") || return ""
    c = _profile_cell(nb, file[6:end]); c === nothing && return ""
    ls = split(c.source, '\n')
    return 1 <= line <= length(ls) ? strip(ls[line]) : ""
end

"""
    profile_summary_text(nb, cid) -> String

The last profile of `cid` in words: run facts, the change from the run before, the lines that
cost the most of their own time, and the hot path under each of the cell's heaviest lines.
"""
function profile_summary_text(nb::LiveNotebook, cid::AbstractString)
    p = last_profile(nb, cid)
    p === nothing && return "No profile of cell `$cid` yet. `prof_run` takes one."
    P = p["profile"]; T = max(1, P["samples"])
    io = IOBuffer()
    println(io, "Cell `", cid, "`", isempty(p["side"]) ? "" : " on " * p["side"], ": ", _pms(P["duration_ms"]),
            ", ", P["samples"], " samples", P["threads"] > 1 ? " on $(P["threads"]) threads" : "",
            ", compiling ", _pms(P["compile_ms"]), ", GC ", _pms(P["gc_ms"]), ".")
    P["error"] === nothing || println(io, "The run threw: ", first(split(String(P["error"]), '\n')))
    prev = lock(_PROF_HUB_LOCK) do; get(_PROF_PREV, (nb.id, String(cid)), nothing); end
    if prev !== nothing
        Q = prev["profile"]
        println(io, "The run before took ", _pms(Q["duration_ms"]), " (", round(P["duration_ms"] / max(1e-9, Q["duration_ms"]); digits = 2), "× now).")
    end
    L = P["lines"]; S = P["strings"]
    rows = [(file = String(S[L["file"][i]]), line = L["line"][i], incl = L["incl"][i], self = L["self"][i],
             d = L["dispatch"][i], g = L["gc"][i], c = L["compile"][i]) for i in eachindex(L["file"])]
    sort!(rows; by = r -> -r.self)
    println(io, "\nLines by their own time (self / total):")
    for r in Iterators.take(filter(r -> r.self > 0, rows), 12)
        println(io, "  ", lpad(_ppct(r.self / T), 6), " / ", lpad(_ppct(r.incl / T), 5), "  ",
                _pshort(r.file), ":", r.line, (t = _cell_line_text(nb, r.file, r.line); isempty(t) ? "" : "  " * t),
                _pmarks(r.d, r.g, r.c, T))
    end
    nodes, kids = _pnodes(P)
    println(io, "\nHot paths, from the cell's heaviest lines:")
    tops = sort(kids[1]; by = i -> -nodes[i].total)
    for top in Iterators.take(tops, 3)
        nodes[top].total / T < 0.05 && break
        i = top; chain = String[]
        while true
            n = nodes[i]
            push!(chain, string(_ppct(n.total / T), " ", n.kind != 0 ? n.func : string(n.func, " ", _pshort(n.file), ":", n.line)))
            ks = kids[i]; isempty(ks) && break
            j = ks[argmax([nodes[k].total for k in ks])]
            nodes[j].total / T < 0.03 && break
            i = j
        end
        println(io, "  ", join(chain, "  →  "))
    end
    return String(take!(io))
end

"""
    profile_tree_text(nb, cid; at, depth, min) -> String

The line-keyed tree under `at` ("" for the whole cell, `file:line`, or a function name), down to
`depth` levels and leaving out anything under `min` percent of the run.
"""
function profile_tree_text(nb::LiveNotebook, cid::AbstractString; at::AbstractString = "",
                           depth::Integer = 6, min::Real = 1.0)
    p = last_profile(nb, cid)
    p === nothing && return "No profile of cell `$cid` yet. `prof_run` takes one."
    P = p["profile"]; T = max(1, P["samples"])
    nodes, kids = _pnodes(P)
    a = strip(String(at)); start = 1
    if !isempty(a)
        m = match(r"^(.*):(\d+)$", a)
        cand = m === nothing ? [n for n in nodes if n.func == a] :
               [n for n in nodes if n.line == parse(Int, m.captures[2]) && endswith(n.file, m.captures[1])]
        isempty(cand) && return "Nothing in the profile at `$a`. Name a `file:line` or a function from the summary or the tree."
        start = cand[argmax([n.total for n in cand])].id
    end
    io = IOBuffer()
    walk(i, d) = begin
        n = nodes[i]
        println(io, "  "^d, lpad(_ppct(n.total / T), 6), "  self ", lpad(_ppct(n.self / T), 5), "  ",
                i == 1 ? "cell " * cid : _pwhere(n), _pmarks(n.d, n.g, n.c, T))
        d >= depth && return
        for k in sort(kids[i]; by = k -> -nodes[k].total)
            nodes[k].total / T * 100 >= min && walk(k, d + 1)
        end
    end
    walk(start, 0)
    return String(take!(io))
end

"""
    profile_source_text(nb, cid, file; line, around) -> String

`file` as the machine the cell ran on has it, with each line's share of the run, around `line`.
"""
function profile_source_text(nb::LiveNotebook, cid::AbstractString, file::AbstractString;
                             line::Integer = 0, around::Integer = 20)
    p = last_profile(nb, cid)
    p === nothing && return "No profile of cell `$cid` yet. `prof_run` takes one."
    P = p["profile"]; T = max(1, P["samples"]); S = P["strings"]; L = P["lines"]
    want = strip(String(file))
    full = something(findfirst(f -> endswith(f, want), [String(f) for f in S]), 0)
    path = full == 0 ? want : String(S[full])
    src = profile_source(nb, cid, path)
    src["error"] === nothing || return "Could not read `$path`: $(src["error"])"
    heat = Dict{Int,Any}()
    for i in eachindex(L["file"])
        String(S[L["file"][i]]) == path || continue
        heat[L["line"][i]] = (incl = L["incl"][i], self = L["self"][i], d = L["dispatch"][i], g = L["gc"][i], c = L["compile"][i])
    end
    ls = split(String(src["text"]), '\n')
    lo, hi = line > 0 ? (max(1, line - around), min(length(ls), line + around)) : (1, min(length(ls), 2around))
    io = IOBuffer()
    println(io, _pshort(path), "  (lines ", lo, "–", hi, " of ", length(ls), "; total / self share of the run)")
    for k in lo:hi
        h = get(heat, k, nothing)
        tag = h === nothing ? " "^15 : lpad(_ppct(h.incl / T), 6) * " / " * lpad(_ppct(h.self / T), 6)
        println(io, lpad(k, 5), k == line ? " ▶ " : "   ", tag, " │ ", ls[k],
                h === nothing ? "" : _pmarks(h.d, h.g, h.c, T))
    end
    return String(take!(io))
end

"""
    profile_eval(nb, cid, code) -> String

Evaluate `code` on the kernel cell `cid` runs on, in the notebook's namespace, and return what it
printed and its value: `@code_warntype f(x)`, `@allocated`, a timing at the types the cell uses.
"""
function profile_eval(nb::LiveNotebook, cid::AbstractString, code::AbstractString)
    cell = _profile_cell(nb, cid)
    cell === nothing && return "no code cell '$cid'"
    _, side = _region_route(nb, cell)
    k, why = _profile_kernel(nb, side)
    k === nothing && return why
    out = lock(_eval_mutex(nb)) do
        ReportEngine.eval_capture(k, nb.report, String(code), "prof:eval")
    end
    io = IOBuffer()
    isempty(out.stdout) || print(io, out.stdout)
    isempty(out.stderr) || print(io, out.stderr)
    out.exception === nothing ? print(io, isempty(out.value_repr) ? "" : out.value_repr) :
                                print(io, "ERROR: ", out.exception)
    t = String(take!(io))
    return length(t) > 8000 ? first(t, 8000) * "\n… (cut at 8000 characters)" : t
end

# ── the profiler specialist ────────────────────────────────────────────────────────────────────

const PROFILE_ROLE = "profiler"

# Its own verbs, plus reading cells, changing one once the person has agreed, and the conversation
# every specialist has.
const PROFILE_VERBS = String["prof_run", "prof_summary", "prof_tree", "prof_source", "prof_eval",
                             "read", "edit_cell", "spec_ask", "spec_done"]

const PROFILE_BRIEF = """
You are a performance specialist working inside a Slate notebook, alongside the person who called
you in. You have one job: find where a cell's time goes and what would make it faster.

Your tools profile the cell where it runs (a `region=` cell on its cluster node) and read the
result: `prof_run` runs the cell under the profiler and returns a summary compared with the run
before; `prof_summary` repeats it; `prof_tree` shows the call tree under a line or function, keyed
by source line; `prof_source` shows any file with each line's share of the run; `prof_eval` runs
Julia on the cell's own kernel, in the notebook's namespace, which is where you check a hypothesis:
`@code_warntype f(args)`, `@allocated f(args)`, `@time`, `typeof(x)`, at the values the cell uses.
`read` shows any cell. `edit_cell` changes one, and only after the person has agreed.

How to work:

- Start from the profile, not from reading code. The lines with the most time of their own are
  where the cost is; the marks say what kind: runtime dispatch (type instability), GC (allocation)
  or compilation (code compiled during the run, usually because of dispatch).
- Follow a hot line down with `prof_tree(at="file:line")` until you reach the code that is
  actually slow, then read it with `prof_source`. Library code is rarely the problem; how it is
  called usually is.
- Confirm before you claim. Type instability is confirmed by `@code_warntype` at the real
  argument types, allocation by `@allocated`; say what you ran and what it showed.
- One change at a time. Propose it with `spec_ask`, giving the edit as an option, and wait. Once
  agreed, make it with `edit_cell`, run `prof_run`, and report the before and after. If a change
  does not help, say so and put it back.
- The first run of a cell includes compiling it. A second `prof_run` shows the steady state;
  compare like with like.

What you do not know: what this notebook is for, which results must not change, and how much
speed matters against clarity. When a fix would change results or make the code harder to read,
ask.

When you are done, `spec_done` with the cell you changed or recommend changing, a one-sentence
summary with the numbers, and the evidence. Say plainly if you found nothing worth changing.

Be brief in chat. Say what you are about to look at and why, then look.
"""

"The opening turn for a profiler: this notebook, this cell, and its last profile if there is one."
function profile_briefing(nb::LiveNotebook, cid::AbstractString, task::AbstractString)
    io = IOBuffer()
    println(io, "Notebook `", nb.id, "` (", basename(nb.path), ").")
    println(io)
    println(io, _specialist_cell_context(nb, cid))
    if last_profile(nb, cid) !== nothing
        println(io, "\nIts last profile:\n")
        println(io, profile_summary_text(nb, cid))
    else
        println(io, "\nIt has not been profiled yet; `prof_run` takes one.")
    end
    println(io)
    println(io, isempty(strip(task)) ? "Find where this cell's time goes and what would make it faster." : strip(task))
    return String(take!(io))
end

register_specialist!(Specialist(PROFILE_ROLE; brief = PROFILE_BRIEF, verbs = PROFILE_VERBS,
                                briefing = profile_briefing))
