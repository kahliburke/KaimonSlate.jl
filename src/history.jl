# Durable, content-addressed notebook history — the "time machine" store.
#
# Append-only by design: every distinct notebook state is recorded once, keyed by
# the SHA-256 of its full serialized source. Nothing is ever mutated or deleted, so
# "undo" / "restore" are themselves new entries — it is structurally impossible to
# lose code or lose the ability to go back. Snapshots dedup by content hash, so a
# no-op capture (the periodic draft net while idle) costs nothing.
#
# Layout (one dir per notebook, central cache so the user's working dirs stay clean):
#   <cache>/kaimonslate/history/<key>/
#     meta.json          {path, created}
#     objects/<sha256>   full serialized source (deduped, content-addressed)
#     log.jsonl          append-only, one entry per line:
#       {seq, ts, hash, parent, source, kind, label, cells:[{id,kind,hash}]}
#
# `cells` carries a per-cell digest so the UI can show *which* cells changed and
# offer per-cell recovery without re-parsing every snapshot.
module SlateHistory

using SHA, JSON

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

# In-memory tail cache (key → (seq, last_hash, last_cells)) so `record!` is O(1):
# no full-log re-read on every capture. Primed lazily from disk.
const _LOCK = ReentrantLock()
const _TAIL = Dict{String,Tuple{Int,String,Vector{Any}}}()

function _ensure_dir(path)
    d = _dir(path)
    mkpath(_objdir(d))
    mp = joinpath(d, "meta.json")
    isfile(mp) || write(mp, JSON.json(Dict("path" => _abspath(path), "created" => time())))
    return d
end

# Read every entry (chronological). O(n) — for list/preview, not the hot path.
function entries(path)
    lp = _logpath(_dir(path))
    out = Dict{String,Any}[]
    isfile(lp) || return out
    for l in eachline(lp)
        isempty(strip(l)) && continue
        try; push!(out, JSON.parse(l)); catch; end
    end
    return out
end

# Full serialized source for a recorded hash (nothing if unknown).
function content(path, hash::AbstractString)
    p = joinpath(_objdir(_dir(path)), String(hash))
    isfile(p) ? read(p, String) : nothing
end

# Prime the tail cache for `path` from disk (called under _LOCK).
function _prime!(key, path)
    haskey(_TAIL, key) && return
    es = entries(path)
    _TAIL[key] = isempty(es) ? (0, "", Any[]) :
        (Int(es[end]["seq"]), String(es[end]["hash"]), Vector{Any}(get(es[end], "cells", Any[])))
    return
end

# cells :: iterable of (id, kind, source) — hash each cell body for the digest.
_celldigest(cells) =
    [Dict("id" => string(id), "kind" => string(kind), "hash" => _sha(src)) for (id, kind, src) in cells]

# Derive a human label by diffing this snapshot's cell digest against the previous
# entry's: added / deleted / reordered / edited <ids>. No op-site bookkeeping needed.
function _derive_label(prev_cells, cur)
    pids = [String(c["id"]) for c in prev_cells]
    cids = [String(c["id"]) for c in cur]
    added = [id for id in cids if !(id in pids)]
    removed = [id for id in pids if !(id in cids)]
    isempty(added)   || return "added " * join(added, ", ")
    isempty(removed) || return "deleted " * join(removed, ", ")
    if isempty(prev_cells)
        return isempty(cur) ? "empty" : "initial"
    end
    ph = Dict(String(c["id"]) => String(c["hash"]) for c in prev_cells)
    changed = [String(c["id"]) for c in cur if get(ph, String(c["id"]), "") != String(c["hash"])]
    pids == cids || return "reordered cells"
    isempty(changed) || return "edited " * join(changed, ", ")
    return "snapshot"
end

"""
    record!(path, source; source_label="browser", kind="checkpoint", cells=nothing) -> entry | nothing

Record a notebook snapshot. Deduped by content hash — returns `nothing` (and writes
nothing) when `source` equals the latest recorded state. Otherwise appends a log
entry and stores the content object. `cells` is an iterable of `(id, kind, source)`.
"""
function record!(path, source::AbstractString;
                 source_label::AbstractString = "browser",
                 kind::AbstractString = "checkpoint",
                 cells = nothing)
    h = _sha(source)
    key = _key(path)
    lock(_LOCK) do
        _prime!(key, path)
        seq, last, prev_cells = _TAIL[key]
        last == h && return nothing                       # unchanged — dedup
        d = _ensure_dir(path)
        op = joinpath(_objdir(d), h)
        isfile(op) || write(op, source)
        cdig = cells === nothing ? Dict{String,Any}[] : _celldigest(cells)
        entry = Dict{String,Any}(
            "seq" => seq + 1, "ts" => time(), "hash" => h,
            "parent" => last == "" ? nothing : last,
            "source" => String(source_label), "kind" => String(kind),
            "label" => _derive_label(prev_cells, cdig), "cells" => cdig)
        open(_logpath(d), "a") do io
            println(io, JSON.json(entry))
        end
        _TAIL[key] = (seq + 1, h, Vector{Any}(cdig))
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

end # module SlateHistory
