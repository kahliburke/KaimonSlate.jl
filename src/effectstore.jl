"""
    EffectStore

Durable, per-cell record of the effects a cell DECLARED via the code→Slate channel (`slate_effect`) —
so a cell's per-side classification and its statement-scoped re-establishment survive a hub restart /
notebook reload WITHOUT the declaring cell having to run on main first this session.

Sibling of `MemoStore`: PURE (stdlib `TOML` only — no gate, no KaimonSlate deps), content-addressed by the
cell's OWN source digest (editing the cell → new key → the record is re-established fresh; the old file is
orphaned, never loaded for the new source). One small, human-readable, `ls`-able TOML file per key so a
cell's declared effects are inspectable on disk, mirroring MemoStore's manifests.
"""
module EffectStore

import TOML

# One TOML file per cell src-digest under `root/`. The key is sanitised to a safe filename stem.
_path(root::AbstractString, key::AbstractString) =
    joinpath(root, replace(String(key), r"[^A-Za-z0-9]" => "_") * ".toml")

"""
    store!(root, key, records) -> nothing

Persist a cell's declared effect records — an iterable of `(; kind, names, stmt_src)`. An empty `records`
REMOVES any stale file for `key` (the cell no longer declares anything). Best-effort: a write failure warns
and leaves the prior state, never throws into the caller.
"""
function store!(root::AbstractString, key::AbstractString, records)
    p = _path(root, key)
    if isempty(records)
        isfile(p) && (try; rm(p); catch; end)
        return nothing
    end
    try
        mkpath(root)
        data = Dict("effect" => [Dict("kind"     => String(string(r.kind)),
                                      "names"    => String[string(n) for n in r.names],
                                      "stmt_src" => String(r.stmt_src)) for r in records])
        open(p, "w") do io; TOML.print(io, data); end
    catch e
        @warn "EffectStore: could not persist effects" key = key exception = e
    end
    return nothing
end

"""
    load(root, key) -> Vector{@NamedTuple{kind,names,stmt_src}} | nothing

Load a cell's declared effect records, or `nothing` when none are stored (or the file is unreadable).
"""
function load(root::AbstractString, key::AbstractString)
    p = _path(root, key)
    isfile(p) || return nothing
    try
        d = TOML.parsefile(p)
        haskey(d, "effect") || return nothing
        return [(; kind     = Symbol(e["kind"]),
                   names    = Symbol[Symbol(n) for n in get(e, "names", String[])],
                   stmt_src = String(get(e, "stmt_src", "")))
                for e in d["effect"]]
    catch e
        @warn "EffectStore: could not read effects" key = key exception = e
        return nothing
    end
end

end # module EffectStore
