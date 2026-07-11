# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Structural ops (add / delete / move / change type) ───────────────────────

function _gen_id(report::Report)
    existing = Set(c.id for c in report.cells)
    while true
        id = string(hash(time_ns()) % 0xffffff; base = 16, pad = 6)
        id in existing || return id
    end
end

# Push a cell's CURRENT (pre-eval) state to the browser as a targeted `cellpre:` upsert, so an
# agent add/edit is VISIBLE — the new source, marked stale — BEFORE its (possibly long) eval
# finishes. Without it the browser only learns the change from the post-eval version bump
# (`celldone:`/`patchCells` can only UPDATE an existing cell, never insert one; and an edit's
# new source isn't shown until the run ends). A targeted event — not a version bump — is used on
# purpose: a mid-eval `GET /api/state` runs `sync_from_file!`, and the change isn't on disk yet,
# so it would roll back. The browser inserts (add) or replaces in place (edit) by cell id.
function _announce_cell!(nb::LiveNotebook, idx::Int)
    (1 <= idx <= length(nb.report.cells)) || return nb
    try
        bindref, hostednames = _bind_index(nb.report)
        bibctx = _bib_link_ctx(nb)
        figidx = figure_index(nb.report)
        _broadcast(nb, "cellpre:" * JSON.json(Dict(
            "index" => idx - 1,                         # browser cells[] is 0-based
            "cell" => cell_json(nb.report.cells[idx], bindref, hostednames; nbid = nb.id, bibctx = bibctx, figidx = figidx))))
    catch
    end
    return nb
end

# A structural change at index `idx` reorders state, so conservatively restale everything from
# there on, recompute, and persist. `announce` shows the cell at `idx` (stale) before eval.
function _commit_structure!(nb::LiveNotebook, idx::Int; announce::Bool = false)
    # Hold nb.lock around deps + restale + persist: with async eval the runner / set_bind! hold the
    # lock intermittently, so this must serialize against them (else the persist races and is lost,
    # like the edit_cell! bug). Reentrant — the agent structural paths already hold nb.lock.
    lock(nb.lock) do
        build_dependencies!(nb.report)
        for (i, c) in enumerate(nb.report.cells)
            i >= idx && (c.state = STALE)
        end
        announce && _announce_cell!(nb, idx)
        _eval!(nb)                       # kick the async runner (non-blocking; safe inside the lock)
        _persist!(nb)
        _autoindex!(nb)                  # added/edited cell may introduce a new `using`
    end
    return nb
end

# Structural commit for reorder / add / delete. Rebuilds the dependency graph (cheap — the per-cell
# analysis is memoized) and re-evaluates ONLY the cells whose dependency set actually CHANGED, plus
# their transitive dependents. For a pure move, an empty-cell insert, or a leaf delete nothing
# changes → no re-evaluation at all (instant). This replaces the old `_commit_structure!` path that
# restaled everything by POSITION and re-ran the whole notebook on every click.
function _commit_reorder!(nb::LiveNotebook)
    lock(nb.lock) do                     # serialize deps + restale + persist vs the async runner (reentrant)
        old = Dict{String,Set{String}}(c.id => copy(c.deps) for c in nb.report.cells)
        build_dependencies!(nb.report)
        changed = Set{String}(c.id for c in nb.report.cells if get(old, c.id, nothing) != c.deps)
        if !isempty(changed)
            restale = dependents_of(nb.report, changed)   # the changed cells + everything downstream
            for c in nb.report.cells
                c.id in restale && (c.state = STALE)
            end
            _eval!(nb)                   # kick the async runner (non-blocking; safe inside the lock)
            _autoindex!(nb)
        end
        _persist!(nb)
    end
    return nb
end

_index_of(cells, id) = findfirst(c -> c.id == id, cells)

function add_cell!(nb::LiveNotebook, after_id::AbstractString, kind::AbstractString; before::Bool = false)
    nid = _gen_id(nb.report)                          # generated up front so the undo label can name it
    _snapshot!(nb; label = "add $nid")
    cells = nb.report.cells
    i = isempty(after_id) ? length(cells) : something(_index_of(cells, after_id), length(cells))
    cell = Cell(nid, kind == "md" ? MARKDOWN : CODE, "")
    cell.state = FRESH                               # empty cell: nothing to run (don't show it stale)
    pos = before ? max(1, i) : i + 1                 # insert above (at `i`) or below the reference
    insert!(cells, pos, cell)
    _commit_reorder!(nb)                             # empty cell defines nothing → no restale/re-eval
    return cell.id
end

# ── Build-floor + version-CAS (multi-agent write safety) ─────────────────────
# The safety layer Slate owns so several agents can drive ONE notebook without
# clobbering each other (MULTIAGENT.md §3). Two composable mechanisms, both opt-in
# so the solo-agent path is completely unaffected (it never takes the floor):
#
#   • Build-floor: a notebook-scoped lease keyed by the holder's CALLER SESSION ID
#     (KaimonGate.current_caller — the invoking agent's Mcp-Session-Id). While held,
#     only that same caller may commit; every edit carries the caller implicitly, so
#     the model threads NO token and can't lock itself out. "One voice at a time" for
#     ANY agent. Auto-expires after FLOOR_TTL idle so a crashed holder can't deadlock.
#   • Version-CAS: when NO floor is held, a mutation may carry the `nb.version` it was
#     decided against; we reject if the notebook has moved since (lost-update guard).
#
# Floor state lives in a module-level map (not an AgentSession/LiveNotebook field) so
# it's Revise-friendly. Lock order is always nb.lock → _FLOOR_LOCK (never inverted).
mutable struct FloorLease
    holder::String          # the holder's caller session id (KaimonGate.current_caller / Mcp-Session-Id)
    acquired_at::Float64
    renewed_at::Float64
end
const _NB_FLOOR = Dict{String,FloorLease}()   # notebook id → current lease
const _FLOOR_LOCK = ReentrantLock()
const FLOOR_TTL = 180.0                        # seconds of idleness before a lease is reclaimable

# Current live lease for `nb`, or nothing (reclaiming an expired one in passing).
function _live_floor(nb::LiveNotebook)
    lock(_FLOOR_LOCK) do
        l = get(_NB_FLOOR, nb.id, nothing)
        l === nothing && return nothing
        if time() - l.renewed_at > FLOOR_TTL
            delete!(_NB_FLOOR, nb.id)
            return nothing
        end
        return l
    end
end

# Grant (or re-grant to the same caller) the floor → (true, ""), or (false, why). The
# holder IS the caller's session id, so no token is minted/threaded — the same caller's
# later edits match implicitly.
function acquire_floor!(nb::LiveNotebook, holder::AbstractString)
    isempty(holder) && return (false, "no agent session — the floor can't be claimed by an unidentified caller")
    lock(_FLOOR_LOCK) do
        l = get(_NB_FLOOR, nb.id, nothing)
        if l !== nothing && time() - l.renewed_at <= FLOOR_TTL && l.holder != String(holder)
            return (false, "held by '$(l.holder)' (≈$(round(Int, time() - l.acquired_at))s ago)")
        end
        _NB_FLOOR[nb.id] = FloorLease(String(holder), time(), time())
        return (true, "")
    end
end

# Keep a held lease alive across a multi-op transaction (called after each commit by its holder).
function _renew_floor!(nb::LiveNotebook, caller::AbstractString)
    isempty(caller) && return
    lock(_FLOOR_LOCK) do
        l = get(_NB_FLOOR, nb.id, nothing)
        l !== nothing && l.holder == String(caller) && (l.renewed_at = time())
    end
end

# Release a held lease (only its holder can). Returns true if released.
function release_floor!(nb::LiveNotebook, caller::AbstractString)
    isempty(caller) && return false
    lock(_FLOOR_LOCK) do
        l = get(_NB_FLOOR, nb.id, nothing)
        (l !== nothing && l.holder == String(caller)) || return false
        delete!(_NB_FLOOR, nb.id)
        return true
    end
end

# Human-readable floor state for the read digest.
function floor_status(nb::LiveNotebook)
    l = _live_floor(nb)
    l === nothing ? "free" : "🔒 held by '$(l.holder)' (≈$(round(Int, time() - l.acquired_at))s)"
end

# Gate one agent commit. Returns nothing to proceed, or a rejection string (the op
# must NOT mutate). Call inside `nb.lock`. `caller` is the invoking agent's session id
# (KaimonGate.current_caller). If the floor is held by ANOTHER caller the op is rejected;
# its own holder (or a free floor) proceeds. A floor holder skips version-CAS (exclusivity
# guarantees freshness); a free floor still honors the optional version check, which catches
# a lost update against an external (or sessionless) commit.
function _guard_commit(nb::LiveNotebook; caller::AbstractString = "", expected_version::Int = -1)
    l = _live_floor(nb)
    if l !== nothing
        (!isempty(caller) && l.holder == String(caller)) && return nothing      # you hold the floor
        return "⛔ build-floor held by another agent ('$(l.holder)') — your change was NOT applied. Wait for it to release / expire, or coordinate."
    end
    if expected_version >= 0 && expected_version != nb.version
        return "⚠ stale write REJECTED — you decided against v$(expected_version) but the notebook is now at v$(nb.version). Nothing was applied; re-read (slate.read) and retry.\n\n" * notebook_digest(nb)
    end
    return nothing
end

# ── Agent cell operations (the incremental-build tool surface) ───────────────
# Cell-level ops the agent drives via `slate.*`: each mutates the live notebook,
# runs the affected cell, pushes the change to open browser tabs, and returns a
# compact TEXT result so the agent works in a tight read→add→run→observe loop —
# the cure for "compose everything in the head, then dump one big Edit."

# A compact fixed-width TEXT rendering of a captured interactive table (its wire dict form —
# "columns"/"rows"/"opts"), so an agent that VIEWS a table cell sees the actual data instead of a
# bare "[rendered: table]". The browser still gets the full sortable table; this caps the rows/cols
# it prints and notes what was elided (never a silent cap).
function _table_text(t; maxrows::Int = 20, maxcols::Int = 20, maxcolw::Int = 28)
    t isa AbstractDict || return "[rendered: table]"
    cols = String[c isa AbstractDict ? string(get(c, "name", "")) : string(c) for c in get(t, "columns", Any[])]
    rows = get(t, "rows", Any[])
    opts = get(t, "opts", Dict{String,Any}())
    (isempty(cols) && isempty(rows)) && return "(empty table)"
    nrows_total = Int(get(opts, "nrows", length(rows)))
    ncols_total = Int(get(opts, "ncols", length(cols)))
    showcols = length(cols) > maxcols ? cols[1:maxcols] : cols
    elidedcols = length(cols) - length(showcols)
    trunc1(x) = (s = x === nothing ? "" : string(x); textwidth(s) > maxcolw ? first(s, maxcolw - 1) * "…" : s)
    header = String[showcols...]; elidedcols > 0 && push!(header, "…")
    grid = Vector{Vector{String}}([header])
    for r in rows[1:min(maxrows, length(rows))]
        vals = String[trunc1(i <= length(r) ? r[i] : nothing) for i in 1:length(showcols)]
        elidedcols > 0 && push!(vals, "…")
        push!(grid, vals)
    end
    ncol = length(header)
    w = Int[maximum(row -> textwidth(row[j]), grid) for j in 1:ncol]
    line(row) = rstrip(join((rpad(row[j], w[j]) for j in 1:ncol), "  "))
    io = IOBuffer()
    println(io, line(grid[1]))
    println(io, join(("─"^w[j] for j in 1:ncol), "  "))
    for i in 2:length(grid); println(io, line(grid[i])); end
    shown = length(grid) - 1
    notes = String[]
    shown < nrows_total  && push!(notes, "$(shown) of $(nrows_total) rows")
    elidedcols > 0       && push!(notes, "$(length(showcols)) of $(ncols_total) cols")
    isempty(notes) || println(io, "… showing ", join(notes, ", "))
    return rstrip(String(take!(io)))
end

# Compact text of a cell's result for the agent: the value/stdout, or the error,
# plus a note that rich output (image/chart) rendered (the agent can't see the
# pixels here, but knows it worked); tables are rendered as text so their data IS visible.
_cell_result_text(c::Cell) = (o = c.output; o === nothing ? "(not run)" : _output_result_text(o))
# The agent-facing text for a captured eval result — shared by cells and out-of-band (scratch) evals.
function _output_result_text(o)
    o.exception === nothing ||
        return "ERROR: " * o.exception * (o.backtrace === nothing ? "" : "\n" * first(o.backtrace, 800))
    parts = String[]
    isempty(rstrip(o.stdout)) || push!(parts, rstrip(o.stdout))
    isempty(o.value_repr) || push!(parts, o.value_repr)
    rich = String[]
    isempty(o.display) || push!(rich, join(unique(ch.mime for ch in o.display), "+"))
    isempty(o.echarts) || push!(rich, "echart")
    isempty(rich) || push!(parts, "[rendered: " * join(rich, ", ") * "]")
    for t in o.tables      # a table's DATA is text-renderable — show it (the agent can't see the widget)
        push!(parts, _table_text(t))
    end
    txt = rstrip(join(parts, "\n"))
    return isempty(txt) ? "(ok — no value)" : txt
end

# The notebook as the agent should see it: each cell's id, kind, state, source,
# and (for code) its result.
# ── Read tokens for delta reads ──────────────────────────────────────────────
# Each digest returns a short STATE TOKEN and remembers the per-cell content hashes behind it, so a
# later read with `delta_since=<token>` reports only what changed (added / edited / removed) instead
# of the whole notebook. In-memory + bounded; an unknown/evicted token falls back to a full read.
const _READTOK = Dict{String,Tuple{Vector{String},Dict{String,String}}}()   # "nbid|token" → (cell order, id→hash)
const _READTOK_LOCK = ReentrantLock()
# A cell's content hash for delta detection — source AND result/state, so a re-run (new output) counts.
_cell_state_hash(c::Cell) = string(hash((c.kind, c.source,
                                         c.kind == CODE ? _cell_result_text(c) : "", c.state)); base = 16)
function _read_token!(nbid, order, hashes)
    tok = string(hash(join((string(id, ':', hashes[id]) for id in order), '\n')); base = 16)[1:12]
    lock(_READTOK_LOCK) do
        length(_READTOK) > 400 && empty!(_READTOK)
        _READTOK[string(nbid, '|', tok)] = (copy(order), copy(hashes))
    end
    return tok
end
_read_token_get(nbid, tok) = lock(_READTOK_LOCK) do; get(_READTOK, string(nbid, '|', String(tok)), nothing); end

_trunc(s, n::Int) = (t = String(s); length(t) <= n ? t : first(t, n) * "…")

# FULL content of a cell — source + result.
function _print_cell!(io::IO, c::Cell)
    kind = c.kind == MARKDOWN ? "md" : "code"
    print(io, "\n\n### id=", c.id, "  [", kind, ", ", lowercase(string(c.state)), "]\n")
    print(io, rstrip(c.source))
    c.kind == CODE && print(io, "\n→ ", replace(_cell_result_text(c), "\n" => "\n  "))
end

# ONE compact line per cell — the high-signal map (id, kind, state, defined names, a 1-line result /
# the md heading). Keeps a big notebook's read small; the agent drills into specific cells from here.
function _outline_cell!(io::IO, c::Cell)
    kind = c.kind == MARKDOWN ? "md" : "code"
    print(io, "\nid=", rpad(c.id, 16), " [", kind, ",", lowercase(string(c.state)), "]")
    tags = sort!(String[string(f) for f in c.flags if f !== :opaque])   # user tags (not the inferred :opaque)
    isempty(tags) || print(io, " {", join(tags, " "), "}")
    if c.kind == MARKDOWN
        # The heading (first non-blank line) plus, when that's a heading, the first body sentence —
        # a touch more context than a bare title.
        head = ""; body = ""
        for ln in split(c.source, '\n')
            s = strip(ln); isempty(s) && continue
            if isempty(head)
                head = s; startswith(head, "#") || break        # prose cell → just its first line
            elseif !startswith(s, "#")
                body = s; break
            end
        end
        isempty(head) || print(io, "  ", _trunc(head, 80))
        isempty(body) || print(io, " — ", _trunc(body, 70))
    else
        defs = sort!(String[string(w) for w in cell_definitions(c)])
        isempty(defs) || print(io, "  defines: ", _trunc(join(defs, ", "), 70))
        print(io, "  (", count(==('\n'), c.source) + 1, "L)")
        r = strip(_cell_result_text(c))
        isempty(r) || print(io, "  → ", _trunc(replace(r, "\n" => " "), 80))
    end
end

# Three modes (one tool):
#   default        → compact OUTLINE (one line per cell) — token-cheap map of a big notebook.
#   cells="a,b"    → FULL source+output of just those cells.
#   delta_since=t  → only the cells added/edited/removed since token `t` (else a full read).
# Every read ends by handing back the CURRENT state token (for the next delta).
function notebook_digest(nb::LiveNotebook; delta_since::AbstractString = "", cells::AbstractString = "")
    lock(nb.lock) do
        allc = nb.report.cells
        order = String[c.id for c in allc]
        hashes = Dict{String,String}(c.id => _cell_state_hash(c) for c in allc)
        token = _read_token!(nb.id, order, hashes)
        io = IOBuffer()
        print(io, "Notebook '", nb.id, "' — ", abspath(nb.path), " — ", length(allc),
              " cell(s) — v", nb.version, " — state=", token, " — build-floor: ", floor_status(nb))
        # explicit cell list → full content of those cells
        wanted = String[strip(x) for x in split(cells, r"[,\s]+") if !isempty(strip(x))]
        if !isempty(wanted)
            print(io, "\nFull content of ", length(wanted), " cell(s):")
            for id in wanted
                i = _index_of(allc, id)
                i === nothing ? print(io, "\n\n### id=", id, "  (no such cell)") : _print_cell!(io, allc[i])
            end
            return String(take!(io))
        end
        # delta since a prior token → only the changed cells (full)
        prev = isempty(delta_since) ? nothing : _read_token_get(nb.id, delta_since)
        if prev !== nothing
            porder, phash = prev
            cset = Set(order); changed = 0
            removed = String[id for id in porder if !(id in cset)]
            print(io, "\nChanges since ", delta_since, ":")
            for c in allc
                old = get(phash, c.id, nothing)
                status = old === nothing ? "ADDED" : (old != hashes[c.id] ? "CHANGED" : "")
                isempty(status) && continue
                changed += 1
                print(io, "\n\n[", status, "]")
                _print_cell!(io, c)
            end
            isempty(removed) || print(io, "\n\n[REMOVED] ", join(removed, ", "))
            (changed == 0 && isempty(removed)) && print(io, "\n\n(no changes since ", delta_since, ")")
            return String(take!(io))
        end
        # default → compact outline
        isempty(delta_since) || print(io, "\n(delta token unknown/expired — full outline)")
        print(io, "\nOUTLINE (one line per cell). Full source+output: slate_read(cells=\"id1,id2\"). ",
              "Catch up after edits: slate_read(delta_since=\"", token, "\").")
        for c in allc
            _outline_cell!(io, c)
        end
        return String(take!(io))
    end
end

# Push an agent-driven change to open browser tabs (the watcher won't — our own
# file write is canonical, so it doesn't echo back as an external change).
_agent_push!(nb::LiveNotebook) = (nb.version += 1; _broadcast(nb, string(nb.version)))

_cell_exists(nb, id) = _index_of(nb.report.cells, id) !== nothing

# Coarse relative age for a history timestamp (no Dates dep).
function _ago(ts)
    s = max(0, round(Int, time() - Float64(ts)))
    s < 60 ? "$(s)s ago" : s < 3600 ? "$(s ÷ 60)m ago" : s < 86400 ? "$(s ÷ 3600)h ago" : "$(s ÷ 86400)d ago"
end

# Per-cell edit history from the time machine: each recorded version where THIS cell's source
# changed, newest first (version / age / origin / diff-label). Cheap — uses the per-cell digest
# already in each entry, no full-source retrieval. `[]` if history is unavailable.
function _cell_history(path::AbstractString, cellid::AbstractString; limit::Int = 12)
    es = try; SlateHistory.entries(path); catch; return String[]; end
    out = String[]; prev = :none
    for e in es
        cc = nothing
        for cd in get(e, "cells", Any[]); string(get(cd, "id", "")) == cellid && (cc = cd; break); end
        h = cc === nothing ? nothing : string(get(cc, "hash", ""))
        h == prev && continue
        status = cc === nothing ? "absent" : (prev === :none || prev === nothing ? "created" : "edited")
        lbl = string(get(e, "label", "")); src = string(get(e, "source", ""))
        push!(out, string("v", get(e, "seq", "?"), "  ", _ago(get(e, "ts", time())), "  ", status,
                          isempty(src) ? "" : "  [$src]", isempty(lbl) ? "" : "  ($lbl)"))
        prev = h
    end
    return first(reverse(out), limit)
end

"""
    cell_inspect(nb, cellid) -> String

Everything about one cell for the agent's build loop: state (kind/state/deps/reads/writes/
duration/flags), source, the canonical result, and the cell's edit history. The live rendered
DOM + optional raster come from the open browser via a separate path (see `slate.inspect`).
"""
function cell_inspect(nb::LiveNotebook, cellid::AbstractString)
    # Build the canonical text under the lock; do the (blocking) live-browser capture OUTSIDE it.
    text = lock(nb.lock) do
        idx = _index_of(nb.report.cells, cellid)
        idx === nothing && return nothing
        c = nb.report.cells[idx]
        io = IOBuffer()
        kind = c.kind == MARKDOWN ? "md" : "code"
        println(io, "Cell '", c.id, "' in '", nb.id, "' — ", kind, ", ", lowercase(string(c.state)),
                " — position ", idx, "/", length(nb.report.cells), " — v", nb.version)
        if c.kind == CODE
            isempty(c.reads)  || println(io, "reads:    ", join(sort(string.(collect(c.reads))), ", "))
            let defs = cell_definitions(c)
                isempty(defs)      || println(io, "writes:   ", join(sort(string.(collect(defs))), ", "))
            end
            isempty(c.mutates) || println(io, "mutates:  ", join(sort(string.(collect(c.mutates))), ", "))
            isempty(c.deps)   || println(io, "deps:     ", join(sort(collect(c.deps)), ", "))
            o = c.output
            (o !== nothing && o.duration_ms > 0) && println(io, "duration: ", round(o.duration_ms; digits = 2), " ms")
        end
        isempty(c.flags) || println(io, "flags:    ", join(sort(string.(collect(c.flags))), ", "))
        println(io, "\n--- source ---\n", rstrip(c.source))
        c.kind == CODE && println(io, "\n--- result ---\n", _cell_result_text(c))
        h = _cell_history(nb.path, cellid)
        isempty(h) || println(io, "\n--- history (newest first) ---\n", join(h, "\n"))
        return String(take!(io))
    end
    text === nothing && return "No cell '$cellid' in '$(nb.id)'. Use slate.read to list cells."
    # Live capture from the open browser (rendered DOM + console + raster), best-effort: appends
    # nothing when no tab is open or it doesn't answer in time, so this never blocks the build loop.
    cap = request_live_inspect(nb, cellid)
    cap === nothing || (text *= _format_live_capture(cap))
    # Point the agent at the image tool whenever the cell has a viewable figure — a native ECharts
    # canvas / CairoMakie raster, or an html2canvas fill for a figureless cell (all via cell_image).
    cell_image(nb, cellid) === nothing || (text *= "\n(this cell renders a figure — see it with slate.view)")
    return text
end
function _result_of(nb, id)
    i = _index_of(nb.report.cells, id)
    i === nothing ? "(cell $id not found)" : _cell_result_text(nb.report.cells[i])
end

"""
    agent_scratch_eval!(nb, source; ephemeral=false, memo_key="", memo_names=(), memo_threshold=0)

Run `source` in the notebook's LIVE kernel and return its captured output as agent text —
WITHOUT creating a cell or writing the `.jl`. A throwaway diagnostic scratchpad: one-off checks
against the notebook's state that would only litter the notebook as cells. It shares the kernel
namespace (a bare `x = …` leaks, like a REPL), so `ephemeral=true` wraps the code in a `let`
(a child scope whose bindings are discarded) for pure read-only pokes. Serialised with cell runs
via the notebook's eval mutex, so it never races a parallel batch. `memo_*` mirror the cell memo
options for parity with the low-level worker eval.
"""
# ── Scratchpad cells ────────────────────────────────────────────────────────────────────────────
# slate.eval runs surface as VISIBLE, in-memory scratch cells (never in report.cells, so never in the
# dep graph, the `.jl`, or an export). A bounded ring keeps the most recent N; each run pushes the cell
# RUNNING, then updates it FRESH/ERRORED — streamed to the browser's Scratchpad panel over SSE.
const _SCRATCH_MAX = 24
const _SCRATCH_CELL_SEQ = Threads.Atomic{Int}(0)
_scratch_id() = "scratch:" * string(Threads.atomic_add!(_SCRATCH_CELL_SEQ, 1) + 1)
_broadcast_scratch(nb::LiveNotebook, cell::Cell) =
    (try; _broadcast(nb, "scratch:" * JSON.json(cell_json(cell))); catch; end; nothing)
function _push_scratch!(nb::LiveNotebook, cell::Cell)
    lock(nb.lock) do
        push!(nb.scratch, cell)
        length(nb.scratch) > _SCRATCH_MAX && deleteat!(nb.scratch, 1:(length(nb.scratch) - _SCRATCH_MAX))
    end
    _broadcast_scratch(nb, cell)
    return cell
end
"Empty the notebook's scratchpad and tell the browser to clear its panel."
function clear_scratch!(nb::LiveNotebook)
    lock(nb.lock) do; empty!(nb.scratch); end
    try; _broadcast(nb, "scratchclear:"); catch; end
    return nothing
end

function agent_scratch_eval!(nb::LiveNotebook, source::AbstractString;
                             ephemeral::Bool = false, memo_key::AbstractString = "",
                             memo_names = String[], memo_threshold::Real = 0.0)
    src = ephemeral ? "let\n" * String(source) * "\nend" : String(source)
    memo = isempty(memo_key) ? nothing :
        (; key = String(memo_key), names = collect(String, memo_names), threshold = Float64(memo_threshold))
    cell = Cell(_scratch_id(), CODE, String(source))   # display the ORIGINAL source, not the let-wrap
    cell.state = RUNNING
    _push_scratch!(nb, cell)                            # surface it immediately (running) in the panel
    out = lock(_eval_mutex(nb)) do
        ReportEngine.eval_capture(nb.kernel, nb.report, src, "scratch", memo)
    end
    cell.output = out
    cell.state = (out !== nothing && out.exception !== nothing) ? ERRORED : FRESH
    _broadcast_scratch(nb, cell)                        # push the finished cell (result / error)
    return _output_result_text(out)
end

# ── Background scratch-eval jobs ─────────────────────────────────────────────────────────────────
# A slate.eval that outruns the grace window is promoted to a background JOB (mirrors the gate `ex`
# tool): the tool call returns a job id instead of blocking to the 300s session-tool cap, the eval
# keeps computing on the worker, and the agent polls `slate.check_eval`. In-memory only — jobs are
# lost on a worker/extension restart (scratch is throwaway by design).
struct ScratchJob
    id::String
    nb::String                            # notebook id (for future per-notebook listing)
    started::Float64
    task::Task
    result::Ref{Union{Nothing,String}}    # filled by the task when the eval finishes
    done::Ref{Bool}
end
const _SCRATCH_JOBS = Dict{String,ScratchJob}()
const _SCRATCH_LOCK = ReentrantLock()
const _SCRATCH_SEQ = Threads.Atomic{Int}(0)
_new_scratch_id() = "sj" * string(Threads.atomic_add!(_SCRATCH_SEQ, 1) + 1)
# Grace window before a slow scratch eval is handed back as a job id (overridable). Well under the
# 300s session-tool cap that was truncating long evals.
_scratch_grace() = something(tryparse(Float64, get(ENV, "KAIMONSLATE_SCRATCH_GRACE", "")), 30.0)

"""
    agent_scratch_eval_bg!(nb, source; ephemeral=false, grace=_scratch_grace(), memo_*…)
        -> (; done::Bool, jobid::String, text::String)

Non-blocking scratch eval. Runs `agent_scratch_eval!` on a background task and races it against
`grace` seconds: finishes in time → `(done=true, text=<result>)`; still running → `(done=false,
jobid=<id>, text=<hint>)`, the eval continuing on the worker (poll `slate.check_eval`). The tool
call thus never blocks past `grace`, so it can't hit the session-tool timeout.
"""
function agent_scratch_eval_bg!(nb::LiveNotebook, source::AbstractString;
                                ephemeral::Bool = false, grace::Real = _scratch_grace(),
                                memo_key::AbstractString = "", memo_names = String[],
                                memo_threshold::Real = 0.0)
    resultref = Ref{Union{Nothing,String}}(nothing)
    doneref = Ref(false)
    task = @async begin
        r = try
            agent_scratch_eval!(nb, source; ephemeral = ephemeral, memo_key = memo_key,
                                memo_names = memo_names, memo_threshold = memo_threshold)
        catch e
            "Scratch eval errored: " * sprint(showerror, e)
        end
        resultref[] = r
        doneref[] = true
        r
    end
    jid = _new_scratch_id()
    lock(_SCRATCH_LOCK) do
        _SCRATCH_JOBS[jid] = ScratchJob(jid, nb.id, time(), task, resultref, doneref)
    end
    if timedwait(() -> doneref[], Float64(grace); pollint = 0.1) === :ok
        lock(_SCRATCH_LOCK) do; delete!(_SCRATCH_JOBS, jid); end
        return (; done = true, jobid = "", text = something(resultref[], "(no result)"))
    end
    hint = "⏳ Still running after $(round(Int, grace))s — promoted to background job $jid. Poll it with " *
           "slate.check_eval(job=\"$jid\"). The eval keeps computing on the worker; the notebook's cell " *
           "runs stay paused until it finishes."
    return (; done = false, jobid = jid, text = hint)
end

"Poll a background scratch job: its result if finished (and forget it), else a still-running note."
function scratch_check(jobid::AbstractString)
    job = lock(_SCRATCH_LOCK) do; get(_SCRATCH_JOBS, String(jobid), nothing); end
    job === nothing && return "No such scratch job '$jobid' — it already finished and was collected, or never existed."
    if job.done[]
        lock(_SCRATCH_LOCK) do; delete!(_SCRATCH_JOBS, job.id); end
        return something(job.result[], "(no result)")
    end
    return "⏳ Scratch job $jobid still running ($(round(Int, time() - job.started))s elapsed). Poll again with slate.check_eval."
end

"Add a cell (default code) after `after` (end if empty) WITH `source`, run it,
return id + result. One file write (build the cell with its source up front) so the
async file-watcher can't race the intermediate empty-cell state."
function agent_add_cell!(nb::LiveNotebook, source::AbstractString;
                         after::AbstractString = "", kind::AbstractString = "code",
                         id::AbstractString = "", tags::AbstractString = "",
                         caller::AbstractString = "", expected_version::Int = -1)
    rej = nothing; errmsg = nothing
    cid = lock(nb.lock) do
        rej = _guard_commit(nb; caller = caller, expected_version = expected_version)
        rej === nothing || return ""
        cells = nb.report.cells
        # An explicit id is sanitized to `#%%`-header-safe chars and MUST be unique; else auto-generate.
        nid = ""
        if !isempty(strip(String(id)))
            nid = replace(strip(String(id)), r"[^A-Za-z0-9_]+" => "_")
            isempty(nid)                      && (errmsg = "id cannot be empty"; return "")
            any(c -> c.id == nid, cells)      && (errmsg = "id '$(nid)' is already in use"; return "")
        else
            nid = _gen_id(nb.report)
        end
        i = isempty(after) ? length(cells) : something(_index_of(cells, after), length(cells))
        cell = Cell(nid, kind == "md" ? MARKDOWN : CODE, String(source))
        union!(cell.flags, _parse_tag_symbols(tags))   # optional user tags on the fresh cell
        _snapshot!(nb)
        insert!(cells, i + 1, cell)
        # announce=true → push the new cell to the browser BEFORE eval, so a long-running
        # added cell is visible (stale) immediately instead of only when its eval finishes.
        _commit_structure!(nb, i + 1; announce = true)
        return cell.id
    end
    errmsg === nothing || return "⛔ $errmsg"
    rej === nothing || return rej
    _eval!(nb; wait_for = cid)           # wait OUTSIDE the lock — the agent wants the cell's result
    _renew_floor!(nb, caller)
    _agent_push!(nb)
    return "added id=$cid →\n$(_result_of(nb, cid))"
end

"Replace a cell's source, run it, return its result."
function agent_edit_cell!(nb::LiveNotebook, id::AbstractString, source::AbstractString;
                          tags::AbstractString = "", caller::AbstractString = "", expected_version::Int = -1)
    _cell_exists(nb, id) || return "(no cell id=$id)"
    rej = lock(nb.lock) do
        r = _guard_commit(nb; caller = caller, expected_version = expected_version)
        r === nothing || return r
        # Tags FIRST: the edit below marks the cell stale and its eval can begin immediately, so
        # tags applied after it race the run — a freshly `cache`-tagged cell would evaluate once
        # more under its OLD flags (seen live: the tagged run didn't persist). Empty = leave
        # existing tags untouched (so an ordinary source edit never silently wipes tags).
        isempty(strip(String(tags))) || set_cell_tags!(nb, id, tags)
        edit_cell!(nb, id, source; announce = true)   # show the edited source before its eval finishes
        return nothing
    end
    rej === nothing || return rej
    _eval!(nb; wait_for = id)            # wait OUTSIDE the lock — the agent wants the cell's result
    _renew_floor!(nb, caller)
    _agent_push!(nb)
    return "edited id=$id →\n$(_result_of(nb, id))"
end

"Rename a cell's id (its label). Ids must be unique + `#%%`-header-safe; returns a status string."
function agent_rename_cell!(nb::LiveNotebook, oldid::AbstractString, newid::AbstractString;
                            caller::AbstractString = "", expected_version::Int = -1)
    _cell_exists(nb, oldid) || return "(no cell id=$oldid)"
    rej = nothing; ok = false; msg = ""
    lock(nb.lock) do
        rej = _guard_commit(nb; caller = caller, expected_version = expected_version)
        rej === nothing || return
        ok, msg = rename_cell!(nb, oldid, newid)
    end
    rej === nothing || return rej
    ok || return "⛔ rename failed: $msg"
    _renew_floor!(nb, caller)
    _agent_push!(nb)
    return "renamed $oldid → $(replace(strip(String(newid)), r"[^A-Za-z0-9_]+" => "_"))"
end

"Run one cell (or recompute all stale if `id` empty); return the result(s)."
function agent_run!(nb::LiveNotebook, id::AbstractString = "";
                    caller::AbstractString = "", expected_version::Int = -1)
    rej = lock(nb.lock) do
        r = _guard_commit(nb; caller = caller, expected_version = expected_version)
        r === nothing || return r
        # A specific cell → force it STALE, exactly like the browser play button
        # (edit_cell! force=true). Otherwise eval_stale! only re-runs cells our
        # affected-cell detection already flagged — so a Revise'd src change that
        # we failed to map to this cell would return its cached (stale) result.
        # Like the play button, the force cascades: the re-run may change this cell's
        # outputs (or its side effects — the usual reason to force), so dependents
        # (dataflow AND manual `needs=` edges) restale and force too — a memo restore
        # against unchanged upstream sources would resurrect pre-re-run results.
        if !isempty(id)
            i = findfirst(c -> c.id == id, nb.report.cells)
            if i !== nothing
                frc = get!(Set{String}, _FORCE_RUN, nb.id)
                for did in dependents_of(nb.report, Set([id]))   # closure includes `id` itself
                    j = findfirst(c -> c.id == did, nb.report.cells)
                    j === nothing || (nb.report.cells[j].state = STALE)
                    push!(frc, String(did))
                end
            end
        end
        return nothing
    end
    rej === nothing || return rej
    # Eval OUTSIDE the lock via the async runner, but WAIT (the agent wants the result back).
    isempty(id) ? _drain!(nb) : _eval!(nb; wait_for = id)
    _renew_floor!(nb, caller)
    _agent_push!(nb)
    isempty(id) ? "ran stale cells; notebook is up to date" :
        (_cell_exists(nb, id) ? "id=$id →\n$(_result_of(nb, id))" : "(no cell id=$id)")
end

"Delete a cell."
function agent_delete_cell!(nb::LiveNotebook, id::AbstractString;
                            caller::AbstractString = "", expected_version::Int = -1)
    _cell_exists(nb, id) || return "(no cell id=$id)"
    rej = lock(nb.lock) do
        r = _guard_commit(nb; caller = caller, expected_version = expected_version)
        r === nothing || return r
        delete_cell!(nb, id)
        return nothing
    end
    rej === nothing || return rej
    _renew_floor!(nb, caller)
    _agent_push!(nb)
    return "deleted id=$id"
end

# Delete SEVERAL cells in one guarded, atomic step (a single undo entry) — so an agent removing a
# run of cells makes one call, not one per id. `ids` is any iterable of cell ids; ids that don't
# exist are reported, not fatal (the rest still delete). Mirrors `agent_delete_cell!` for the
# build-floor guard / floor renewal / agent push, folding the whole batch into one commit.
function agent_delete_cells!(nb::LiveNotebook, ids;
                             caller::AbstractString = "", expected_version::Int = -1)
    want = String[strip(String(i)) for i in ids]
    want = String[i for i in want if !isempty(i)]
    isempty(want) && return "(no cell ids given)"
    present = String[id for id in want if _cell_exists(nb, id)]
    absent = String[id for id in want if !_cell_exists(nb, id)]
    isempty(present) && return "(no such cell$(length(want) == 1 ? "" : "s"): $(join(want, ", ")))"
    rej = lock(nb.lock) do
        r = _guard_commit(nb; caller = caller, expected_version = expected_version)
        r === nothing || return r
        delete_cells!(nb, present)
        return nothing
    end
    rej === nothing || return rej
    _renew_floor!(nb, caller)
    _agent_push!(nb)
    msg = "deleted $(_n_cells(length(present))): $(join(present, ", "))"
    isempty(absent) || (msg *= " · not found: $(join(absent, ", "))")
    return msg
end

# Find a live notebook by hub id or by (expanded, absolute) path. (`h` is a `Hub`;
# untyped because `Hub` is defined later in this file.)
function find_live(h, key::AbstractString)
    lock(h.lock) do
        haskey(h.notebooks, key) && return h.notebooks[key]
        f = abspath(expanduser(String(key)))
        for nb in values(h.notebooks)
            abspath(nb.path) == f && return nb
        end
        return nothing
    end
end

# Split a cell into two at the editor cursor (frontend sends the before/after text).
function split_cell!(nb::LiveNotebook, id::AbstractString, before::AbstractString, after::AbstractString)
    i = _index_of(nb.report.cells, id); i === nothing && return nb
    _snapshot!(nb)
    cells = nb.report.cells
    cells[i].source = String(before)
    insert!(cells, i + 1, Cell(_gen_id(nb.report), cells[i].kind, String(after)))
    _commit_structure!(nb, i)
    return nb
end

# Merge a cell with the one below it (frontend sends the already-combined source).
function merge_cell!(nb::LiveNotebook, id::AbstractString, source::AbstractString)
    i = _index_of(nb.report.cells, id)
    (i === nothing || i >= length(nb.report.cells)) && return nb
    _snapshot!(nb)
    cells = nb.report.cells
    cells[i].source = String(source)
    deleteat!(cells, i + 1)
    _commit_structure!(nb, i)
    return nb
end

# Rename a cell's id (its "label"). Ids must be unique and `#%%`-header-safe
# (letters/digits/underscore). Dependencies are by id, so rebuild them after.
function rename_cell!(nb::LiveNotebook, oldid::AbstractString, newid::AbstractString)
    nid = replace(strip(String(newid)), r"[^A-Za-z0-9_]+" => "_")   # fold spaces/punctuation to _
    isempty(nid) && return (false, "id cannot be empty")
    i = _index_of(nb.report.cells, oldid)
    i === nothing && return (false, "no such cell")
    nid == oldid && return (true, "")
    any(c -> c.id == nid, nb.report.cells) && return (false, "id $(nid) is already in use")
    lock(nb.lock) do                     # serialize the mutation + persist vs the async runner (reentrant)
        _snapshot!(nb)
        nb.report.cells[i].id = String(nid)
        build_dependencies!(nb.report)
        _persist!(nb)
    end
    return (true, "")
end

function delete_cell!(nb::LiveNotebook, id::AbstractString)
    i = _index_of(nb.report.cells, id); i === nothing && return nb
    _snapshot!(nb; label = "delete $id")
    _preempt_superseded!(nb, (nb.report.cells[i],))   # deleting a RUNNING cell orphans its eval
    deleteat!(nb.report.cells, i)
    _commit_reorder!(nb)   # recomputes only the deleted cell's (now-broken) dependents, if any
end

_n_cells(n) = "$(n) cell$(n == 1 ? "" : "s")"
# Label for an op over cell ids: a lone cell is named directly ("cut a1b2c3"), several are counted.
_op_label(verb, ids) = length(ids) == 1 ? "$verb $(first(ids))" : "$verb $(_n_cells(length(ids)))"

# Delete several cells atomically (multi-select dd / cut) — one undo step. Restales from the
# first removed position so downstream cells that depended on them recompute. `verb` labels the
# undo entry ("cut"/"delete") so the UI can say "Undo cut 2 cells" / "Undo delete a1b2c3".
function delete_cells!(nb::LiveNotebook, ids; verb::AbstractString = "delete")
    cells = nb.report.cells
    idset = Set(String(i) for i in ids)
    idxs = sort!([i for (i, c) in enumerate(cells) if c.id in idset])
    isempty(idxs) && return nb
    _snapshot!(nb; label = _op_label(verb, [cells[i].id for i in idxs]))
    _preempt_superseded!(nb, [cells[i] for i in idxs])   # deleting RUNNING cells orphans their evals
    for i in Iterators.reverse(idxs)
        deleteat!(cells, i)
    end
    _commit_reorder!(nb)   # recomputes only the removed cells' (now-broken) dependents, if any
    return nb
end

# Insert a list of {kind, source} cells after `after_id` (end if empty) — paste. One undo step;
# like split/merge it runs the pasted cells (the reactive model keeps no cell lingering stale).
function paste_cells!(nb::LiveNotebook, after_id::AbstractString, specs)
    isempty(specs) && return nb
    n = length(specs)
    # A single paste names the new cell in its undo label ("paste a1b2c3"); generate that id up
    # front (one id → no collision) and reuse it. Multi-cell paste labels as "paste N cells".
    single_id = n == 1 ? _gen_id(nb.report) : ""
    _snapshot!(nb; label = n == 1 ? "paste $single_id" : "paste $(_n_cells(n))")
    cells = nb.report.cells
    i = isempty(after_id) ? length(cells) : something(_index_of(cells, after_id), length(cells))
    pos = i
    for spec in specs
        kind = (get(spec, "kind", "code") == "md") ? MARKDOWN : CODE
        src  = String(get(spec, "source", ""))
        nid  = n == 1 ? single_id : _gen_id(nb.report)   # multi: _gen_id sees prior inserts → unique
        pos += 1
        insert!(cells, pos, Cell(nid, kind, src))
    end
    _commit_structure!(nb, i + 1)
    return nb
end

function move_cell!(nb::LiveNotebook, id::AbstractString, dir::AbstractString)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    j = dir == "up" ? i - 1 : i + 1
    (j < 1 || j > length(cells)) && return nb
    _snapshot!(nb)
    cells[i], cells[j] = cells[j], cells[i]
    _commit_reorder!(nb)                             # reorder doesn't change reactive values
end

# Move `id` to just before/after `target_id` (drag-and-drop).
function move_cell_rel!(nb::LiveNotebook, id::AbstractString, target_id::AbstractString, before::Bool)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    _snapshot!(nb)
    c = cells[i]; deleteat!(cells, i)
    j = _index_of(cells, target_id)
    p = j === nothing ? length(cells) + 1 : (before ? j : j + 1)
    insert!(cells, p, c)
    _commit_reorder!(nb)                             # reorder doesn't change reactive values
end

# Set the `controls=` layout of one or more cells (drag-to-host: add / move /
# reorder / remove / re-column). Presentation only — no re-eval; just rewrite the
# `.jl`. The caller sends each affected cell's *full desired* layout as columns of
# names (`[[a,b],[c]]`); empty columns are dropped.
function set_controls_map!(nb::LiveNotebook, map)
    isempty(map) && return nb
    lock(nb.lock) do                     # serialize the mutation + persist vs the async runner
        _snapshot!(nb)
        for (id, cols) in map
            i = _index_of(nb.report.cells, id); i === nothing && continue
            cleaned = Vector{String}[String[String(n) for n in col] for col in cols]
            nb.report.cells[i].controls = filter(!isempty, cleaned)
        end
        _persist!(nb)
    end
    return nb
end

"""
    agent_surface_controls!(nb, id, controls; caller="")

Surface `@bind` controls onto cell `id`'s control strip — the agent-facing form of drag-to-host.
Presentation only (rewrites the `.jl`, no re-eval). `controls` uses the header layout grammar:
`a,b,c` = a row of single controls; `[a,b],c` = a stacked column `[a,b]` then a column `c`; `""`
clears the strip. Names must be `@bind` variables defined somewhere in the notebook (validated,
so a typo is rejected with the available names rather than silently dropped)."""
function agent_surface_controls!(nb::LiveNotebook, id::AbstractString, controls::AbstractString;
                                 caller::AbstractString = "")
    _cell_exists(nb, id) || return "(no cell id=$id)"
    cols = ReportEngine._parse_controls(String(controls))
    known = Set(string(b.name) for c in nb.report.cells for b in c.binds)
    unknown = unique(String[n for col in cols for n in col if !(n in known)])
    if !isempty(unknown)
        avail = sort(collect(known))
        return "⛔ unknown @bind control(s): $(join(unknown, ", ")). " *
               (isempty(avail) ? "This notebook defines no @bind widgets yet." : "Available: $(join(avail, ", ")).")
    end
    set_controls_map!(nb, Dict{String,Any}(String(id) => cols))
    _renew_floor!(nb, caller)
    total = sum(length, cols; init = 0)
    return total == 0 ? "cleared the control strip on id=$id" :
        "surfaced $total control(s) on id=$id: " * join((join(col, "+") for col in cols), ", ")
end

# ── Cell behavior flags ──────────────────────────────────────────────────────────────────────────
# A single primitive drives every behavior-flag toggle (collapse / hidecode / trace / cache / …) and
# their bulk forms, so there's ONE code path and ONE history entry per action (no per-cell flurry).
# Flags fall in two classes: VIEW/meta flags (`:collapsed` fold, `:hidecode` hide the editor) that
# just persist, and EVAL flags (`:trace`, `:cache`, `:nocache`, …) that change the run result — those
# restale the cell so it re-runs. `:collapsed` is the only flag that applies to markdown cells too.
const _EVAL_FLAGS = Set{Symbol}((:trace, :cache, :nocache, :resource, :volatile))
flag_reruns(flag::Symbol) = flag in _EVAL_FLAGS
_flag_code_only(flag::Symbol) = flag !== :collapsed

# Set (`value=true`) or clear a single flag across one or many cells in ONE persist. `ids === nothing`
# ⇒ every applicable cell; a list ⇒ just those (e.g. "all plot cells"). Persisted in the `.jl` header
# token, so it travels with the notebook. Eval flags restale the cells they touch (the caller re-runs).
# Returns whether anything changed — the write + history entry only happen when it did.
function set_cell_flag!(nb::LiveNotebook, flag::Symbol, value::Bool; ids::Union{Nothing,AbstractVector} = nothing)
    idset = ids === nothing ? nothing : Set(String(x) for x in ids)
    codeonly = _flag_code_only(flag); restale = flag_reruns(flag)
    return lock(nb.lock) do
        changed = false
        for c in nb.report.cells
            (idset === nothing || c.id in idset) || continue
            (codeonly && c.kind != CODE) && continue
            (flag in c.flags) == value && continue           # already in the wanted state → skip
            value ? push!(c.flags, flag) : delete!(c.flags, flag)
            restale && (c.state = STALE)
            changed = true
        end
        changed && _persist!(nb)
        changed
    end
end

# Parse a user tag spec into sanitized, header-safe tag Symbols. Accepts either a collection of
# strings (the editor UI) or a single comma/space-separated string (the add/edit tools). Empties are
# dropped; punctuation folds to underscores (mirrors id sanitization) — EXCEPT in `key=value` tags
# (`needs=up,db`): their structural `=` and value-commas are grammar, not noise (folding them silently
# severed every manual edge on the first tag round-trip), so sanitize the key and each value segment
# individually. In the STRING form a `key=value` token binds tighter than the comma separator
# (whitespace-split first), so `needs=a,b cache` is two tags.
function _parse_tag_symbols(tags)
    items = tags isa AbstractString ? split(tags, r"\s+") : tags
    want = Set{Symbol}()
    clean(s) = replace(s, r"[^A-Za-z0-9_]+" => "_")
    for t in items
        s = strip(String(t)); isempty(s) && continue
        m = match(r"^([A-Za-z][A-Za-z0-9_]*)=(.*)$", s)
        if m !== nothing
            vals = [clean(v) for v in eachsplit(m.captures[2], ',') if !isempty(v)]
            isempty(vals) || push!(want, Symbol(string(m.captures[1], "=", join(vals, ","))))
        else
            for p in eachsplit(s, ',')
                isempty(p) || push!(want, Symbol(clean(p)))
            end
        end
    end
    return want
end

# Replace a cell's user TAGS from the editor UI — the known behaviour tags (collapsed / hidecode /
# trace / nocache) plus any free-form metadata. The only internal flag, `:opaque`, is re-derived by
# dependency inference each eval, so it's preserved here. Toggling an eval flag (`trace`/`cache`/…)
# changes the run result, so re-stale the cell in that case (same policy as `set_cell_flag!`).
function set_cell_tags!(nb::LiveNotebook, id::AbstractString, tags)
    lock(nb.lock) do
        i = _index_of(nb.report.cells, id); i === nothing && return nb
        c = nb.report.cells[i]
        had_trace = :trace in c.flags
        had_cache = :cache in c.flags
        had_nocache = :nocache in c.flags
        had_needs = sort!(ReportEngine._manual_needs(c.flags))
        had_mut = sort!(ReportEngine._manual_mutates(c.flags))
        want = _parse_tag_symbols(tags)
        keep = Set(f for f in c.flags if f === :opaque)        # re-derived each eval — keep it
        empty!(c.flags); union!(c.flags, keep); union!(c.flags, want)
        (had_trace != (:trace in c.flags)) && (c.state = STALE)
        # Flipping cache/nocache changes what the NEXT eval persists — restale so the tag takes
        # effect on the next auto-run instead of silently waiting for an unrelated source edit
        # (seen live: a freshly cache-tagged cell stayed fresh and its value never persisted).
        (had_cache != (:cache in c.flags) || had_nocache != (:nocache in c.flags)) && (c.state = STALE)
        # A `needs=` or `mutates=` change rewires the graph: rebuild deps now (the DAG view reads
        # them from the next state pull, not the next run) and restale the cell so it re-runs under
        # the new ordering — its completion restales dependents through the ordinary reactive path.
        if had_needs != sort!(ReportEngine._manual_needs(c.flags)) ||
           had_mut != sort!(ReportEngine._manual_mutates(c.flags))
            build_dependencies!(nb.report)
            c.state = STALE
        end
        _persist!(nb)
    end
    return nb
end

function set_kind!(nb::LiveNotebook, id::AbstractString, kind::AbstractString; source = nothing)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    _snapshot!(nb)
    old = cells[i]
    # Carry over the latest (possibly unsaved) editor text on the way through, so a convert never
    # discards edits. Convert + restale the cell and its dependents, but DON'T evaluate: changing a
    # cell's kind must not run the code (the user runs it when ready) — unlike _commit_structure!.
    src = source === nothing ? old.source : String(source)
    cells[i] = Cell(old.id, kind == "md" ? MARKDOWN : CODE, src)
    build_dependencies!(nb.report)
    stale = dependents_of(nb.report, [old.id])
    for c in nb.report.cells
        c.id in stale && (c.state = STALE)
    end
    _persist!(nb)
    _autoindex!(nb)                      # the new source may introduce a `using`
    return nb
end

_json(x) = HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(x))

# HTTP 2.0: request body is a BytesBody wrapper; read it as a String.
function _body(req)
    s = String(req.body)
    isempty(s) && return Dict{String,Any}()
    # Tolerate malformed or non-object bodies: every handler does `get(body, key, …)`, so a bad
    # parse or a JSON array/scalar (`[1,2]`, `"x"`, `5`) must degrade to an empty dict, not 500.
    v = try; JSON.parse(s); catch; nothing; end
    return v isa AbstractDict ? v : Dict{String,Any}()
end

