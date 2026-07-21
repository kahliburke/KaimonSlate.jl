# ── Notebook-env preparation policy (shared: engine + worker) ─────────────────
# The SINGLE policy for materialising a notebook's per-notebook worker env from its parent project,
# used by BOTH the local path (worker.jl `_seed_notebook_env!`; the hub's staleness/rebuild in
# NotebookServer) and the remote provisioner (remote.jl). Pure TOML/file ops — no Pkg resolve, no
# transport — so it `include`s into ReportEngine AND the standalone SlateWorker alike. The transports
# differ (local filesystem vs ssh/rsync); THIS is the policy they share:
#   • seed a fork from its parent (deps/compat/sources + the Manifest as the resolution baseline),
#   • rewrite dev/path deps to ABSOLUTE paths (a fork lives in a scratch dir, so a parent's
#     `path="../lib/X"` would otherwise dangle — the class of bug that crashed extension notebooks
#     whose SDK is a `[sources]` path dep),
#   • FINGERPRINT the parent so a later parent change (a dep added, a re-resolve) is detected as
#     stale and the fork rebuilt — the robustness the remote path already had and the local didn't.
import Pkg   # Pkg.TOML only

# `[sources]` with every relative `path` rewritten absolute (anchored on `base`), so a parent's
# dev/path dep still resolves once its env is copied into a scratch fork dir.
function _abs_sources(sources, base::AbstractString)
    out = Dict{String,Any}()
    for (nm, s) in sources
        if s isa AbstractDict && haskey(s, "path")
            p = String(s["path"])
            s = merge(Dict{String,Any}(String(k) => v for (k, v) in s),
                      Dict{String,Any}("path" => isabspath(p) ? p : abspath(joinpath(base, p))))
        end
        out[String(nm)] = s
    end
    return out
end

# Rewrite any relative `path = "…"` in a Manifest's dep entries to an absolute path anchored on
# `base` — the copied Manifest's path deps are relative to the PARENT, which no longer holds from the
# scratch fork dir. (Manifest v2: `deps` maps a name to a vector of entry tables.)
function _abspath_manifest_deps!(manifest::AbstractString, base::AbstractString)
    isfile(manifest) || return nothing
    m = try; Pkg.TOML.parsefile(manifest); catch; return nothing; end
    deps = get(m, "deps", nothing)
    deps isa AbstractDict || return nothing
    changed = false
    for (_nm, entries) in deps
        for e in (entries isa AbstractVector ? entries : (entries,))
            if e isa AbstractDict && haskey(e, "path")
                p = String(e["path"])
                isabspath(p) || (e["path"] = abspath(joinpath(base, p)); changed = true)
            end
        end
    end
    changed && open(manifest, "w") do io; Pkg.TOML.print(io, m); end
    return nothing
end

"""
    seed_env_project!(envdir, parent) -> parent_pkg_name

Write a forked env's `Project.toml` (the parent's `[deps]`+`[compat]`+`[sources]`, with dev paths
made absolute) and copy the parent's `Manifest.toml` as the resolution baseline (path deps
absolutised). PURE files — the caller does the `Pkg.develop(parent)` + `Pkg.instantiate()`. Returns
the parent package name (`""` when the parent isn't a package).
"""
function seed_env_project!(envdir::AbstractString, parent::AbstractString)
    mkpath(envdir)
    ppf = joinpath(parent, "Project.toml")
    if !isfile(ppf)
        write(joinpath(envdir, "Project.toml"), "")
        return ""
    end
    pt = Pkg.TOML.parsefile(ppf)
    seed = Dict{String,Any}()
    haskey(pt, "deps") && (seed["deps"] = pt["deps"])
    haskey(pt, "compat") && (seed["compat"] = pt["compat"])
    haskey(pt, "sources") && (seed["sources"] = _abs_sources(pt["sources"], parent))
    open(joinpath(envdir, "Project.toml"), "w") do io; Pkg.TOML.print(io, seed); end
    pmf = joinpath(parent, "Manifest.toml")
    if isfile(pmf)
        cp(pmf, joinpath(envdir, "Manifest.toml"); force = true)
        _abspath_manifest_deps!(joinpath(envdir, "Manifest.toml"), parent)
    end
    return (haskey(pt, "name") && haskey(pt, "uuid")) ? String(pt["name"]) : ""
end

# The parent fingerprint the fork was seeded from — its Project.toml + Manifest.toml content. Any
# change (a dep added, a re-resolve) flips it, so a fork seeded from the old state reads as stale.
function env_parent_fingerprint(parent::AbstractString)
    isempty(parent) && return ""
    io = IOBuffer()
    for f in ("Project.toml", "Manifest.toml")
        p = joinpath(parent, f)
        isfile(p) && write(io, read(p))
    end
    return string(hash(take!(io)); base = 16)
end

_env_stamp_file(envdir::AbstractString) = joinpath(envdir, ".slate-parent")

"Record the parent fingerprint `envdir` was seeded from (for later [`env_stale`](@ref) checks)."
function stamp_env!(envdir::AbstractString, parent::AbstractString)
    try; write(_env_stamp_file(envdir), env_parent_fingerprint(parent)); catch; end
    return nothing
end

"""
    env_stale(envdir, parent) -> Bool

A forked env is STALE if the parent has changed since it was seeded (or it was never stamped) — the
trigger to rebuild it before booting a worker. Always `false` for a parentless (detached) notebook.
"""
function env_stale(envdir::AbstractString, parent::AbstractString)
    isempty(parent) && return false
    sf = _env_stamp_file(envdir)
    isfile(sf) || return true
    return strip(read(sf, String)) != env_parent_fingerprint(parent)
end
