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

# A structural change at index `idx` reorders state, so conservatively restale
# everything from there on, recompute, and persist.
function _commit_structure!(nb::LiveNotebook, idx::Int)
    build_dependencies!(nb.report)
    for (i, c) in enumerate(nb.report.cells)
        i >= idx && (c.state = STALE)
    end
    eval_stale!(nb.report, nb.kernel)
    _persist!(nb)
    _autoindex!(nb)                      # added/edited cell may introduce a new `using`
    return nb
end

_index_of(cells, id) = findfirst(c -> c.id == id, cells)

function add_cell!(nb::LiveNotebook, after_id::AbstractString, kind::AbstractString; before::Bool = false)
    nid = _gen_id(nb.report)                          # generated up front so the undo label can name it
    _snapshot!(nb; label = "add $nid")
    cells = nb.report.cells
    i = isempty(after_id) ? length(cells) : something(_index_of(cells, after_id), length(cells))
    cell = Cell(nid, kind == "md" ? MARKDOWN : CODE, "")
    pos = before ? max(1, i) : i + 1                 # insert above (at `i`) or below the reference
    insert!(cells, pos, cell)
    _commit_structure!(nb, pos)
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

# Compact text of a cell's result for the agent: the value/stdout, or the error,
# plus a note that rich output (image/chart/table) rendered (the agent can't see
# the pixels here, but knows it worked).
function _cell_result_text(c::Cell)
    o = c.output
    o === nothing && return "(not run)"
    o.exception === nothing ||
        return "ERROR: " * o.exception * (o.backtrace === nothing ? "" : "\n" * first(o.backtrace, 800))
    parts = String[]
    isempty(rstrip(o.stdout)) || push!(parts, rstrip(o.stdout))
    isempty(o.value_repr) || push!(parts, o.value_repr)
    rich = String[]
    isempty(o.display) || push!(rich, join(unique(ch.mime for ch in o.display), "+"))
    isempty(o.echarts) || push!(rich, "echart")
    isempty(o.tables)  || push!(rich, "table")
    isempty(rich) || push!(parts, "[rendered: " * join(rich, ", ") * "]")
    txt = rstrip(join(parts, "\n"))
    return isempty(txt) ? "(ok — no value)" : txt
end

# The notebook as the agent should see it: each cell's id, kind, state, source,
# and (for code) its result.
function notebook_digest(nb::LiveNotebook)
    lock(nb.lock) do
        io = IOBuffer()
        print(io, "Notebook '", nb.id, "' — ", abspath(nb.path), " — ", length(nb.report.cells),
              " cell(s) — v", nb.version, " — build-floor: ", floor_status(nb))
        for c in nb.report.cells
            kind = c.kind == MARKDOWN ? "md" : "code"
            print(io, "\n\n### id=", c.id, "  [", kind, ", ", lowercase(string(c.state)), "]\n")
            print(io, rstrip(c.source))
            c.kind == CODE && print(io, "\n→ ", replace(_cell_result_text(c), "\n" => "\n  "))
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
    lock(nb.lock) do
        idx = _index_of(nb.report.cells, cellid)
        idx === nothing && return "No cell '$cellid' in '$(nb.id)'. Use slate.read to list cells."
        c = nb.report.cells[idx]
        io = IOBuffer()
        kind = c.kind == MARKDOWN ? "md" : "code"
        println(io, "Cell '", c.id, "' in '", nb.id, "' — ", kind, ", ", lowercase(string(c.state)),
                " — position ", idx, "/", length(nb.report.cells), " — v", nb.version)
        if c.kind == CODE
            isempty(c.reads)  || println(io, "reads:    ", join(sort(string.(collect(c.reads))), ", "))
            isempty(c.writes) || println(io, "writes:   ", join(sort(string.(collect(c.writes))), ", "))
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
end
function _result_of(nb, id)
    i = _index_of(nb.report.cells, id)
    i === nothing ? "(cell $id not found)" : _cell_result_text(nb.report.cells[i])
end

"Add a cell (default code) after `after` (end if empty) WITH `source`, run it,
return id + result. One file write (build the cell with its source up front) so the
async file-watcher can't race the intermediate empty-cell state."
function agent_add_cell!(nb::LiveNotebook, source::AbstractString;
                         after::AbstractString = "", kind::AbstractString = "code",
                         caller::AbstractString = "", expected_version::Int = -1)
    rej = nothing
    cid = lock(nb.lock) do
        rej = _guard_commit(nb; caller = caller, expected_version = expected_version)
        rej === nothing || return ""
        cells = nb.report.cells
        i = isempty(after) ? length(cells) : something(_index_of(cells, after), length(cells))
        cell = Cell(_gen_id(nb.report), kind == "md" ? MARKDOWN : CODE, String(source))
        _snapshot!(nb)
        insert!(cells, i + 1, cell)
        _commit_structure!(nb, i + 1)        # build deps, restale from here, eval, one write
        return cell.id
    end
    rej === nothing || return rej
    _renew_floor!(nb, caller)
    _agent_push!(nb)
    return "added id=$cid →\n$(_result_of(nb, cid))"
end

"Replace a cell's source, run it, return its result."
function agent_edit_cell!(nb::LiveNotebook, id::AbstractString, source::AbstractString;
                          caller::AbstractString = "", expected_version::Int = -1)
    _cell_exists(nb, id) || return "(no cell id=$id)"
    rej = lock(nb.lock) do
        r = _guard_commit(nb; caller = caller, expected_version = expected_version)
        r === nothing || return r
        edit_cell!(nb, id, source)
        return nothing
    end
    rej === nothing || return rej
    _renew_floor!(nb, caller)
    _agent_push!(nb)
    return "edited id=$id →\n$(_result_of(nb, id))"
end

"Run one cell (or recompute all stale if `id` empty); return the result(s)."
function agent_run!(nb::LiveNotebook, id::AbstractString = "";
                    caller::AbstractString = "", expected_version::Int = -1)
    rej = lock(nb.lock) do
        r = _guard_commit(nb; caller = caller, expected_version = expected_version)
        r === nothing || return r
        eval_stale!(nb.report, nb.kernel)
        return nothing
    end
    rej === nothing || return rej
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
    _snapshot!(nb)
    nb.report.cells[i].id = String(nid)
    build_dependencies!(nb.report)
    _persist!(nb)
    return (true, "")
end

function delete_cell!(nb::LiveNotebook, id::AbstractString)
    i = _index_of(nb.report.cells, id); i === nothing && return nb
    _snapshot!(nb; label = "delete $id")
    deleteat!(nb.report.cells, i)
    _commit_structure!(nb, max(1, i))
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
    for i in Iterators.reverse(idxs)
        deleteat!(cells, i)
    end
    _commit_structure!(nb, max(1, first(idxs)))
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
    _commit_structure!(nb, min(i, j))
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
    _commit_structure!(nb, min(i, p))
end

# Set the `controls=` layout of one or more cells (drag-to-host: add / move /
# reorder / remove / re-column). Presentation only — no re-eval; just rewrite the
# `.jl`. The caller sends each affected cell's *full desired* layout as columns of
# names (`[[a,b],[c]]`); empty columns are dropped.
function set_controls_map!(nb::LiveNotebook, map)
    isempty(map) && return nb
    _snapshot!(nb)
    for (id, cols) in map
        i = _index_of(nb.report.cells, id); i === nothing && continue
        cleaned = Vector{String}[String[String(n) for n in col] for col in cols]
        nb.report.cells[i].controls = filter(!isempty, cleaned)
    end
    _persist!(nb)
    return nb
end

# Fold / unfold a cell (view-only; persisted in the `.jl` header as the `collapsed` token, so it
# travels with the notebook). No re-eval — just flip the flag and rewrite the file.
function set_collapsed!(nb::LiveNotebook, id::AbstractString, collapsed::Bool)
    lock(nb.lock) do
        i = _index_of(nb.report.cells, id); i === nothing && return nb
        f = nb.report.cells[i].flags
        collapsed ? push!(f, :collapsed) : delete!(f, :collapsed)
        _persist!(nb)
    end
    return nb
end

# Hide / show a cell's code editor (view-only; persisted in the `.jl` header as the `hidecode`
# token). The output (plot) stays visible — for clean, presentation-style cells. No re-eval.
function set_code_hidden!(nb::LiveNotebook, id::AbstractString, hidden::Bool)
    lock(nb.lock) do
        i = _index_of(nb.report.cells, id); i === nothing && return nb
        f = nb.report.cells[i].flags
        hidden ? push!(f, :hidecode) : delete!(f, :hidecode)
        _persist!(nb)
    end
    return nb
end

function set_kind!(nb::LiveNotebook, id::AbstractString, kind::AbstractString)
    cells = nb.report.cells
    i = _index_of(cells, id); i === nothing && return nb
    _snapshot!(nb)
    old = cells[i]
    cells[i] = Cell(old.id, kind == "md" ? MARKDOWN : CODE, old.source)
    _commit_structure!(nb, i)
end

_json(x) = HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(x))

# HTTP 2.0: request body is a BytesBody wrapper; read it as a String.
function _body(req)
    s = String(req.body)
    return isempty(s) ? Dict{String,Any}() : JSON.parse(s)
end

