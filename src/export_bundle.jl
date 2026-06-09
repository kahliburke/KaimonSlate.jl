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

# Add a shallow git bundle of the project's repo + its `origin` URL, so an expanded copy can
# `git clone` it and attach to the original remote with MATCHING SHAs (branch & PR off the
# real history). A self-contained shallow bundle can't be made with `bundle create --depth`
# (that needs the parent as a prerequisite); the reliable recipe is a depth-1 working clone,
# then bundle from THAT. Best-effort: skipped when git is absent or the project isn't a repo.
function _maybe_git_bundle!(stage::AbstractString, projectdir::AbstractString)
    Sys.which("git") === nothing && return
    top = try
        strip(read(pipeline(`git -C $projectdir rev-parse --show-toplevel`; stderr = devnull), String))
    catch
        return
    end
    (isempty(top) || !isdir(top)) && return
    try
        sc = joinpath(mktempdir(), "s")
        run(pipeline(`git clone -q --depth=1 file://$top $sc`; stdout = devnull, stderr = devnull))
        run(pipeline(`git -C $sc bundle create $(joinpath(stage, "repo.gitbundle")) HEAD`; stdout = devnull, stderr = devnull))
        url = try; strip(read(pipeline(`git -C $top remote get-url origin`; stderr = devnull), String)); catch; ""; end
        isempty(url) || write(joinpath(stage, "git-remote.txt"), url)
    catch
    end
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
    for pd in pathdeps
        src = pd isa NamedTuple ? pd.source : pd[2]
        nm = pd isa NamedTuple ? pd.name : pd[1]
        isdir(src) && _copy_tree!(joinpath(stage, "local", nm), src)
    end
    write(joinpath(stage, nbname), cells)
    _maybe_git_bundle!(stage, projectdir)
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
    mkpath(tdir)
    tgz = joinpath(mktempdir(), "bundle.tgz")
    write(tgz, Base64.base64decode(b64))
    run(`tar xzf $tgz -C $tdir`)
    @info "Expanded standalone notebook" target = tdir
    repo = _attach_git_repo(tdir)                    # clone the embedded bundle + wire origin
    println("""
    Expanded to: $tdir
      • instantiate the environment:   julia --project=$tdir -e 'using Pkg; Pkg.instantiate()'
      • local package source is under: $(joinpath(tdir, "local"))""" *
            (repo === nothing ? "" :
             "\n      • git repo (matching origin SHAs, ready to branch & PR): $repo") * "\n")
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
