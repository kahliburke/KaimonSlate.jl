# ── Findings — what a specialist concluded, and what became of it ─────────────────────────────────
#
# A sign-off used to be a sentence in a slot: one per notebook, overwritten by the next, readable
# only as prose. That is enough to tell a person what was found, and nothing else.
#
# The review protocol needs three parties to reason about the SAME claim — the specialist that made
# it, a checker that did not watch it being made, and the orchestrator that knows what the notebook
# is for. Prose is what makes them restate one another instead of building on each other: a
# reviewer handed a paragraph re-reads a paragraph, and an orchestrator handed two paragraphs
# summarises them for a third time. Observed, on the first session that ran this way end to end.
#
# So a finding names a CELL, states a claim in one sentence, and carries its evidence separately.
# The cell is what makes the graph check below possible at all.

mutable struct Finding
    id::String
    role::String          # which kind of specialist found it
    from::String          # its agent id
    cell::String          # the cell it names as the fault ("" when it names none)
    claim::String         # one sentence: what is wrong
    evidence::String      # what it saw that says so
    at::Float64
    # Cells upstream of `cell` that this investigation never looked at. Computed, not asked: "did
    # you look where this value came from" is a reachability question with an exact answer, and
    # spending a language model on it would be both slower and less certain.
    unread_upstream::Vector{String}
    # The checker's read of the CLAIM — never of the transcript. A reviewer shown the reasoning
    # inherits it, and a confirmation from an anchored reviewer is worse than no review, because it
    # launders a wrong answer as a checked one.
    verdict::String       # "" | "confirmed" | "disputed"
    verdict_why::String
    verdict_at::Float64
    # The orchestrator's plan, and what the person said about it.
    plan::String
    decision::String
    decided_at::Float64
end

const _FINDINGS = Dict{String,Vector{Finding}}()   # nb.id → findings, oldest first
const _FINDING_SEQ = Ref(0)

# ── where they live ───────────────────────────────────────────────────────────────────────────────
#
# On disk beside the document's revisions, not in memory and not in the .jl.
#
# In memory they lasted until the hub restarted, which made the whole point of recording them —
# that a later investigation starts from what an earlier one established — good for one sitting.
# The .jl would survive, but a finding's evidence runs to paragraphs and every save would carry it
# into the diff. The revision store is already per-document, already survives a move, and is
# already invisible to git.

const _FINDINGS_LOADED = Set{String}()

# `nbdoc`, not `SlateHistory.Doc(path)`. The latter is the legacy identity and hashes the absolute
# path, so findings would be stranded by a rename or a move while the document's own revisions
# followed it. `nbdoc` keys off the file-carried `docid`, which is what makes them the DOCUMENT's
# findings rather than this filename's.
_finding_doc(nb::LiveNotebook) = nbdoc(nb)

function _finding_from(d::AbstractDict)
    g(k, dflt) = get(d, k, dflt)
    return Finding(String(g("id", "")), String(g("role", "")), String(g("from", "")),
                   String(g("cell", "")), String(g("claim", "")), String(g("evidence", "")),
                   Float64(g("at", 0.0)),
                   String[String(x) for x in g("unread_upstream", Any[])],
                   String(g("verdict", "")), String(g("verdict_why", "")),
                   Float64(g("verdict_at", 0.0)), String(g("plan", "")),
                   String(g("decision", "")), Float64(g("decided_at", 0.0)))
end

# Must be called holding `_SPEC_LOCK`. Reads from disk once per notebook, then serves the cache.
function _findings!(nb::LiveNotebook)
    if !(nb.id in _FINDINGS_LOADED)
        push!(_FINDINGS_LOADED, nb.id)
        loaded = Finding[]
        try
            raw = SlateHistory.read_side(_finding_doc(nb), "findings")
            raw isa AbstractVector && (loaded = Finding[_finding_from(x) for x in raw if x isa AbstractDict])
        catch e
            @debug "slate: could not read findings" exception = e
        end
        # Ids are handed out from a counter, so a reload has to move it past anything already on
        # disk or the next finding would collide with one of these and overwrite it in the UI.
        for f in loaded
            n = tryparse(Int, replace(f.id, "find" => ""))
            n === nothing || (_FINDING_SEQ[] = max(_FINDING_SEQ[], n))
        end
        _FINDINGS[nb.id] = loaded
    end
    return get!(() -> Finding[], _FINDINGS, nb.id)
end

# Snapshot under the lock, write outside it: the write is file I/O and nothing else should wait on
# it, least of all the tool call that just recorded the finding.
function _persist_findings!(nb::LiveNotebook)
    snap = lock(_SPEC_LOCK) do; [finding_json(f) for f in _findings!(nb)]; end
    try; SlateHistory.write_side!(_finding_doc(nb), "findings", snap); catch; end
    return nothing
end

finding_json(f::Finding) = Dict{String,Any}(
    "id" => f.id, "role" => f.role, "from" => f.from, "cell" => f.cell,
    "claim" => f.claim, "evidence" => f.evidence, "at" => f.at,
    "unread_upstream" => copy(f.unread_upstream),
    "verdict" => f.verdict, "verdict_why" => f.verdict_why, "verdict_at" => f.verdict_at,
    "plan" => f.plan, "decision" => f.decision, "decided_at" => f.decided_at)

findings_json(nb::LiveNotebook) = lock(_SPEC_LOCK) do
    [finding_json(f) for f in _findings!(nb)]
end

"The most recent finding for this notebook, or `nothing`."
latest_finding(nb::LiveNotebook) = lock(_SPEC_LOCK) do
    fs = _findings!(nb)
    isempty(fs) ? nothing : last(fs)
end

finding_by_id(nb::LiveNotebook, id::AbstractString) = lock(_SPEC_LOCK) do
    fs = _findings!(nb)
    i = findfirst(f -> f.id == String(id), fs)
    i === nothing ? nothing : fs[i]
end

# ── what the investigation actually looked at ─────────────────────────────────────────────────────
#
# Stepping a cell or reading its source both count; an agent that has done neither has not looked
# at it, whatever it concluded. Scoped to one investigation rather than to the notebook's whole
# history: it is reset when a debug session starts, so a cell someone read an hour ago for another
# reason does not count as diligence here.

const _SEEN_CELLS = Dict{String,Set{String}}()

function note_cells_seen!(nb::LiveNotebook, ids)
    isempty(ids) && return nothing
    lock(_SPEC_LOCK) do
        s = get!(() -> Set{String}(), _SEEN_CELLS, nb.id)
        for id in ids; push!(s, String(id)); end
    end
    return nothing
end

function reset_cells_seen!(nb::LiveNotebook, ids = String[])
    lock(_SPEC_LOCK) do
        _SEEN_CELLS[nb.id] = Set{String}(String(i) for i in ids)
        delete!(_DONE_WARNED, nb.id)        # a new investigation earns a fresh warning
    end
    return nothing
end

cells_seen(nb::LiveNotebook) = lock(_SPEC_LOCK) do
    copy(get(_SEEN_CELLS, nb.id, Set{String}()))
end

"""
Every cell `cid` transitively depends on.

The whole cone rather than direct dependencies: a value is often built two or three cells back, and
the cell that finally mishandles it is the one an investigation is looking at when it goes wrong.
"""
function upstream_cells(nb::LiveNotebook, cid::AbstractString)
    cells = nb.report.cells
    byid = Dict(c.id => c for c in cells)
    haskey(byid, String(cid)) || return String[]
    up = Set{String}(); frontier = String[String(cid)]
    while !isempty(frontier)
        c = get(byid, pop!(frontier), nothing); c === nothing && continue
        for d in c.deps
            (d == String(cid) || d in up) && continue
            push!(up, d); push!(frontier, d)
        end
    end
    return [c.id for c in cells if c.id in up]      # notebook order, not set order
end

# Whether this investigation has already been told it skipped its upstream. The structural check
# asks once and then gets out of the way: sometimes the upstream really does not matter, and a
# check with no way past it stops being a check and becomes a trap.
const _DONE_WARNED = Dict{String,Bool}()

done_warned(nb::LiveNotebook)::Bool = lock(_SPEC_LOCK) do; get(_DONE_WARNED, nb.id, false); end
mark_done_warned!(nb::LiveNotebook) = lock(_SPEC_LOCK) do; _DONE_WARNED[nb.id] = true; end

"""
Cells that produce `cid`'s inputs and that this investigation never looked at.

This is the whole of the structural check. A specialist naming the cell where a bad value was USED,
having never looked at the cell that PRODUCED it, is reporting a symptom — and the fix it proposes
will be to the code that received the value rather than to whatever made it wrong.
"""
unread_upstream(nb::LiveNotebook, cid::AbstractString) =
    (seen = cells_seen(nb); [c for c in upstream_cells(nb, cid) if !(c in seen)])

# ── carrying them in the file ─────────────────────────────────────────────────────────────────────
#
# The local store is per machine. A colleague who opens the notebook has none of it, and the thing
# they would most want — "this was already investigated, here is what was established and decided"
# — is exactly what they do not get. With `sharefindings` on, the footer carries it.

"Put this notebook's findings where the serializer can write them into the footer."
function stage_findings!(nb::LiveNotebook)
    get(nb.report.meta, "sharefindings", false) === true || (delete!(nb.report.meta, "findings"); return nothing)
    nb.report.meta["findings"] = findings_json(nb)
    return nothing
end

"""
Take on findings that arrived in an opened file.

Merged by id rather than replacing: the file's records are what its sender established, and a
notebook opened here may have its own. A record already known is left alone — the local one has
this machine's decision on it, and an incoming copy would be a step backwards.
"""
function adopt_findings!(nb::LiveNotebook)
    incoming = get(nb.report.meta, "findings_incoming", nothing)
    delete!(nb.report.meta, "findings_incoming")
    (incoming isa AbstractVector && !isempty(incoming)) || return 0
    added = lock(_SPEC_LOCK) do
        fs = _findings!(nb)
        have = Set{String}(f.id for f in fs)
        n = 0
        for d in incoming
            d isa AbstractDict || continue
            f = _finding_from(d)
            (isempty(f.id) || f.id in have) && continue
            push!(fs, f); push!(have, f.id); n += 1
            k = tryparse(Int, replace(f.id, "find" => ""))
            k === nothing || (_FINDING_SEQ[] = max(_FINDING_SEQ[], k))
        end
        n
    end
    added == 0 || _persist_findings!(nb)
    return added
end

# ── provenance, delivered where it is needed ──────────────────────────────────────────────────────
#
# The structural check at sign-off CATCHES a specialist that blamed the cell a bad value landed in.
# This prevents it. The notebook knows which cell defines a name — it has to, to order the run — and
# the moment that fact is worth having is when someone is looking at the value, not in a briefing
# thirty turns earlier that has long since scrolled away.

"Which cell defines `name`, or `\"\"`. The LAST one wins, which is the binding actually in scope."
function defining_cell(nb::LiveNotebook, name::AbstractString)
    sym = Symbol(strip(name))
    out = ""
    for c in nb.report.cells
        # `mutates` is excluded on purpose: a cell that writes into an array it did not create is
        # not where that array came from, and naming it would send a reader to the wrong place.
        (sym in c.writes && !(sym in c.mutates)) && (out = c.id)
    end
    return out
end

"The identifiers in a snippet, in the order they appear, without duplicates."
function _idents(src::AbstractString)
    out = String[]
    for m in eachmatch(r"[A-Za-z_][A-Za-z0-9_!]*", String(src))
        s = m.match
        (s in out || s in ("true", "false", "nothing", "missing", "end", "if", "for", "while",
                           "let", "do", "function", "return", "in", "begin")) && continue
        push!(out, s)
    end
    return out
end

"""
Where the names in `expr` come from, as a line to append to a value an agent just looked at.

Empty when nothing in the expression is a notebook binding — a frame local has no cell, and saying
so every time would be noise on the majority of evaluations.
"""
function provenance_note(nb::LiveNotebook, expr::AbstractString)
    seen = Tuple{String,String}[]
    for name in _idents(expr)
        cid = defining_cell(nb, name)
        isempty(cid) || any(p -> p[2] == cid, seen) || push!(seen, (name, cid))
        length(seen) >= 3 && break        # a long expression should not turn into a lecture
    end
    isempty(seen) && return ""
    parts = String[]
    for (name, cid) in seen
        ups = upstream_cells(nb, cid)
        push!(parts, isempty(ups) ? "`$name` is defined in cell `$cid`" :
              "`$name` is defined in cell `$cid`, which reads " *
              join(("`" * u * "`" for u in ups), ", "))
    end
    return "↳ " * join(parts, "; ") * "."
end

# ── recording one ─────────────────────────────────────────────────────────────────────────────────

function record_finding!(nb::LiveNotebook, role::AbstractString, from::AbstractString;
                         cell::AbstractString = "", claim::AbstractString = "",
                         evidence::AbstractString = "")
    f = Finding("", String(role), String(from), String(cell), String(claim), String(evidence),
                time(), isempty(cell) ? String[] : unread_upstream(nb, cell),
                "", "", 0.0, "", "", 0.0)
    lock(_SPEC_LOCK) do
        fs = _findings!(nb)
        f.id = string("find", _FINDING_SEQ[] += 1)
        push!(fs, f)
    end
    _persist_findings!(nb)
    # An investigation ends where its conclusion is filed, so the next one starts from nothing.
    # `unread_upstream` above was computed first, and is kept on the finding — the record of what
    # this one did not look at survives the reset that follows it.
    reset_cells_seen!(nb)
    broadcast_specialist(nb, f.role, Dict{String,Any}("finding" => finding_json(f)))
    return f
end

function set_verdict!(nb::LiveNotebook, id::AbstractString, verdict::AbstractString,
                      why::AbstractString)
    f = finding_by_id(nb, id); f === nothing && return nothing
    lock(_SPEC_LOCK) do
        f.verdict = String(verdict); f.verdict_why = String(why); f.verdict_at = time()
    end
    _persist_findings!(nb)
    broadcast_specialist(nb, f.role, Dict{String,Any}("finding" => finding_json(f)))
    return f
end

function set_plan!(nb::LiveNotebook, id::AbstractString, plan::AbstractString)
    f = finding_by_id(nb, id); f === nothing && return nothing
    lock(_SPEC_LOCK) do; f.plan = String(plan); end
    _persist_findings!(nb)
    broadcast_specialist(nb, f.role, Dict{String,Any}("finding" => finding_json(f)))
    return f
end

function set_decision!(nb::LiveNotebook, id::AbstractString, decision::AbstractString)
    f = finding_by_id(nb, id); f === nothing && return nothing
    lock(_SPEC_LOCK) do; f.decision = String(decision); f.decided_at = time(); end
    _persist_findings!(nb)
    broadcast_specialist(nb, f.role, Dict{String,Any}("finding" => finding_json(f)))
    return f
end

"Drop a closed notebook's findings — ids are reused when the same file is reopened."
function forget_findings!(id::AbstractString)
    lock(_SPEC_LOCK) do
        delete!(_FINDINGS, String(id)); delete!(_SEEN_CELLS, String(id))
        delete!(_DONE_WARNED, String(id)); delete!(_FINDINGS_LOADED, String(id))
    end
    return nothing
end
