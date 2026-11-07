# Package operations a notebook asks for (`slate_pkg`, the package pane), shared by the worker
# (`__slate_pkg`) and the in-process kernel (`pkg_op`) so both accept the same specs. They run
# against the active project; the caller activates the right one.

# Pkg reads the project and manifest through Base's TOML cache, and while a `require` is in flight on
# any task that cache serves each file as it was when the load began. A Pkg operation then misses what
# an earlier one added: its precompile fails with "Unknown package", or it writes back a project
# without that add. The hub serializes package ops with cell evals; this waits out a load the hub
# did not start (a background warm-up, a hot reload).
function _await_loads(; timeout::Real = 300)
    isdefined(Base, :LOADING_CACHE) || return
    t0 = time()
    while Base.LOADING_CACHE[] !== nothing && time() - t0 < timeout
        sleep(0.05)
    end
end

# Classify each add-token into a registry/git spec (→ Pkg.add) or a local-path spec (→ Pkg.develop),
# with a human label. Shared by the notebook-env add and the parent-project add.
function _pkg_add_specs(tokens)
    adds = Pkg.PackageSpec[]; devs = Pkg.PackageSpec[]; labels = String[]
    for tok in tokens
        t = String(tok)
        if occursin(r"^(https?://|git://|git@|ssh://)"i, t) || endswith(t, ".git") || endswith(t, ".git/")
            parts = split(t, '#'; limit = 2)                      # url or url#rev (branch/tag/sha)
            url = String(parts[1]); rev = length(parts) == 2 ? String(parts[2]) : ""
            push!(adds, isempty(rev) ? Pkg.PackageSpec(url = url) : Pkg.PackageSpec(url = url, rev = rev))
        elseif startswith(t, "/") || startswith(t, "~/") || startswith(t, "./") ||
               startswith(t, "../") || isdir(expanduser(t))
            push!(devs, Pkg.PackageSpec(path = abspath(expanduser(t))))
        elseif occursin('@', t)                                   # name@version
            nm, ver = split(t, '@'; limit = 2)
            push!(adds, Pkg.PackageSpec(name = String(nm), version = String(ver)))
        else
            push!(adds, Pkg.PackageSpec(name = t))
        end
        push!(labels, t)
    end
    return (adds = adds, devs = devs, labels = labels)
end

"""
    _pkg_apply(op, name) -> Dict("ok", "message")

Add, update or remove package(s) in the active project. `op` is "add", "update" or "rm". `name` is one
spec, or several separated by whitespace/commas, all applied in a single resolve (one precompile). An
add-spec may be a registry name (`Foo` or `Foo@1.2`), a git URL (`https://…[.git][#rev]`, `git@…`) →
`Pkg.add(url=…)`, or a LOCAL path (`/…`, `~/…`, `./…`, or an existing dir) → `Pkg.develop(path=…)`, so
it's a dev'd dep, hot-reloadable and carried to remote workers.
"""
function _pkg_apply(op, name)
    tokens = filter(!isempty, split(String(name), r"[\s,]+"))
    isempty(tokens) && return Dict{String,Any}("ok" => false, "message" => "empty package name")
    o = String(op)
    _await_loads()
    try
        if o == "rm"
            Pkg.rm(String.(tokens))
            return Dict{String,Any}("ok" => true, "message" => "removed $(join(tokens, ", "))")
        elseif o == "update"
            # Distinct from `add`: adding a package that's already a dep keeps the resolved version,
            # so an upgrade needs `Pkg.update`. Scoped to the named packages — a bare update would
            # move the notebook's whole environment, which is not what "update this one" means.
            Pkg.update(String.(tokens))
            return Dict{String,Any}("ok" => true, "message" => "updated $(join(tokens, ", "))")
        elseif o == "add"
            s = _pkg_add_specs(tokens)
            add_installed_first!(s.adds)    # envprep.jl: reuse versions this depot already holds
            isempty(s.devs) || Pkg.develop(s.devs)
            return Dict{String,Any}("ok" => true, "message" => "added $(join(s.labels, ", "))")
        else
            return Dict{String,Any}("ok" => false, "message" => "unknown op '$o'")
        end
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

"""
    _same_registry(reg, url) -> Bool

Does an installed registry point at `url`? Compared on `repo`, which is the only field carrying it:
a `RegistryInstance` has NO `url` field, and reading one throws a `FieldError` that surfaces to the
user as "could not add the registry". That failure appears only on a machine which does not already
have the registry — precisely the machine the add path exists for.

Trailing `.git`, a trailing slash and case are all ignored, so the spelling a user pastes matches.
"""
function _same_registry(reg, url::AbstractString)
    repo = try; something(reg.repo, ""); catch; ""; end
    norm(s) = lowercase(rstrip(replace(String(s), r"\.git$" => ""), '/'))
    return !isempty(repo) && norm(repo) == norm(url)
end

"The active project's direct dependencies as `{name, version, uuid, source, origin}` (for eager docs
auto-index + the package viewer). `source` = \"registry\" | \"path\" (a dev'd local checkout) | \"git\"
(added from a URL); `origin` carries the path or `url#rev` for the non-registry ones — so the UI can flag
that a dep points at something machine-specific rather than a pinned registry release."
function _project_deps()
    out = Dict{String,Any}[]
    try
        proj = Pkg.project()
        info = Pkg.dependencies()
        for (name, uuid) in proj.dependencies
            pi = get(info, uuid, nothing)
            ver = (pi === nothing || pi.version === nothing) ? "" : string(pi.version)
            source = "registry"; origin = ""
            if pi !== nothing
                try
                    if getfield(pi, :is_tracking_path)
                        source = "path"; origin = String(something(getfield(pi, :source), ""))
                    elseif getfield(pi, :is_tracking_repo)
                        source = "git"
                        url = ""; rev = ""
                        try; url = String(something(getfield(pi, :git_source), "")); catch; end
                        try; rev = String(something(getfield(pi, :git_revision), "")); catch; end
                        origin = isempty(rev) ? url : (isempty(url) ? rev : url * "#" * rev)
                    end
                catch
                end
            end
            push!(out, Dict{String,Any}("name" => name, "version" => ver, "uuid" => string(uuid),
                                        "source" => source, "origin" => origin))
        end
    catch
    end
    return out
end

"Install a package registry into this process's depot. It runs in the kernel rather than the hub
because a notebook on a remote region resolves against the remote depot. Idempotent: an already-installed registry
(matched by url or by name) reports success without touching anything. Returns `{ok, message}`."
function _registry_add(url)
    u = String(url)
    isempty(strip(u)) && return Dict{String,Any}("ok" => false, "message" => "no registry url")
    want = basename(rstrip(replace(u, r"\.git$" => ""), '/'))
    try
        for r in Pkg.Registry.reachable_registries()
            # `repo`, not `url`: a `RegistryInstance` has no `url` field, and reading one throws a
            # FieldError that surfaces as "could not add the registry" — the failure only appears on
            # a machine that does NOT already have it, which is exactly the machine this runs for.
            (_same_registry(r, u) || r.name == want) &&
                return Dict{String,Any}("ok" => true, "message" => "registry $(r.name) already installed")
        end
        Pkg.Registry.add(Pkg.RegistrySpec(; url = u))
        return Dict{String,Any}("ok" => true, "message" => "added registry $want")
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end
