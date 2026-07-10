# ── Self-contained "single-source .jl" export ────────────────────────────────
# Bundle the notebook together with its FULL resolved environment (Project + Manifest), the
# local / path-dependency source (the parent module code), and — when the project is a git
# repo — a shallow git bundle (so an expanded copy can attach to the original remote and
# open PRs with matching SHAs), all into ONE `.jl`. `expand` reinflates it into a project
# tree that instantiates and runs. The heavy bundle lives ONLY in the exported file; the
# working notebook keeps just the lightweight `Slate.env` delta footer.
#
# Footer layout (terminal, like `Slate.env`): an open marker, the gzip'd archive as base64
# wrapped into commented lines, then a close marker. `parse_report` strips any `Slate.*`
# block, so a standalone `.jl` still opens as an ordinary notebook.
import SHA
# Self-contained content hash (this file is also `include`d standalone in tests, where the
# SlateHistory module isn't present — so don't reach into it).
_bundle_sha(s) = bytes2hex(SHA.sha2_256(codeunits(String(s))))

const _BUNDLE_OPEN = "# ╔═╡ Slate.bundle"
const _BUNDLE_CLOSE = "# ╚═╡ Slate.bundle"

# Wrap a base64 payload into a `Slate.*` terminal footer block: an open marker (with a one-line
# description), the payload split into 100-char commented lines, then a close marker. Shared by
# `_bundle_footer` and `_preview_footer` (encode side) so the two layouts can't drift apart.
function _footer_block(open_marker::AbstractString, close_marker::AbstractString, header::AbstractString, b64::AbstractString)
    io = IOBuffer()
    println(io, open_marker, " ", header)
    for i in 1:100:lastindex(b64)
        println(io, "# ", SubString(b64, i, min(i + 99, lastindex(b64))))
    end
    print(io, close_marker)
    return String(take!(io))
end

# Pull a footer's base64 payload out of `text` (between `open_marker`/`close_marker`), or
# `nothing` if the marker isn't present. Shared by `_read_preview` and `_read_bundle_b64`
# (decode side) so the two extraction passes can't drift apart.
function _read_footer_b64(text::AbstractString, open_marker::AbstractString, close_marker::AbstractString)
    lines = split(text, '\n')
    oi = findfirst(l -> startswith(l, open_marker), lines)
    oi === nothing && return nothing
    rest = @view lines[(oi + 1):end]
    ci = findfirst(l -> startswith(l, close_marker), rest)
    body = ci === nothing ? rest : @view rest[1:(ci - 1)]
    return join((startswith(l, "# ") ? SubString(l, 3) : l for l in body))
end

_bundle_footer(b64::AbstractString) = _footer_block(_BUNDLE_OPEN, _BUNDLE_CLOSE,
    "v1 · self-contained env (Project + Manifest + local source). Expand: julia> using KaimonSlate; KaimonSlate.expand(\"this.jl\")", b64)

# ── Frozen render (preview) ───────────────────────────────────────────────────
# A standalone `.jl` optionally embeds the cells' rendered outputs as of export time, so the
# notebook can be shown instantly while its env reconstructs in the background (then swapped for
# live cells). Stored like the bundle: a marked, base64'd (gzip'd) block, terminal so
# `parse_report` strips it. gzip via CodecZlib (in-process; no `gzip` binary / PATH / Windows
# dependency).
const _PREVIEW_OPEN = "# ╔═╡ Slate.preview"
const _PREVIEW_CLOSE = "# ╚═╡ Slate.preview"

_gzip_b64(data::AbstractString) = Base64.base64encode(transcode(GzipCompressor, Vector{UInt8}(data)))
_gunzip_b64(b64::AbstractString) = String(transcode(GzipDecompressor, Base64.base64decode(b64)))

# `cells` is the JSON-able rendered-cells array (`state_json(nb)["cells"]`).
_preview_footer(cells) = _footer_block(_PREVIEW_OPEN, _PREVIEW_CLOSE,
    "v1 · frozen render shown while the live env reconstructs", _gzip_b64(JSON.json(cells)))

# Pull the embedded frozen-render cells out of a standalone `.jl` (or `nothing` if absent).
function _read_preview(text::AbstractString)
    b64 = _read_footer_b64(text, _PREVIEW_OPEN, _PREVIEW_CLOSE)
    b64 === nothing && return nothing
    return try; JSON.parse(_gunzip_b64(b64)); catch; nothing; end
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

# Tracked files (relative, forward-slashed) of the git worktree at `dir`, or `nothing` when `dir`
# isn't under git. `git ls-files` gives exactly the source we want to ship: it drops `.git`, every
# `.gitignore`d path (build/output dirs), AND untracked stray files (a 60 MB `test.out` sitting in
# the tree) — the working-tree copy of each tracked file, so uncommitted source edits still ride.
function _git_tracked_files(dir::AbstractString)
    Sys.which("git") === nothing && return nothing
    out = try; read(pipeline(`git -C $dir ls-files -z`; stderr = devnull), String); catch; return nothing; end
    files = String[replace(String(f), '\\' => '/') for f in split(out, '\0'; keepempty = false)]
    return isempty(files) ? nothing : files
end

# Vendor a path-dep's SOURCE into `dest` WITHOUT its data/computed bloat. A dev'd package can carry
# huge untracked/ignored artifacts (`bowtie_search/`, `output/`, a stray `test.out`); copying it
# whole (`_copy_tree!`) ballooned standalone bundles to 100 MB+. If the dep is a git worktree, ship
# only its tracked files; otherwise ship just what `using <Pkg>` needs — the `*.toml` metadata plus
# `src`/`ext`/`test` — so a data dir alongside the source can't bloat the bundle.
function _copy_dep_source!(dest::AbstractString, src::AbstractString)
    tracked = _git_tracked_files(src)
    if tracked !== nothing
        for rel in tracked
            s = joinpath(src, rel); isfile(s) || continue
            d = joinpath(dest, rel); mkpath(dirname(d))
            try; cp(s, d; force = true, follow_symlinks = true); catch; end
        end
    else
        for f in readdir(src)                                             # package metadata (Project/Manifest/…)
            endswith(lowercase(f), ".toml") && isfile(joinpath(src, f)) &&
                (mkpath(dest); cp(joinpath(src, f), joinpath(dest, f); force = true))
        end
        for d in ("src", "ext", "test")                                   # the loadable source
            isdir(joinpath(src, d)) && _copy_tree!(joinpath(dest, d), joinpath(src, d))
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

# Add a git bundle of `top` (+ its `origin` URL) so an expanded copy can `git clone` it and
# attach to the original remote with MATCHING SHAs (branch & PR off the real history).
# FULL history, straight from the repo — NOT a `--depth=1` clone: a bundle built from a shallow
# clone can't be cloned back (no shallow boundary → "failed to traverse parents" / "remote did
# not send all necessary objects"). `--branches HEAD` carries the branch refs so the expanded
# clone lands on its real branch (e.g. `main`) instead of a detached HEAD. Returns `true` on
# success. (The size cost of full history is the price of a checkout that actually works offline.)
function _git_bundle!(stage::AbstractString, top::AbstractString)
    try
        run(pipeline(`git -C $top bundle create $(joinpath(stage, "repo.gitbundle")) --branches HEAD`;
                     stdout = devnull, stderr = devnull))
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

# Rewrite the staged `Manifest.toml` so each bundled path-dependency points at its in-bundle
# source (a path RELATIVE to the manifest's dir — `local/<name>` for a copied tree) instead of
# the author's original absolute path — otherwise an expanded copy fails to instantiate with
# "Missing source file" on a machine where that absolute path doesn't exist. `targets` maps dep
# name → relative path. Line-oriented so the generated manifest's formatting is preserved untouched.
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

# ── Archive: a trivial (path, bytes) container, gzip'd ────────────────────────
# We don't need tar — there are no symlinks (staging follows them), no exec bits or other
# metadata that matter, and we own both ends. So pack the staged tree as a flat stream of
# [pathlen:u32][path][len:u64][bytes] entries (network byte order) and gzip it (CodecZlib).
# In-process, cross-platform, no `tar`/`gzip` binary and no macOS AppleDouble `._*` cruft.
function _pack_tree(dir::AbstractString)
    io = IOBuffer()
    for (root, _, files) in walkdir(dir), f in files
        full = joinpath(root, f)
        isfile(full) || continue
        relb = Vector{UInt8}(replace(relpath(full, dir), '\\' => '/'))   # portable forward slashes
        data = read(full)
        write(io, hton(UInt32(length(relb))), relb, hton(UInt64(length(data))), data)
    end
    return transcode(GzipCompressor, take!(io))
end

function _unpack_tree(packed::Vector{UInt8}, dest::AbstractString)
    mkpath(dest)
    # Path-escape guard prefix — MUST use the OS separator: `normpath` emits backslashes on
    # Windows, so the old hardcoded "/" prefix rejected EVERY entry there (a ghost expansion:
    # empty folder, then the printed instantiate manufactured an empty Project.toml).
    sep = Base.Filesystem.path_separator
    base = normpath(dest)
    endswith(base, sep) || (base *= sep)
    io = IOBuffer(transcode(GzipDecompressor, packed))
    written = 0; rejected = 0
    while !eof(io)
        rel = String(read(io, ntoh(read(io, UInt32))))
        data = read(io, ntoh(read(io, UInt64)))
        out = normpath(joinpath(dest, rel))
        startswith(out, base) || (rejected += 1; continue)   # no path-escape
        mkpath(dirname(out))
        write(out, data)
        written += 1
    end
    # A malicious archive may lose a few entries to the guard; losing ALL of them means the
    # guard itself is broken — fail loudly instead of leaving a convincing empty expansion.
    written == 0 && rejected > 0 &&
        error("bundle unpack: the path guard rejected all $(rejected) entries — this is a Slate bug, please report it")
    return dest
end

_pd_source(pd) = pd isa NamedTuple ? pd.source : pd[2]
_pd_name(pd) = String(pd isa NamedTuple ? pd.name : pd[1])

# The git repo to root a bundle on: the worktree that is the notebook's PROJECT — either the active
# env itself (package-as-project / base mode) or a package the notebook develops (a `dev`'d path-dep,
# e.g. the parent package a Slate *forked-env* notebook lives inside). Prefer the repo CONTAINING THE
# NOTEBOOK (the common `MyPkg/notebooks/nb.jl` case — its env is a depot fork OUTSIDE the repo, so the
# env's own toplevel is `nothing`); fall back to the env's repo. The "is the env OR a `dev`'d path-dep"
# guard is what stops a notebook merely sitting inside a big UNRELATED checkout from dragging that whole
# repo into the bundle. Returns the worktree root, or `nothing` (no qualifying repo → flat layout).
function _root_repo(projectdir::AbstractString, pathdeps, nbpath::AbstractString)
    proj = _safe_realpath(projectdir)
    is_project(top) = proj == top ||
        any(pd -> (s = _pd_source(pd); isdir(s) && _safe_realpath(s) == top), pathdeps)
    for cand in (dirname(_safe_realpath(nbpath)), projectdir)
        top = _git_toplevel(cand)
        top !== nothing && is_project(top) && return top
    end
    return nothing
end

# Stage the notebook's env (Project/Manifest at `envrel`) and its path-deps into a bundle tree, and
# rewrite the (live) Manifest so EVERY path-dep points at its in-bundle location relative to the env
# dir — a dep INSIDE the repo resolves from the tree at its repo-relative path; one OUTSIDE is vendored
# (source only, no data/computed bloat) under `<localroot>/local/<name>`. So no author-absolute path
# leaks, including the parent package a forked env `dev`s at the repo root. `envroot` is where the env
# files land (an `overlay/` for the git layout; the stage root for the source snapshot); `localroot` is
# where `local/` lands. Shared by the repo-rooted (git-history) and source-rooted (no-history) layouts.
function _stage_env_and_deps!(envroot::AbstractString, localroot::AbstractString,
                              projectdir::AbstractString, pathdeps, top::AbstractString, envrel::AbstractString)
    for f in ("Project.toml", "Manifest.toml")
        s = joinpath(projectdir, f)
        isfile(s) && (mkpath(joinpath(envroot, envrel)); cp(s, joinpath(envroot, envrel, f); force = true))
    end
    targets = Dict{String,String}()
    for pd in pathdeps
        s = _pd_source(pd); nm = _pd_name(pd)
        isdir(s) || continue
        inside = _within(top, _safe_realpath(s))                              # dep's path within the repo, or `nothing`
        intree = inside === nothing ? "local/$nm" : inside
        inside === nothing && _copy_dep_source!(joinpath(localroot, "local", nm), s)
        targets[nm] = replace(envrel == "." ? intree : relpath(intree, envrel), '\\' => '/')
    end
    man = joinpath(envroot, envrel, "Manifest.toml")
    (isempty(targets) || !isfile(man)) || _rewrite_manifest_paths!(man, targets)
    return
end

# Build the base64 archive from explicit coordinates (kernel-independent, so it's unit testable):
# the active project (env) dir, its path deps `[(name, source)]`, and the notebook's absolute path.
# `history` chooses what the reproducible tree ships when the notebook lives in a git repo (below).
#
# Three layouts:
#  • REPO-ROOTED (history=true) — the notebook lives in a git repo that IS its project. Bundle a
#    matching-SHA git bundle of the repo plus an `overlay/` of the LIVE env files + notebook. On expand
#    the repo becomes the project ROOT (its `src/`, `notebooks/…`), the notebook back in place, wired to
#    `origin` — ready to branch & PR. Ships the FULL commit history (deliberate for a shared `.jl`).
#  • SOURCE-ROOTED (history=false) — same reconstructed structure, but the repo's TRACKED SOURCE is
#    staged directly (git `ls-files`, no `.git`) instead of a git bundle — a runnable snapshot that does
#    NOT publish the commit history (the safe default for a PUBLIC web export). No clone on expand.
#  • FLAT (fallback) — no enclosing repo (or the notebook lives outside it). Stage the env at the root,
#    vendor every path-dep under `local/<name>`, drop the notebook at the root. Structure-less, git-free.
# The env lands at `envrel`: the repo-relative env dir when the env lives INSIDE the repo (package-as-
# project / a committed `notebooks/` env), else a dedicated `_slate_env/` for a depot FORK outside it
# (the common Slate case — a per-notebook env that `dev`s the parent package). Path-deps inside the repo
# resolve from the tree; those `dev`'d from outside are vendored under `local/<name>`.
function _make_bundle_b64(projectdir::AbstractString, pathdeps, nbpath::AbstractString, cells::AbstractString;
                          history::Bool = true)
    stage = mktempdir()
    top = _root_repo(projectdir, pathdeps, nbpath)
    if top !== nothing
        nrel = _within(top, _safe_realpath(nbpath))                           # notebook file relative to repo
        prel = _within(top, _safe_realpath(projectdir))                       # env dir relative to repo, or `nothing`
        envrel = prel === nothing ? "_slate_env" : prel
        if nrel !== nothing && history && _git_bundle!(stage, top)
            ov = joinpath(stage, "overlay")                                   # live files overlay the committed clone
            _stage_env_and_deps!(ov, stage, projectdir, pathdeps, top, envrel)
            mkpath(dirname(joinpath(ov, nrel)))
            write(joinpath(ov, nrel), cells)                                  # live notebook cells
            write(joinpath(stage, "bundle.json"),
                  JSON.json(Dict("mode" => "repo-rooted", "env" => envrel, "notebook" => nrel, "parent" => ".")))
            return Base64.base64encode(_pack_tree(stage))
        elseif nrel !== nothing && !history
            # Source snapshot: the repo's TRACKED files (working-tree copy, no `.git`, no gitignored data)
            # staged directly at the root, then the env + vendored deps + LIVE notebook cells on top.
            _copy_dep_source!(stage, top)
            _stage_env_and_deps!(stage, stage, projectdir, pathdeps, top, envrel)
            mkpath(dirname(joinpath(stage, nrel)))
            write(joinpath(stage, nrel), cells)                               # live cells overwrite the committed notebook
            write(joinpath(stage, "bundle.json"),
                  JSON.json(Dict("mode" => "source-rooted", "env" => envrel, "notebook" => nrel, "parent" => ".")))
            return Base64.base64encode(_pack_tree(stage))
        end
        # fall through to the flat layout (notebook outside the repo, or the git bundle failed)
    end
    # ── Flat fallback: self-contained, structure-less, git-free ────────────────────────────────────
    for f in ("Project.toml", "Manifest.toml")
        s = joinpath(projectdir, f)
        isfile(s) && cp(s, joinpath(stage, f); force = true)
    end
    targets = Dict{String,String}()                  # dep name → in-bundle relative source path
    for pd in pathdeps
        src = _pd_source(pd); nm = _pd_name(pd)
        isdir(src) || continue
        _copy_dep_source!(joinpath(stage, "local", nm), src)  # source only (no data/computed bloat)
        targets[nm] = "local/" * nm
    end
    _rewrite_manifest_paths!(joinpath(stage, "Manifest.toml"), targets)
    # Package-as-project: an active project carrying its OWN package source (`src/`, `ext/`) needs
    # that source at the expanded root or `using <Pkg>` fails there.
    for d in ("src", "ext")
        s = joinpath(projectdir, d)
        isdir(s) && _copy_tree!(joinpath(stage, d), s)
    end
    write(joinpath(stage, basename(nbpath)), cells)
    return Base64.base64encode(_pack_tree(stage))
end

"""
    export_standalone(nb; include_preview=true, history=true) -> String

Render the notebook as a self-contained single-source `.jl`: the runnable cells, a
`Slate.bundle` footer embedding the full environment (Project + Manifest), the local package
source, and (when the project is a git repo) either its full git history or a source-only
snapshot — and, when `include_preview`, a `Slate.preview` footer holding the cells' rendered
outputs so the notebook displays instantly while its env reconstructs. `history=true` (the
default for a deliberately-shared `.jl`) ships a matching-SHA git bundle so the expanded copy
can branch & PR; `history=false` ships the tracked SOURCE only — same runnable structure, no
commit history published — the safe default for a PUBLIC web export. Reinflate / run with
[`expand`](@ref) or the open box.
"""
# For a self-contained `.jl`, inline any EXTERNAL bibliography file into its `:bibliography` cell
# (replace the `.bib` path lines with the file's contents) so the reproducible notebook keeps its
# citations working without depending on a file outside the bundle. Embedded-BibTeX cells and
# notebooks without an external bib are returned unchanged.
function _serialize_cells_inlining_bibs(report, nbdir::AbstractString)
    isext(c) = :bibliography in c.flags && !occursin(r"@\w+\s*\{", c.source)
    any(isext, report.cells) || return ReportEngine.serialize_cells(report)
    cells2 = map(report.cells) do c
        isext(c) || return c
        io = IOBuffer()
        for ln in split(c.source, '\n')
            p = strip(ln); isempty(p) && continue
            src = isabspath(p) ? String(p) : joinpath(nbdir, p)
            isfile(src) ? println(io, rstrip(read(src, String))) : println(io, p)   # keep path if missing
        end
        nc = ReportEngine.Cell(c.id, c.kind, rstrip(String(take!(io))))
        union!(nc.flags, c.flags)
        nc
    end
    tmp = ReportEngine.Report(report.id, report.title)
    append!(tmp.cells, cells2)
    return ReportEngine.serialize_cells(tmp)
end

function export_standalone(nb::LiveNotebook; include_preview::Bool = true, history::Bool = true)
    lock(nb.lock) do
        info = ReportEngine.bundle_info(nb.kernel, nb.report)
        isempty(info.projectdir) &&
            error("this notebook has no project environment to bundle (in-process kernel)")
        cells = _serialize_cells_inlining_bibs(nb.report, dirname(abspath(nb.path)))
        b64 = _make_bundle_b64(info.projectdir, info.pathdeps, abspath(nb.path), cells; history = history)
        out = cells * "\n" * _bundle_footer(b64)
        include_preview && try
            out *= "\n" * _preview_footer(state_json(nb)["cells"])   # frozen render for instant display
        catch
        end
        return out * "\n"
    end
end

# Pull the base64 payload out of a standalone `.jl`'s `Slate.bundle` footer.
function _read_bundle_b64(text::AbstractString)
    b64 = _read_footer_b64(text, _BUNDLE_OPEN, _BUNDLE_CLOSE)
    b64 === nothing && error("no Slate.bundle footer found")
    return b64
end

# True if `text` carries a `Slate.bundle` footer (cheap marker scan, no base64 decode).
_has_bundle(text::AbstractString) = occursin(_BUNDLE_OPEN, text)

# The single notebook `.jl` at the root of a FLAT expanded bundle (Project/Manifest/local are the
# only other root entries). "" if none found. (Repo-rooted bundles record the path in `bundle.json`.)
function _expanded_notebook(tdir::AbstractString)
    for f in readdir(tdir)
        (endswith(f, ".jl") && isfile(joinpath(tdir, f))) && return joinpath(tdir, f)
    end
    return ""
end

# The bundle layout marker unpacked at `dir` (repo-rooted bundles ship `bundle.json`), else `nothing`.
function _read_bundle_meta(dir::AbstractString)
    f = joinpath(dir, "bundle.json")
    isfile(f) || return nothing
    return try; JSON.parse(read(f, String)); catch; nothing; end
end

_joinrel(dir, rel) = (rel == "." || isempty(rel)) ? String(dir) : normpath(joinpath(dir, rel))

# Persist the expanded project's coordinates so the open/reconstruct paths (and cache hits) know the
# ENV dir to activate, the PARENT package, and where the notebook landed — without re-deriving.
_write_coords!(dir; mode, env, parent, notebook) =
    write(joinpath(dir, ".slatebundle.json"),
          JSON.json(Dict("mode" => mode, "env" => env, "parent" => parent, "notebook" => notebook)))

# Read `.slatebundle.json` → absolute coordinates `(root, envdir, parent, notebook)`.
function _read_coords(dir::AbstractString)
    f = joinpath(dir, ".slatebundle.json")
    m = isfile(f) ? (try; JSON.parse(read(f, String)); catch; Dict{String,Any}(); end) : Dict{String,Any}()
    env = String(get(m, "env", ".")); parent = String(get(m, "parent", "")); nb = String(get(m, "notebook", ""))
    return (root = String(dir), envdir = _joinrel(dir, env),
            parent = isempty(parent) ? "" : _joinrel(dir, parent),
            notebook = isempty(nb) ? _expanded_notebook(dir) : _joinrel(dir, nb))
end

# Move every top-level entry of `src` into `dst` (preserves `.git`; cross-filesystem safe).
function _move_contents!(src::AbstractString, dst::AbstractString)
    mkpath(dst)
    for e in readdir(src)
        s = joinpath(src, e); d = joinpath(dst, e)
        rm(d; recursive = true, force = true)
        try; mv(s, d); catch; cp(s, d; force = true, follow_symlinks = true); rm(s; recursive = true, force = true); end
    end
    return dst
end

# After the embedded repo is cloned into place, make it a CLEAN working checkout: point `origin`
# at the real remote (or DROP the dangling bundle-path remote when there is none), and locally
# ignore Slate's `.slatebundle.json` coords file so `git status` stays clean. The bundle is
# full-history + `--branches HEAD`, so the checkout is already on its real branch with a working
# `git log` — no shallow graft to repair.
function _tidy_git_checkout!(dir::AbstractString, remote_url::AbstractString)
    if isempty(strip(remote_url))
        try; run(pipeline(`git -C $dir remote remove origin`; stdout = devnull, stderr = devnull)); catch; end
    else
        try
            run(pipeline(`git -C $dir remote set-url origin $remote_url`; stdout = devnull, stderr = devnull))
        catch
            try; run(pipeline(`git -C $dir remote add origin $remote_url`; stdout = devnull, stderr = devnull)); catch; end
        end
    end
    # Locally ignore Slate's reconstruction artifacts so `git status` stays clean (ready to branch &
    # PR): the coords file, the forked-env dir, and any vendored external deps that landed in-tree.
    excl = joinpath(dir, ".git", "info", "exclude")
    try; isdir(dirname(excl)) &&
        open(io -> foreach(l -> println(io, l), (".slatebundle.json", "/_slate_env/", "/local/")), excl, "a"); catch; end
    return dir
end

# Materialise a bundle payload into `dir` and return `(root, envdir, parent, notebook)` (absolute;
# `parent=""` when detached). Shared by `expand` and `_reconstruct_bundle!`.
#  • REPO-ROOTED — clone the embedded repo as the ROOT (tidy `origin`), then overlay the LIVE env
#    files + notebook so the checkout matches the author's tree with the current cells in place.
#  • SOURCE-ROOTED — unpack in place: the tracked source is already staged at its paths (env + vendored
#    deps + live notebook alongside), so just drop the `bundle.json` marker and record coords. No git.
#  • FLAT — unpack in place (self-contained, structure-less; no git).
function _extract_bundle!(b64::AbstractString, dir::AbstractString)
    try
        _unpack_tree(Base64.base64decode(b64), dir)
    catch e
        e isa InterruptException && rethrow()
        # A raw EOFError / bad-gzip / bad-base64 here means the payload is truncated or was written
        # by an INCOMPATIBLE Slate version (e.g. a pre-`(path,bytes)`-archive bundle) — surface an
        # actionable message rather than "EOFError: read end of file" in the hydrate banner.
        error("This notebook's embedded bundle is corrupt or from an incompatible Slate version — " *
              "re-export the standalone `.jl` from a current Slate. (bundle decode: $(sprint(showerror, e)))")
    end
    meta = _read_bundle_meta(dir)
    if meta !== nothing && get(meta, "mode", "") == "repo-rooted"
        Sys.which("git") === nothing && error("expand: this is a repo-rooted bundle but `git` isn't available")
        clone = joinpath(mktempdir(), "r")
        run(pipeline(`git clone -q $(joinpath(dir, "repo.gitbundle")) $clone`; stdout = devnull, stderr = devnull))
        urlf = joinpath(dir, "git-remote.txt")
        remote_url = isfile(urlf) ? strip(read(urlf, String)) : ""
        ov = joinpath(dir, "overlay")
        for f in ("repo.gitbundle", "git-remote.txt", "bundle.json")   # drop the scaffolding
            rm(joinpath(dir, f); force = true)
        end
        ovkeep = isdir(ov) ? mktempdir() : ""
        isempty(ovkeep) || _move_contents!(ov, ovkeep)                 # stash overlay before the repo lands
        rm(ov; recursive = true, force = true)
        _move_contents!(clone, dir)                                    # the repo IS the root (incl .git)
        isempty(ovkeep) || _copy_tree_overlay!(dir, ovkeep)           # live env + notebook overwrite committed
        _tidy_git_checkout!(dir, remote_url)                          # clean origin + ignore the coords file
        env = String(get(meta, "env", ".")); nb = String(get(meta, "notebook", ""))
        _write_coords!(dir; mode = "repo-rooted", env = env, parent = ".", notebook = nb)
        return _read_coords(dir)
    elseif meta !== nothing && get(meta, "mode", "") == "source-rooted"
        # The reconstructed tree is already complete (source staged in place, live cells written) — just
        # drop the marker and record coords (env dir + repo root as parent). No clone, no git needed.
        rm(joinpath(dir, "bundle.json"); force = true)
        env = String(get(meta, "env", ".")); nb = String(get(meta, "notebook", ""))
        _write_coords!(dir; mode = "source-rooted", env = env, parent = ".", notebook = nb)
        return _read_coords(dir)
    end
    # FLAT — self-contained vendored tree, no git.
    nb = _expanded_notebook(dir)
    _write_coords!(dir; mode = "flat", env = ".", parent = "",
                   notebook = isempty(nb) ? "" : replace(relpath(nb, dir), '\\' => '/'))
    return _read_coords(dir)
end

# Deep-merge overlay files into `dir` (file-by-file, overwriting individual files — NOT replacing whole
# dirs, so the repo's other files in an overlaid dir survive). Unlike `_copy_tree!`, keeps `.git`-named
# paths (none expected in an overlay, but don't special-case).
function _copy_tree_overlay!(dest::AbstractString, src::AbstractString)
    for (root, _, files) in walkdir(src)
        rel = relpath(root, src)
        mkpath(joinpath(dest, rel))
        for f in files
            try; cp(joinpath(root, f), joinpath(dest, rel, f); force = true, follow_symlinks = true); catch; end
        end
    end
    return dest
end

# Content-addressed cache dir under the depot for a bundle payload, keyed by a SHA-256 of the
# bundle bytes: identical content reuses the same extracted env (instant reopen), a changed
# bundle lands in a fresh dir. Uses SHA (like history.jl) — NOT `hash`, which is non-cryptographic,
# unstable across Julia versions/sessions (cache would never hit → rebuilds + orphan dirs), and
# collision-prone (a collision would serve the WRONG environment).
function _bundle_cache_dir(b64::AbstractString)
    key = _bundle_sha(b64)
    return joinpath(first(Base.DEPOT_PATH), "environments", "kaimonslate-bundles", key)
end

"""
    _reconstruct_bundle!(jl_path) -> (root, envdir, parent, notebook, fresh, install)

Reconstruct a standalone `.jl`'s embedded environment and return its coordinates — the project ROOT,
the ENV dir the kernel should activate, the PARENT package dir (`""` if none), the reconstructed
NOTEBOOK path, `fresh` (`false` when it was already populated, reused instantly), and `install`
(`true` when it landed in a durable user-chosen dir rather than the cache — the caller re-points the
notebook there so edits persist).

Destination: the content-addressed depot cache (`_bundle_cache_dir`) by default, OR — when a
launcher (`run.jl`) sets `ENV["SLATE_INSTALL_DIR"]` — a durable, user-owned directory THERE (a real
project: a git checkout for a full-history bundle). Does not instantiate (the caller does, so
download/precompile can be streamed). Cache extraction is staged in a sibling `.partial` dir and
swapped in, so a crash mid-extract can't leave a half-populated cache.
"""
function _reconstruct_bundle!(jl_path::AbstractString)
    b64 = _read_bundle_b64(read(jl_path, String))
    # A durable install dir (run.jl's "where to set this up?" prompt) → reconstruct THERE, not the cache.
    install = strip(get(ENV, "SLATE_INSTALL_DIR", ""))
    if !isempty(install)
        dir = abspath(expanduser(String(install)))
        isfile(joinpath(dir, ".slatebundle.json")) && return (; _read_coords(dir)..., fresh = false, install = true)  # reuse
        (isdir(dir) && !isempty(readdir(dir))) &&
            error("SLATE_INSTALL_DIR is a non-empty directory that isn't a Slate install: $dir\n" *
                  "Choose an empty/new path, or remove it, and re-run.")
        _extract_bundle!(b64, dir)
        return (; _read_coords(dir)..., fresh = true, install = true)
    end
    dir = _bundle_cache_dir(b64)
    isfile(joinpath(dir, ".slatebundle.json")) && return (; _read_coords(dir)..., fresh = false, install = false)   # cache hit
    mkpath(dirname(dir))
    staging = dir * ".partial"
    rm(staging; recursive = true, force = true)
    _extract_bundle!(b64, staging)
    if isfile(joinpath(dir, ".slatebundle.json"))    # someone raced us → keep theirs
        rm(staging; recursive = true, force = true)
        return (; _read_coords(dir)..., fresh = false, install = false)
    end
    rm(dir; recursive = true, force = true)
    mv(staging, dir)
    return (; _read_coords(dir)..., fresh = true, install = false)
end

"""
    expand(jl_path; target="") -> String

Reinflate a standalone `.jl` (one carrying a `Slate.bundle` footer) into a project directory at
`target` (default: `<jl>.expanded/`). A REPO-ROOTED bundle expands to a real git checkout of the
original project (its `src/`, `notebooks/`, …) with the LIVE notebook cells in place, wired to
`origin` (branch & PR with matching SHAs). A FLAT bundle writes Project + Manifest, any `local/`
package source, and the notebook at the root. Returns the target dir.
"""
function expand(jl_path::AbstractString; target::AbstractString = "", force::Bool = false)
    txt = read(jl_path, String)
    b64 = _read_bundle_b64(txt)
    tdir = isempty(target) ? splitext(abspath(jl_path))[1] * ".expanded" : abspath(target)
    # Don't silently overwrite into a non-empty dir (re-expanding over user edits would mix two
    # states + leave unrelated files behind). Require force=true to extract into it.
    (isdir(tdir) && !isempty(readdir(tdir)) && !force) &&
        error("expand: target exists and is not empty: $tdir  (pass force=true to overwrite)")
    force && isdir(tdir) && rm(tdir; recursive = true, force = true)
    co = _extract_bundle!(b64, tdir)
    isrepo = isdir(joinpath(tdir, ".git"))
    @info "Expanded standalone notebook" target = tdir
    # Double quotes throughout: cmd.exe treats single quotes as literal characters, so the
    # -e '…' form hands Windows users a broken command. Double quotes parse on cmd,
    # PowerShell, AND POSIX shells (nothing in the literal needs escaping in any of them).
    println("Expanded to: $tdir\n" *
            "  • notebook:   $(co.notebook)\n" *
            "  • instantiate: julia --project=\"$(co.envdir)\" -e \"using Pkg; Pkg.instantiate()\"" *
            (isdir(joinpath(tdir, "local")) ? "\n  • local package source: $(joinpath(tdir, "local"))" : "") *
            (isrepo ? "\n  • git checkout wired to origin (matching SHAs) — ready to branch & PR" : "") * "\n")
    return tdir
end

