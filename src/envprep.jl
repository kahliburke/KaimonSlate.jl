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

# ── workspace-aware project/manifest resolution ───────────────────────────────
# A project listed in an ancestor's `[workspace] projects` has NO manifest of its own — the whole
# workspace shares ONE at the root, under any of Julia's manifest names. Looking for a `Manifest.toml`
# beside the member's Project.toml therefore finds nothing, and a fork seeded from it gets no
# resolution baseline. A member also INHERITS the root's `[sources]`, which is where an unregistered
# dep's path typically lives, so seeding from the member's own `[deps]` alone yields a fork that
# can't resolve it ("expected package `X` to be registered").
#
# This mirrors Base's `base_project` / `project_file_manifest_path` rather than calling them: those
# are internal, and this file is include'd into the standalone worker as well as the engine. Keeping
# the walk identical (including Base's home-directory boundary) means Slate resolves a notebook's
# manifest to exactly the file `using` would.
const _PROJECT_NAMES = ("JuliaProject.toml", "Project.toml")
const _MANIFEST_NAMES = ("JuliaManifest-v$(VERSION.major).$(VERSION.minor).toml",
                         "Manifest-v$(VERSION.major).$(VERSION.minor).toml",
                         "JuliaManifest.toml", "Manifest.toml")

_toml(p::AbstractString) = try; Pkg.TOML.parsefile(p); catch; Dict{String,Any}(); end

"The `Project.toml`/`JuliaProject.toml` in `dir`, or `\"\"`."
function project_file_in(dir::AbstractString)
    for n in _PROJECT_NAMES
        p = joinpath(dir, n)
        isfile(p) && return p
    end
    return ""
end

_same_dir(a, b) = try; samefile(a, b); catch; normpath(abspath(a)) == normpath(abspath(b)); end

"The ancestor project file whose `[workspace] projects` lists `projectfile`'s dir, or `\"\"`."
function workspace_parent(projectfile::AbstractString)
    isfile(projectfile) || return ""
    pdir = abspath(dirname(projectfile))
    home = abspath(homedir())
    in_home = startswith(pdir, home)
    cur = pdir
    while true
        up = dirname(cur)
        up == cur && return ""                       # filesystem root
        in_home && !startswith(up, home) && return ""  # same boundary Base stops at
        bpf = project_file_in(up)
        if !isempty(bpf)
            projects = get(get(_toml(bpf), "workspace", Dict{String,Any}()), "projects", nothing)
            if projects isa AbstractVector
                for pr in projects
                    pp = joinpath(up, String(pr))
                    isdir(pp) && _same_dir(pp, pdir) && return bpf
                end
            end
        end
        cur = up
    end
end

"""
    workspace_chain(projectfile) -> Vector{String}

The workspace roots above `projectfile`, nearest first (empty when it isn't a member). Nested
workspaces are followed, so a member's inherited `[sources]`/`[compat]` can come from any level.
"""
function workspace_chain(projectfile::AbstractString)
    out = String[]
    cur = String(projectfile)
    while true
        nxt = workspace_parent(cur)
        (isempty(nxt) || nxt in out) && return out     # "" or a cycle
        push!(out, nxt)
        cur = nxt
    end
end

"""
    parent_manifest(parent) -> String

Absolute path of the manifest that RESOLVES the project in directory `parent`, or `""` when there
is none. For a workspace member that is the workspace root's shared manifest; otherwise the manifest
beside the project, honouring the versioned (`Manifest-v1.12.toml`) names and an explicit
`manifest = ` key — the same order Julia's loader uses.
"""
function parent_manifest(parent::AbstractString)
    p = String(parent)
    isempty(p) && return ""
    pf = project_file_in(p)
    isempty(pf) || return _manifest_for(pf)
    # No project file, so there is no workspace membership to resolve — just look beside it.
    for n in _MANIFEST_NAMES
        q = joinpath(p, n)
        isfile(q) && return q
    end
    return ""
end

function _manifest_for(projectfile::AbstractString)
    root = workspace_parent(projectfile)
    isempty(root) || return _manifest_for(root)      # a member never holds its own manifest
    dir = dirname(abspath(projectfile))
    ex = get(_toml(projectfile), "manifest", nothing)
    if ex isa AbstractString
        p = normpath(joinpath(dir, ex))
        isfile(p) && return p
    end
    for n in _MANIFEST_NAMES
        p = joinpath(dir, n)
        isfile(p) && return p
    end
    return ""
end

"""
    deps_digest(projectfile, exclude = ()) -> UInt

Hash of every package the notebook's environment loads, as its resolving manifest (`_manifest_for`)
records them, plus the Julia version. It starts from `projectfile`'s direct `[deps]` minus the names
in `exclude` (Slate's own worker packages) and follows each entry's `deps` through the manifest, so
a package reached only through another one counts, and a package only Slate's worker brings doesn't.
Each entry contributes its name, UUID, version, `git-tree-sha1` and any `path`/`repo-url`/`repo-rev`.
A workspace member reads the shared manifest at the workspace root. `UInt(0)` when there is no
manifest or a file does not parse.

This is what lets the memo key change when the code a cached result came from changes outside the
notebook's own source: an upgrade of a dependency of a dependency, or a new Julia.
"""
function deps_digest(projectfile::AbstractString, exclude = ())
    try
        man = _manifest_for(projectfile); isempty(man) && return UInt(0)
        pdeps = sort!([d for d in keys(get(Pkg.TOML.parsefile(projectfile), "deps", Dict{String,Any}()))
                       if !(d in exclude)])
        mdeps = get(Pkg.TOML.parsefile(man), "deps", Dict{String,Any}())   # format 2: "deps" → name → [entry]
        seen = Set{String}()
        todo = copy(pdeps)
        while !isempty(todo)
            dn = pop!(todo)
            dn in seen && continue
            push!(seen, dn)
            entries = get(mdeps, dn, nothing)
            entries isa Vector || continue
            for e in entries
                e isa AbstractDict || continue
                d = get(e, "deps", nothing)
                d isa AbstractVector && append!(todo, String[String(x) for x in d])
                d isa AbstractDict && append!(todo, String[String(k) for k in keys(d)])
            end
        end
        h = hash(string(VERSION), UInt(0x4d616e00))
        for dn in sort!(collect(seen))
            entries = get(mdeps, dn, nothing)
            sig = entries isa Vector ? sort!([join((get(e, k, "") for k in
                                              ("uuid", "version", "git-tree-sha1", "path", "repo-url", "repo-rev")), "|")
                                              for e in entries if e isa AbstractDict]) : String[]
            h = hash((dn, sig), h)
        end
        return h
    catch; return UInt(0); end
end

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

# Make a copied Manifest usable from the scratch fork dir. Two rewrites, one parse:
#
#  • relative `path = "…"` dep entries → absolute. They are relative to the MANIFEST's own directory
#    (the workspace ROOT for a member, which is NOT the parent project dir), which no longer holds
#    once the file is copied elsewhere. (Manifest v2: `deps` maps a name to a vector of entry tables.)
#  • drop `project_hash`. It covers the project the manifest was resolved for — the whole workspace
#    for a shared manifest — and a fork's Project.toml is never byte-identical to that anyway. Left
#    in place, Pkg reports the fork as "changed since the manifest was last resolved" forever, which
#    turns every later `Pkg.add` into a full re-resolve; dropping it lets Pkg recompute against the fork.
function _adapt_fork_manifest!(manifest::AbstractString, base::AbstractString)
    isfile(manifest) || return nothing
    m = try; Pkg.TOML.parsefile(manifest); catch; return nothing; end
    changed = haskey(m, "project_hash")
    delete!(m, "project_hash")
    deps = get(m, "deps", nothing)
    if deps isa AbstractDict
        for (_nm, entries) in deps
            for e in (entries isa AbstractVector ? entries : (entries,))
                if e isa AbstractDict && haskey(e, "path")
                    p = String(e["path"])
                    isabspath(p) || (e["path"] = abspath(joinpath(base, p)); changed = true)
                end
            end
        end
    end
    changed && open(manifest, "w") do io; Pkg.TOML.print(io, m); end
    return nothing
end

# A workspace member INHERITS the roots' `[sources]` and has its `[compat]` resolved across the whole
# workspace — but a fork is a standalone env with nothing above it to inherit from, so those entries
# have to be folded in at seed time or the fork can't resolve what the member could. Restricted to
# names the seed actually declares, because Pkg rejects a `sources`/`compat` entry naming a package
# that is not in `deps`/`weakdeps`/`extras`. Nearest root wins; the member's own always wins.
function _inherit_workspace!(seed::AbstractDict, projectfile::AbstractString)
    chain = workspace_chain(projectfile)
    isempty(chain) && return seed
    declared = Set{String}()
    for k in ("deps", "weakdeps", "extras")
        v = get(seed, k, nothing)
        v isa AbstractDict && union!(declared, String.(keys(v)))
    end
    for root in chain
        rt = _toml(root)
        rdir = dirname(abspath(root))
        src = get(rt, "sources", nothing)
        if src isa AbstractDict
            dst = get!(() -> Dict{String,Any}(), seed, "sources")
            for (nm, s) in _abs_sources(src, rdir)
                (nm in declared && !haskey(dst, nm)) && (dst[nm] = s)
            end
        end
        cmp = get(rt, "compat", nothing)
        if cmp isa AbstractDict
            dst = get!(() -> Dict{String,Any}(), seed, "compat")
            for (nm, c) in cmp
                n = String(nm)
                ((n == "julia" || n in declared) && !haskey(dst, n)) && (dst[n] = c)
            end
        end
    end
    # A root whose entries were all filtered out would otherwise leave an empty table behind.
    for k in ("sources", "compat")
        v = get(seed, k, nothing)
        (v isa AbstractDict && isempty(v)) && delete!(seed, k)
    end
    return seed
end

"""
    seed_env_project!(envdir, parent) -> parent_pkg_name

Write a forked env's `Project.toml` (the parent's `[deps]`+`[compat]`+`[sources]`, with dev paths
made absolute, plus anything it inherits as a workspace member) and copy the manifest that resolves
the parent as the resolution baseline (path deps absolutised). PURE files — the caller does the
`Pkg.develop(parent)` + `Pkg.instantiate()`. Returns the parent package name (`""` when the parent
isn't a package).
"""
function seed_env_project!(envdir::AbstractString, parent::AbstractString)
    mkpath(envdir)
    ppf = project_file_in(parent)
    if isempty(ppf)
        write(joinpath(envdir, "Project.toml"), "")
        return ""
    end
    pdir = dirname(abspath(ppf))
    pt = _toml(ppf)
    seed = Dict{String,Any}()
    haskey(pt, "deps") && (seed["deps"] = pt["deps"])
    haskey(pt, "compat") && (seed["compat"] = pt["compat"])
    haskey(pt, "sources") && (seed["sources"] = _abs_sources(pt["sources"], pdir))
    # `[weakdeps]`/`[extras]` come along because `[compat]` is allowed to name them, and Pkg
    # REJECTS a compat entry naming nothing the project declares ("Compat `X` not listed in
    # `deps`, `weakdeps` or `extras`"). Copying compat while dropping the sections it refers to
    # made every parent with a weakdep or a test-only extra unforkable, and the error names the
    # fork's Project.toml rather than the parent it was seeded from. Neither section installs
    # anything on instantiate, so carrying them costs nothing.
    haskey(pt, "weakdeps") && (seed["weakdeps"] = pt["weakdeps"])
    haskey(pt, "extras") && (seed["extras"] = pt["extras"])
    _inherit_workspace!(seed, ppf)
    open(joinpath(envdir, "Project.toml"), "w") do io; Pkg.TOML.print(io, seed); end
    pmf = parent_manifest(parent)
    if !isempty(pmf)
        dest = joinpath(envdir, "Manifest.toml")
        cp(pmf, dest; force = true)
        _adapt_fork_manifest!(dest, dirname(abspath(pmf)))
    end
    return (haskey(pt, "name") && haskey(pt, "uuid")) ? String(pt["name"]) : ""
end

"""
    readd_specs(delta; pinned = false) -> (; devs, adds, skipped)

`Pkg.PackageSpec` keyword sets that re-create a notebook's OWN packages (its `Slate.env` records)
after a re-seed, each the way it was added: a local checkout (`source = "path"`) is developed from
its path, a git package (`"git"`) is added from its `url#rev`, and any other package is added by
name and uuid. A checkout whose path does not exist on this machine goes to `skipped`, so the rest
still install.

Seeding rebuilds a fork from its PARENT, which knows nothing about what the notebook added, so every
rebuild path re-adds these afterwards. A registry package is left to resolve unless `pinned`: its
recorded version would fight the parent's fresh resolution, which is the thing that just changed.
"""
function readd_specs(delta; pinned::Bool = false)
    devs = NamedTuple[]; adds = NamedTuple[]; skipped = String[]
    for e in (delta isa AbstractVector ? delta : ())
        e isa AbstractDict || continue
        f(k) = string(get(e, k, get(e, Symbol(k), "")))
        nm = f("name")
        isempty(nm) && continue
        src = f("source"); origin = f("origin")
        if src == "path" && !isempty(origin)
            dir = abspath(expanduser(origin))
            isdir(dir) ? push!(devs, (; path = dir)) : push!(skipped, nm)
        elseif src == "git" && !isempty(origin)
            url, rev = (split(origin, '#'; limit = 2)..., "")
            push!(adds, isempty(rev) ? (; url = String(url)) : (; url = String(url), rev = String(rev)))
        else
            uu = f("uuid"); v = f("version")
            s = isempty(uu) ? (; name = nm) : (; name = nm, uuid = uu)
            pinned && !isempty(v) && (s = merge(s, (; version = v)))
            push!(adds, s)
        end
    end
    return (; devs, adds, skipped)
end

"""
    env_add_code(delta) -> String

Pkg code that re-adds the notebook's own packages (`readd_specs`) after a re-seed, for a rebuild
that runs in a subprocess. Checkouts are developed first, so a package that depends on one
resolves against it.
"""
function env_add_code(delta)
    s = readd_specs(delta)
    spec(t) = "Pkg.PackageSpec(" * join(("$k=$(repr(v))" for (k, v) in pairs(t)), ", ") * ")"
    code = ""
    isempty(s.devs) || (code *= "; Pkg.develop([" * join(spec.(s.devs), ", ") * "])")
    isempty(s.adds) || (code *= "; Pkg.add([" * join(spec.(s.adds), ", ") * "])")
    return code
end

# The parent fingerprint the fork was seeded from — everything `seed_env_project!` reads: the parent's
# project file, any workspace roots above it (their `[sources]`/`[compat]` are seeded in, so an edit up
# there has to stale the fork too), and the manifest that resolves it. Any change — a dep added, a
# re-resolve — flips it, so a fork seeded from the old state reads as stale.
# For an ordinary project this hashes the same bytes in the same order as before, so existing forks
# don't all go stale on upgrade.
function env_parent_fingerprint(parent::AbstractString)
    isempty(parent) && return ""
    ppf = project_file_in(parent)
    isempty(ppf) && return string(hash(UInt8[]); base = 16)
    io = IOBuffer()
    write(io, read(ppf))
    for root in workspace_chain(ppf)
        isfile(root) && write(io, read(root))
    end
    pmf = _manifest_for(ppf)
    isempty(pmf) || write(io, read(pmf))
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
