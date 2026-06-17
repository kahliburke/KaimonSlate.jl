# ── Self-contained "single-source .jl" export ────────────────────────────────
# Bundle the notebook together with its FULL resolved environment (Project + Manifest), the
# local / path-dependency source (the parent module code), and — when the project is a git
# repo — a shallow git bundle (so an expanded copy can attach to the original remote and
# open PRs with matching SHAs), all into ONE `.jl`. `expand` reinflates it into a project
# tree that instantiates and runs. The heavy bundle lives ONLY in the exported file; the
# working notebook keeps just the lightweight `Slate.env` delta footer.
#
# Footer layout (terminal, like `Slate.env`): an open marker, the gzip'd tarball as base64
# wrapped into commented lines, then a close marker. `parse_report` strips any `Slate.*`
# block, so a standalone `.jl` still opens as an ordinary notebook.
const _BUNDLE_OPEN = "# ╔═╡ Slate.bundle"
const _BUNDLE_CLOSE = "# ╚═╡ Slate.bundle"

_bundle_footer(b64::AbstractString) = let io = IOBuffer()
    println(io, _BUNDLE_OPEN, " v1 · self-contained env (Project + Manifest + local source). Expand: julia> using KaimonSlate; KaimonSlate.expand(\"this.jl\")")
    for i in 1:100:lastindex(b64)
        println(io, "# ", SubString(b64, i, min(i + 99, lastindex(b64))))
    end
    print(io, _BUNDLE_CLOSE)
    String(take!(io))
end

# Copy a directory's contents into `dest`, skipping `.git` (history travels via the git
# bundle, not as loose objects) — keeps the tarball lean and avoids nested-repo confusion.
function _copy_tree!(dest::AbstractString, src::AbstractString)
    for (root, dirs, files) in walkdir(src)
        filter!(d -> d != ".git", dirs)
        rel = relpath(root, src)
        mkpath(joinpath(dest, rel))
        for f in files
            from = joinpath(root, f)
            try; cp(from, joinpath(dest, rel, f); force = true, follow_symlinks = true); catch; end
        end
    end
    return dest
end

# Canonical path (symlinks resolved) so repo-root and project-dir comparisons line up; falls
# back to `abspath` if the path can't be resolved.
_safe_realpath(p::AbstractString) = try realpath(p) catch; abspath(p) end

# The realpath of the git work-tree root containing `dir`, or `nothing` (no git / not a repo).
function _git_toplevel(dir::AbstractString)
    Sys.which("git") === nothing && return nothing
    top = try
        strip(read(pipeline(`git -C $dir rev-parse --show-toplevel`; stderr = devnull), String))
    catch
        return nothing
    end
    (isempty(top) || !isdir(top)) && return nothing
    return realpath(top)
end

# Add a shallow git bundle of `top` + its `origin` URL, so an expanded copy can `git clone`
# it and attach to the original remote with MATCHING SHAs (branch & PR off the real history).
# A self-contained shallow bundle can't be made with `bundle create --depth` (that needs the
# parent as a prerequisite); the reliable recipe is a depth-1 working clone, then bundle from
# THAT. Returns `true` on success (so the caller can point deduped path-deps at `repo/`).
function _git_bundle!(stage::AbstractString, top::AbstractString)
    try
        sc = joinpath(mktempdir(), "s")
        run(pipeline(`git clone -q --depth=1 file://$top $sc`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $sc bundle create $(joinpath(stage, "repo.gitbundle")) HEAD`; stdout = devnull, stderr = devnull))
        url = try; strip(read(pipeline(`git -C $top remote get-url origin`; stderr = devnull), String)); catch; ""; end
        isempty(url) || write(joinpath(stage, "git-remote.txt"), url)
        return true
    catch
        return false
    end
end

# `src`'s path relative to `top` if it lies within `top` (or IS `top` ⇒ "."), else `nothing`.
function _within(top::AbstractString, src::AbstractString)
    rel = relpath(src, top)
    (rel == "." || !startswith(rel, "..")) ? replace(rel, '\\' => '/') : nothing
end

# True only if the subtree at `top/relpath` has no uncommitted OR untracked changes — i.e. the
# bundled repo's HEAD checkout is byte-identical to the live source, so pointing the env at the
# cloned `repo/` instead of a `local/` copy loses nothing. `--porcelain` lists `??` untracked
# too, so a dirty/partly-untracked package stays conservative (gets its own local copy).
function _subtree_clean(top::AbstractString, relpath::AbstractString)
    spec = relpath == "." ? "." : relpath
    out = try
        read(pipeline(`git -C $top status --porcelain -- $spec`; stderr = devnull), String)
    catch
        return false
    end
    return isempty(strip(out))
end

# Rewrite the staged `Manifest.toml` so each bundled path-dependency points at its in-bundle
# source (a path RELATIVE to the manifest's dir — `local/<name>` for a copied tree, or
# `repo/<rel>` when it's reused straight from the cloned git repo) instead of the author's
# original absolute path — otherwise an expanded copy fails to instantiate with "Missing
# source file" on a machine where that absolute path doesn't exist. `targets` maps dep name →
# relative path. Line-oriented so the generated manifest's formatting is preserved untouched.
function _rewrite_manifest_paths!(manifest::AbstractString, targets::AbstractDict)
    isfile(manifest) || return
    lines = readlines(manifest)
    cur = ""
    for (i, l) in pairs(lines)
        m = match(r"^\[\[deps\.(.+)\]\]$", strip(l))
        if m !== nothing
            cur = String(m.captures[1])
        elseif haskey(targets, cur) && occursin(r"^\s*path\s*=", l)
            lines[i] = "path = " * repr(targets[cur])      # forward slash: Julia/TOML-portable
        end
    end
    write(manifest, join(lines, "\n") * "\n")
    return
end

# Build the base64 tarball from explicit coordinates (kernel-independent, so it's unit
# testable): the active project dir, its path deps `[(name, source)]`, and the notebook.
function _make_bundle_b64(projectdir::AbstractString, pathdeps, nbname::AbstractString, cells::AbstractString)
    stage = mktempdir()
    for f in ("Project.toml", "Manifest.toml")
        s = joinpath(projectdir, f)
        isfile(s) && cp(s, joinpath(stage, f); force = true)
    end
    # Bundle the project's git repo ONLY when the project IS that repo's root — i.e. the
    # notebook lives in a repo-as-project being shared for collaboration. When the project
    # merely sits nested inside a larger, unrelated git checkout, walking up to that repo would
    # drag in the whole thing (whose source isn't even a dependency), so skip it. When bundled,
    # a path-dep whose committed-clean source lives inside the repo is reused from the cloned
    # `repo/` on expand (no redundant `local/<name>` copy). `gitok` says the bundle was written.
    top = let t = _git_toplevel(projectdir)
        (t !== nothing && t == _safe_realpath(projectdir)) ? t : nothing
    end
    gitok = top !== nothing && _git_bundle!(stage, top)
    targets = Dict{String,String}()                  # dep name → in-bundle relative source path
    for pd in pathdeps
        src = pd isa NamedTuple ? pd.source : pd[2]
        nm = String(pd isa NamedTuple ? pd.name : pd[1])
        isdir(src) || continue
        rel = gitok ? _within(top, realpath(src)) : nothing
        if rel !== nothing && _subtree_clean(top, rel)
            targets[nm] = rel == "." ? "repo" : "repo/" * rel    # reuse the cloned repo source
        else
            _copy_tree!(joinpath(stage, "local", nm), src)       # ship our own copy
            targets[nm] = "local/" * nm
        end
    end
    _rewrite_manifest_paths!(joinpath(stage, "Manifest.toml"), targets)
    # Package-as-project: when the active project carries its OWN package source (`src/`, plus
    # `ext/` for extensions), that source must sit at the expanded project root or `using <Pkg>`
    # fails there — Julia loads the active project's package from `<root>/src`, and otherwise it
    # would ride only inside `repo/`. Independent of the git bundle (best-effort, collaboration
    # only), so a package round-trips even when no `repo/` is shipped. A bare env project (the
    # path-dep / monorepo case — no `src/` of its own) is a no-op here.
    for d in ("src", "ext")
        s = joinpath(projectdir, d)
        isdir(s) && _copy_tree!(joinpath(stage, d), s)
    end
    write(joinpath(stage, nbname), cells)
    tgz = joinpath(mktempdir(), "bundle.tgz")
    # COPYFILE_DISABLE stops macOS BSD tar from emitting `._*` AppleDouble entries that would
    # otherwise litter the tree when extracted on another platform.
    run(addenv(`tar czf $tgz -C $stage .`, "COPYFILE_DISABLE" => "1"))
    return Base64.base64encode(read(tgz))
end

"""
    export_standalone(nb) -> String

Render the notebook as a self-contained single-source `.jl`: the runnable cells followed by
a `Slate.bundle` footer embedding the full environment (Project + Manifest), the local
package source, and (if the project is a git repo) a shallow git bundle. Reinflate it with
[`expand`](@ref).
"""
function export_standalone(nb::LiveNotebook)
    lock(nb.lock) do
        info = ReportEngine.bundle_info(nb.kernel, nb.report)
        isempty(info.projectdir) &&
            error("this notebook has no project environment to bundle (in-process kernel)")
        cells = ReportEngine.serialize_cells(nb.report)
        b64 = _make_bundle_b64(info.projectdir, info.pathdeps, basename(nb.path), cells)
        return cells * "\n" * _bundle_footer(b64) * "\n"
    end
end

# Pull the base64 payload out of a standalone `.jl`'s `Slate.bundle` footer.
function _read_bundle_b64(text::AbstractString)
    lines = split(text, '\n')
    oi = findfirst(l -> startswith(l, _BUNDLE_OPEN), lines)
    oi === nothing && error("no Slate.bundle footer found")
    rest = @view lines[(oi + 1):end]
    ci = findfirst(l -> startswith(l, _BUNDLE_CLOSE), rest)
    body = ci === nothing ? rest : @view rest[1:(ci - 1)]
    return join((startswith(l, "# ") ? SubString(l, 3) : l for l in body))
end

# True if `text` carries a `Slate.bundle` footer (cheap marker scan, no base64 decode).
_has_bundle(text::AbstractString) = occursin(_BUNDLE_OPEN, text)

# Extract a decoded bundle payload (Project/Manifest/src/local/notebook + git bundle) into
# `dir`, then clone+wire the embedded git repo. Returns the cloned repo path or `nothing`.
# Shared by `expand` (user-chosen dir) and `_reconstruct_bundle!` (depot cache).
function _extract_bundle!(b64::AbstractString, dir::AbstractString)
    mkpath(dir)
    tgz = joinpath(mktempdir(), "bundle.tgz")
    write(tgz, Base64.base64decode(b64))
    run(`tar xzf $tgz -C $dir`)
    return _attach_git_repo(dir)                     # clone repo.gitbundle + wire origin
end

# Content-addressed cache dir under the depot for a bundle payload, keyed by a hash of the
# bundle bytes: identical content reuses the same extracted env (instant reopen), a changed
# bundle lands in a fresh dir. Mirrors `notebook_env_dir`'s depot convention.
function _bundle_cache_dir(b64::AbstractString)
    key = string(hash(b64) % 0xffffffffffffffff; base = 16, pad = 16)
    return joinpath(first(Base.DEPOT_PATH), "environments", "kaimonslate-bundles", key)
end

"""
    _reconstruct_bundle!(jl_path) -> (dir, fresh)

Reconstruct a standalone `.jl`'s embedded environment into the content-addressed depot cache
(`_bundle_cache_dir`) and return `(dir, fresh)` — `fresh=false` when the cache was already
populated (reused as-is, instantly). The notebook file is NOT moved; this just materialises a
runnable project the kernel can activate in place. Does not instantiate (the caller does, so
package download/precompile can be streamed/backgrounded). Extraction is staged in a sibling
`.partial` dir and swapped in, so a crash mid-extract can't leave a half-populated cache.
"""
function _reconstruct_bundle!(jl_path::AbstractString)
    b64 = _read_bundle_b64(read(jl_path, String))
    dir = _bundle_cache_dir(b64)
    isfile(joinpath(dir, "Project.toml")) && return (dir = dir, fresh = false)   # cache hit
    mkpath(dirname(dir))
    staging = dir * ".partial"
    rm(staging; recursive = true, force = true)
    _extract_bundle!(b64, staging)
    if isfile(joinpath(dir, "Project.toml"))         # someone raced us → keep theirs
        rm(staging; recursive = true, force = true)
    else
        rm(dir; recursive = true, force = true)
        mv(staging, dir)
    end
    return (dir = dir, fresh = true)
end

"""
    expand(jl_path; target="") -> String

Reinflate a standalone `.jl` (one carrying a `Slate.bundle` footer) into a project directory
at `target` (default: `<jl>.expanded/`): writes Project.toml + Manifest.toml, the local
package source under `local/`, the runnable notebook, and — when present — a `repo.gitbundle`
(+ `git-remote.txt`) for attaching to the original repo. Returns the target dir.
"""
function expand(jl_path::AbstractString; target::AbstractString = "")
    txt = read(jl_path, String)
    b64 = _read_bundle_b64(txt)
    tdir = isempty(target) ? splitext(abspath(jl_path))[1] * ".expanded" : abspath(target)
    repo = _extract_bundle!(b64, tdir)               # tar extract + clone the embedded git bundle
    @info "Expanded standalone notebook" target = tdir
    println("Expanded to: $tdir\n" *
            "  • instantiate the environment:   julia --project=$tdir -e 'using Pkg; Pkg.instantiate()'" *
            (isdir(joinpath(tdir, "local")) ?
             "\n  • local package source is under: $(joinpath(tdir, "local"))" : "") *
            (repo === nothing ? "" :
             "\n  • git repo (matching origin SHAs, ready to branch & PR): $repo") * "\n")
    return tdir
end

# When an expanded tree carries `repo.gitbundle`, clone it into `target/repo` and point
# `origin` at the recorded URL — handing back a real git repo whose tip SHA matches the
# original, ready to branch and PR. Returns the repo path, or `nothing` (no bundle / no git
# / already present / failure — the bundle file is left in place either way).
function _attach_git_repo(tdir::AbstractString)
    gb = joinpath(tdir, "repo.gitbundle")
    (isfile(gb) && Sys.which("git") !== nothing) || return nothing
    repo = joinpath(tdir, "repo")
    ispath(repo) && return nothing
    try
        run(pipeline(`git clone -q $gb $repo`; stdout = devnull, stderr = devnull))
        urlfile = joinpath(tdir, "git-remote.txt")
        if isfile(urlfile)
            url = strip(read(urlfile, String))
            isempty(url) || try
                run(pipeline(`git -C $repo remote set-url origin $url`; stdout = devnull, stderr = devnull))
            catch
                run(pipeline(`git -C $repo remote add origin $url`; stdout = devnull, stderr = devnull))
            end
        end
        return repo
    catch
        return nothing
    end
end
