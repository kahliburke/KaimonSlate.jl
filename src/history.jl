# Durable, content-addressed notebook history — the "time machine" store.
#
# Append-only and UNBOUNDED by design: every distinct notebook state is recorded once,
# keyed by the SHA-256 of its full serialized source. Nothing is ever mutated or deleted,
# so "undo" / "restore" are themselves new entries — it is structurally impossible to lose
# code or lose the ability to go back (git keeps full history for a reason; so do we).
# Snapshots dedup by content hash, so a no-op capture (the periodic draft net while idle)
# costs nothing.
#
# Layout (one dir per notebook, central cache so the user's working dirs stay clean):
#   <cache>/kaimonslate/history/<key>/
#     meta.json          {path, created}
#     head.json          full current cell digest [{id,kind,hash}] — a keyframe, OVERWRITTEN
#                         each write so the tail cache primes without folding the whole log
#     objects/<sha256>   full serialized source, zstd-compressed (deduped, content-addressed)
#     log.jsonl          append-only, one entry per line:
#       {seq, ts, hash, parent, source, kind, label, chg:[{id,kind,hash}], del:[id]}
#
# Each entry stores only the DELTA — `chg` = cells whose source changed vs the parent,
# `del` = removed cell ids — not the full per-cell digest. Editing one cell in a big
# notebook then costs one small row, not a full-notebook digest per capture (which had
# bloated logs into the tens of MB and stalled the history panel). The delta doubles as a
# per-cell change index: the entries that touched cell X ARE its version timeline, so
# per-cell recovery / undo is a log scan, no full-snapshot re-parse.
module SlateHistory

using SHA, JSON, CodecZstd

const _ROOT = Ref{String}("")
function _root()
    isempty(_ROOT[]) || return _ROOT[]
    cache = get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache"))
    _ROOT[] = joinpath(cache, "kaimonslate", "history")
    return _ROOT[]
end

_abspath(p) = abspath(expanduser(String(p)))
_sha(s) = bytes2hex(sha2_256(codeunits(String(s))))
_key(path) = _sha(_abspath(path))[1:16]
_dir(path) = joinpath(_root(), _key(path))
_objdir(d) = joinpath(d, "objects")
_logpath(d) = joinpath(d, "log.jsonl")
_headpath(d) = joinpath(d, "head.json")

# In-memory tail cache (key → (seq, last_hash, last_cells_full)) so `record!` is O(1):
# no full-log re-read on every capture. `last_cells_full` is the WHOLE ordered digest of
# the last state (needed to diff the next capture into a delta + derive its label); it is
# seeded from the head.json keyframe on first touch. Primed lazily from disk.
const _LOCK = ReentrantLock()
const _TAIL = Dict{String,Tuple{Int,String,Vector{Any}}}()

function _ensure_dir(path)
    d = _dir(path)
    mkpath(_objdir(d))
    mp = joinpath(d, "meta.json")
    isfile(mp) || write(mp, JSON.json(Dict("path" => _abspath(path), "created" => time())))
    return d
end

# ── Object codec ─────────────────────────────────────────────────────────────
# Objects are zstd-compressed on write (source snapshots compress ~3×). Reads auto-detect
# by magic bytes (zstd `28 b5 2f fd`) so any legacy uncompressed object still loads.
_iszstd(b) = length(b) >= 4 && b[1] == 0x28 && b[2] == 0xb5 && b[3] == 0x2f && b[4] == 0xfd
_zcompress(s) = transcode(ZstdCompressor, Vector{UInt8}(codeunits(String(s))))
function _zread(p)
    isfile(p) || return nothing
    b = read(p)
    return _iszstd(b) ? String(transcode(ZstdDecompressor, b)) : String(b)
end

# Read entries (chronological order).
function entries(path)
    lp = _logpath(_dir(path))
    isfile(lp) || return Dict{String,Any}[]
    out = Dict{String,Any}[]
    for l in eachline(lp)
        isempty(strip(l)) && continue
        try; push!(out, JSON.parse(l)); catch; end
    end
    return out
end

# Full serialized source for a recorded hash (nothing if unknown). Objects are
# SHA-256-named, so a hash that isn't 64 hex chars is invalid — reject it outright
# rather than let `../…` escape the object dir (arbitrary file read / overwrite).
function content(path, hash::AbstractString)
    occursin(r"^[0-9a-f]{64}$", String(hash)) || return nothing
    return _zread(joinpath(_objdir(_dir(path)), String(hash)))
end

# ── Digests / deltas ─────────────────────────────────────────────────────────
# cells :: iterable of (id, kind, source) — hash each cell body for the full digest.
_celldigest(cells) =
    [Dict("id" => string(id), "kind" => string(kind), "hash" => _sha(src)) for (id, kind, src) in cells]

# Diff a full previous digest against a full current one → (chg, del): `chg` is every cell
# whose source-hash is new or changed, `del` every id that vanished. This is what the log
# actually stores (the unchanged bulk is dropped).
function _delta(prev, cur)
    ph = Dict(String(c["id"]) => String(c["hash"]) for c in prev)
    seen = Set{String}()
    chg = Dict{String,Any}[]
    for c in cur
        id = string(c["id"]); push!(seen, id)
        (haskey(ph, id) && ph[id] == string(c["hash"])) && continue
        push!(chg, Dict("id" => id, "kind" => string(c["kind"]), "hash" => string(c["hash"])))
    end
    del = String[String(c["id"]) for c in prev if !(string(c["id"]) in seen)]
    return chg, del
end

# Rebuild the full ordered digest by folding the whole log (legacy `cells` keyframes or
# `chg`/`del` deltas). Only used as a fallback when head.json is absent (pre-migration).
function _fold_cells(es)
    order = String[]; by = Dict{String,Dict{String,Any}}()
    for e in es
        if haskey(e, "cells")            # legacy full snapshot → replaces state wholesale
            order = String[string(c["id"]) for c in e["cells"]]
            empty!(by)
            for c in e["cells"]
                by[string(c["id"])] = Dict{String,Any}("id" => string(c["id"]),
                    "kind" => string(c["kind"]), "hash" => string(c["hash"]))
            end
        else
            for c in get(e, "chg", Any[])
                id = string(c["id"]); haskey(by, id) || push!(order, id)
                by[id] = Dict{String,Any}("id" => id,
                    "kind" => string(get(c, "kind", "code")), "hash" => string(c["hash"]))
            end
            for id in get(e, "del", Any[])
                id = string(id); delete!(by, id); filter!(!=(id), order)
            end
        end
    end
    return Any[by[id] for id in order if haskey(by, id)]
end

# Prime the tail cache for `path` from disk (called under _LOCK). Seeds the full last
# digest from the head.json keyframe (fast); falls back to the last legacy `cells` entry
# or a full fold when head.json is missing.
function _prime!(key, path)
    haskey(_TAIL, key) && return
    d = _dir(path)
    es = entries(path)
    if isempty(es)
        _TAIL[key] = (0, "", Any[])
        return
    end
    last = es[end]
    hp = _headpath(d)
    full = if isfile(hp)
        try; Vector{Any}(JSON.parse(read(hp, String))); catch; Any[]; end
    elseif haskey(last, "cells")
        Vector{Any}(last["cells"])
    else
        _fold_cells(es)
    end
    _TAIL[key] = (Int(last["seq"]), String(last["hash"]), full)
    return
end

# ── Labels ───────────────────────────────────────────────────────────────────
# Derive a human label by diffing the previous full digest against the current one:
# added / deleted / renamed / reordered / edited <ids>. No op-site bookkeeping needed.
# Summarize a list of cell ids: name them if few, count them if many (so a whole-notebook
# rewrite reads as "deleted 13 cells", not a wall of ids).
_summ(ids) = length(ids) <= 4 ? join(ids, ", ") : "$(length(ids)) cells"

function _derive_label(prev_cells, cur)
    isempty(prev_cells) && return isempty(cur) ? "empty" : "initial"
    pids = [String(c["id"]) for c in prev_cells]
    cids = [String(c["id"]) for c in cur]
    ph = Dict(String(c["id"]) => String(c["hash"]) for c in prev_cells)
    ch = Dict(String(c["id"]) => String(c["hash"]) for c in cur)
    added   = [id for id in cids if !(id in pids)]
    removed = [id for id in pids if !(id in cids)]
    # Rename detection (git-style): the per-cell digest hashes the SOURCE only, not the
    # id — so a removed id and an added id with the same content hash are one cell whose
    # id changed. Pair them up and label it a rename, not a delete+add. (A cell renamed
    # AND edited won't match by hash → it falls back to added/deleted, which is honest.)
    renames = Tuple{String,String}[]
    avail = copy(added)
    for r in removed
        i = findfirst(a -> ch[a] == ph[r], avail)
        i === nothing && continue
        push!(renames, (r, avail[i])); deleteat!(avail, i)
    end
    if !isempty(renames)
        newids = Set(a for (_, a) in renames); oldids = Set(r for (r, _) in renames)
        added   = [a for a in added if !(a in newids)]
        removed = [r for r in removed if !(r in oldids)]
    end
    changed = [id for id in cids if (id in pids) && ph[id] != ch[id]]
    # Report EVERY kind of change — a destructive overwrite (adds + deletes) must
    # not hide behind the additions.
    parts = String[]
    isempty(renames) || push!(parts, length(renames) <= 3 ?
        join(("renamed $r → $a" for (r, a) in renames), ", ") : "renamed $(length(renames)) cells")
    isempty(added)   || push!(parts, "added "   * _summ(added))
    isempty(removed) || push!(parts, "deleted " * _summ(removed))
    isempty(changed) || push!(parts, "edited "  * _summ(changed))
    isempty(parts) || return join(parts, "; ")
    pids == cids || return "reordered cells"
    return "snapshot"
end

"""
    record!(path, source; source_label="browser", kind="checkpoint", cells=nothing, label="") -> entry | nothing

Record a notebook snapshot. Deduped by content hash — returns `nothing` (and writes
nothing) when `source` equals the latest recorded state. Otherwise appends a delta log
entry, stores the (zstd) content object, and refreshes the head keyframe. `cells` is an
iterable of `(id, kind, source)`.
"""
function record!(path, source::AbstractString;
                 source_label::AbstractString = "browser",
                 kind::AbstractString = "checkpoint",
                 cells = nothing,
                 label::AbstractString = "")   # explicit action label; overrides the source-diff derivation
    h = _sha(source)
    key = _key(path)
    lock(_LOCK) do
        _prime!(key, path)
        seq, last, prev_cells = _TAIL[key]
        last == h && return nothing                       # unchanged — dedup
        d = _ensure_dir(path)
        op = joinpath(_objdir(d), h)
        isfile(op) || write(op, _zcompress(source))
        cur = cells === nothing ? Dict{String,Any}[] : _celldigest(cells)  # full ordered digest
        chg, del = _delta(prev_cells, cur)
        entry = Dict{String,Any}(
            "seq" => seq + 1, "ts" => time(), "hash" => h,
            "parent" => last == "" ? nothing : last,
            "source" => String(source_label), "kind" => String(kind),
            # A flag/metadata toggle changes header tokens, not cell SOURCE, so the source-diff can't
            # describe it — callers pass an explicit `label` for those ("hid code · cellA", …).
            "label" => isempty(label) ? _derive_label(prev_cells, cur) : String(label),
            "chg" => chg, "del" => del)
        open(_logpath(d), "a") do io
            println(io, JSON.json(entry))
        end
        write(_headpath(d), JSON.json(cur))               # refresh keyframe (overwritten, never grows)
        _TAIL[key] = (seq + 1, h, Vector{Any}(cur))
        return entry
    end
end

# Latest recorded hash for `path` ("" if none) — lets callers cheaply check whether
# a state is already captured without reading the log.
function latest_hash(path)
    key = _key(path)
    lock(_LOCK) do
        _prime!(key, path)
        return _TAIL[key][2]::String
    end
end

# Version timeline for a single cell: the entries where cell `cellid`'s SOURCE changed,
# NEWEST FIRST, each carrying the STATE hash (to fetch the full snapshot), ts and label.
# Source extraction is the caller's job (parse the snapshot) — SlateHistory doesn't know
# the notebook grammar. Powers per-cell recovery and the editor's undo-through-history.
function cell_versions(path, cellid::AbstractString)
    out = Dict{String,Any}[]
    for e in entries(path)
        any(cd -> string(get(cd, "id", "")) == cellid, get(e, "chg", Any[])) || continue
        push!(out, Dict{String,Any}(
            "seq" => get(e, "seq", 0), "ts" => get(e, "ts", 0.0),
            "hash" => String(get(e, "hash", "")), "label" => string(get(e, "label", ""))))
    end
    reverse!(out)
    return out
end

# ── One-time migration ───────────────────────────────────────────────────────
# Convert every notebook history under the cache root from the old full-digest log to the
# compact delta form, and zstd-compress every object. Idempotent: delta entries and
# already-compressed objects pass through untouched (the magic-byte check reads only 4
# bytes, so re-runs are cheap). Writes a head.json keyframe per notebook. A marker file
# makes the common "already migrated" case skip the scan entirely.
function _migrate_dir!(keydir; sink)
    lp = _logpath(keydir)
    isfile(lp) || return
    es = Dict{String,Any}[]
    for l in eachline(lp)
        isempty(strip(l)) && continue
        try; push!(es, JSON.parse(l)); catch; end
    end
    sink[:log_before] += filesize(lp)
    # Rewrite the log: legacy full-`cells` entries become deltas; delta entries pass through.
    prev = Any[]; changed = false; io = IOBuffer()
    for e in es
        if haskey(e, "cells")
            cur = Vector{Any}(e["cells"])
            chg, del = _delta(prev, cur)
            ne = Dict{String,Any}()
            for k in ("seq", "ts", "hash", "parent", "source", "kind", "label")
                haskey(e, k) && (ne[k] = e[k])
            end
            haskey(ne, "label") || (ne["label"] = _derive_label(prev, cur))
            ne["chg"] = chg; ne["del"] = del
            println(io, JSON.json(ne))
            prev = cur; changed = true
        else
            println(io, JSON.json(e))
        end
    end
    if changed
        tmp = lp * ".tmp"; write(tmp, String(take!(io))); mv(tmp, lp; force = true)
    end
    sink[:log_after] += filesize(lp)
    write(_headpath(keydir), JSON.json(_fold_cells(es)))
    # Compress objects (magic-check reads 4 bytes; only legacy objects are rewritten).
    od = _objdir(keydir)
    if isdir(od)
        for f in readdir(od; join = true)
            isfile(f) || continue
            sz = filesize(f); sink[:obj_before] += sz
            magic = open(io2 -> read(io2, min(sz, 4)), f)
            if _iszstd(magic)
                sink[:obj_after] += sz
            else
                cb = transcode(ZstdCompressor, read(f))
                tmp = f * ".tmp"; write(tmp, cb); mv(tmp, f; force = true)
                sink[:obj_after] += length(cb)
            end
        end
    end
    sink[:dirs] += 1
    return
end

function migrate!(; verbose::Bool = true)
    root = _root()
    sink = Dict(:dirs => 0, :log_before => 0, :log_after => 0, :obj_before => 0, :obj_after => 0)
    isdir(root) || return sink
    for keydir in readdir(root; join = true)
        isdir(keydir) || continue
        try; _migrate_dir!(keydir; sink = sink); catch e
            verbose && @warn "SlateHistory.migrate!: skipped $keydir" exception = (e, catch_backtrace())
        end
    end
    lock(_LOCK) do; empty!(_TAIL); end     # force re-prime under the new format
    write(joinpath(root, ".migrated_v2"), string(time()))
    verbose && @info "SlateHistory.migrate! done" dirs = sink[:dirs] log_MB =
        round((sink[:log_before] - sink[:log_after]) / 1e6; digits = 1) obj_MB =
        round((sink[:obj_before] - sink[:obj_after]) / 1e6; digits = 1)
    return sink
end

# Run migrate! once per cache root (marker-gated), at server startup.
function migrate_once!(; verbose::Bool = true)
    isfile(joinpath(_root(), ".migrated_v2")) && return
    migrate!(; verbose = verbose)
    return
end

end # module SlateHistory
