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
            isempty(s.adds) || Pkg.add(s.adds)
            isempty(s.devs) || Pkg.develop(s.devs)
            return Dict{String,Any}("ok" => true, "message" => "added $(join(s.labels, ", "))")
        else
            return Dict{String,Any}("ok" => false, "message" => "unknown op '$o'")
        end
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end
