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
    base = normpath(dest)
    io = IOBuffer(transcode(GzipDecompressor, packed))
    while !eof(io)
        rel = String(read(io, ntoh(read(io, UInt32))))
        data = read(io, ntoh(read(io, UInt64)))
        out = normpath(joinpath(dest, rel))
        startswith(out, base * (endswith(base, "/") ? "" : "/")) || continue   # no path-escape
        mkpath(dirname(out))
        write(out, data)
    end
    return dest
end

_pd_source(pd) = pd isa NamedTuple ? pd.source : pd[2]
_pd_name(pd) = String(pd isa NamedTuple ? pd.name : pd[1])

# Build the base64 archive from explicit coordinates (kernel-independent, so it's unit testable):
# the active project (env) dir, its path deps `[(name, source)]`, and the notebook's absolute path.
#
# Two layouts:
#  • REPO-ROOTED — the env, the notebook, and every path-dep source all live inside ONE git repo.
#    Bundle the repo (a matching-SHA git bundle) plus an `overlay/` of the LIVE env files + notebook
#    at their repo-relative paths. On expand the repo becomes the project ROOT with the notebook back
#    in place (e.g. `WindowPrimes.jl/` with `src/` + `notebooks/presentation.jl`), so a `{path=".."}`
#    / relative Manifest source resolves naturally — no `local/` vendoring, no path rewriting, and
#    the result is a real git checkout wired to `origin` (branch & PR with matching SHAs).
#  • FLAT (fallback) — no enclosing repo, or a path-dep lives outside it. Stage the env at the root,
#    vendor path-dep sources under `local/<name>` (rewriting the Manifest), and drop the notebook at
#    the root. Self-contained but structure-less.
function _make_bundle_b64(projectdir::AbstractString, pathdeps, nbpath::AbstractString, cells::AbstractString)
    stage = mktempdir()
    top = _git_toplevel(projectdir)
    if top !== nothing
        prel = _within(top, _safe_realpath(projectdir))                       # env dir relative to repo
        nrel = _within(top, _safe_realpath(nbpath))                           # notebook file relative to repo
        allin = all(pd -> (s = _pd_source(pd); isdir(s) && _within(top, realpath(s)) !== nothing), pathdeps)
        # Only when this repo IS the notebook's project — the repo root is the env dir (package-as-
        # project) or the source of a path-dep the notebook develops. Otherwise a notebook merely
        # sitting inside a big unrelated checkout would drag the whole thing into the bundle.
        repo_is_project = _safe_realpath(projectdir) == top ||
            any(pd -> (s = _pd_source(pd); isdir(s) && _safe_realpath(s) == top), pathdeps)
        if repo_is_project && prel !== nothing && nrel !== nothing && allin && _git_bundle!(stage, top)
            write(joinpath(stage, "bundle.json"),
                  JSON.json(Dict("mode" => "repo-rooted", "env" => prel, "notebook" => nrel, "parent" => ".")))
            ov = joinpath(stage, "overlay")
            for f in ("Project.toml", "Manifest.toml")                        # live env files overlay the committed ones
                s = joinpath(projectdir, f)
                isfile(s) && (mkpath(joinpath(ov, prel)); cp(s, joinpath(ov, prel, f); force = true))
            end
            mkpath(dirname(joinpath(ov, nrel)))
            write(joinpath(ov, nrel), cells)                                  # live notebook cells
            return Base64.base64encode(_pack_tree(stage))
        end
        # fall through to the flat layout (repo present but not self-contained, or bundle failed)
    end
    # ── Flat fallback ────────────────────────────────────────────────────────────────────────────
    for f in ("Project.toml", "Manifest.toml")
        s = joinpath(projectdir, f)
        isfile(s) && cp(s, joinpath(stage, f); force = true)
    end
    # Bundle the git repo only when the project IS that repo's root (repo-as-project shared for
    # collaboration); a project merely nested in a larger checkout would otherwise drag in the whole
    # thing. A committed-clean path-dep inside that repo is reused from the cloned `repo/`.
    rtop = (top !== nothing && top == _safe_realpath(projectdir)) ? top : nothing
    gitok = rtop !== nothing && _git_bundle!(stage, rtop)
    targets = Dict{String,String}()                  # dep name → in-bundle relative source path
    for pd in pathdeps
        src = _pd_source(pd); nm = _pd_name(pd)
        isdir(src) || continue
        rel = gitok ? _within(rtop, realpath(src)) : nothing
        if rel !== nothing && _subtree_clean(rtop, rel)
            targets[nm] = rel == "." ? "repo" : "repo/" * rel    # reuse the cloned repo source
        else
            _copy_tree!(joinpath(stage, "local", nm), src)       # ship our own copy
            targets[nm] = "local/" * nm
        end
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
    export_standalone(nb; include_preview=true) -> String

Render the notebook as a self-contained single-source `.jl`: the runnable cells, a
`Slate.bundle` footer embedding the full environment (Project + Manifest), the local package
source, and (if the project is a git repo) a shallow git bundle — and, when `include_preview`,
a `Slate.preview` footer holding the cells' rendered outputs so the notebook displays instantly
while its env reconstructs. Reinflate / run with [`expand`](@ref) or the open box.
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

function export_standalone(nb::LiveNotebook; include_preview::Bool = true)
    lock(nb.lock) do
        info = ReportEngine.bundle_info(nb.kernel, nb.report)
        isempty(info.projectdir) &&
            error("this notebook has no project environment to bundle (in-process kernel)")
        cells = _serialize_cells_inlining_bibs(nb.report, dirname(abspath(nb.path)))
        b64 = _make_bundle_b64(info.projectdir, info.pathdeps, abspath(nb.path), cells)
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

# Materialise a bundle payload into `dir` and return `(root, envdir, parent, notebook)` (absolute;
# `parent=""` when detached). Shared by `expand` and `_reconstruct_bundle!`.
#  • REPO-ROOTED — clone the embedded repo as the ROOT (wire `origin`), then overlay the LIVE env
#    files + notebook so the checkout matches the author's tree with the current cells in place.
#  • FLAT — unpack in place; clone the optional git repo into `repo/` (legacy self-contained layout).
function _extract_bundle!(b64::AbstractString, dir::AbstractString)
    _unpack_tree(Base64.base64decode(b64), dir)
    meta = _read_bundle_meta(dir)
    if meta !== nothing && get(meta, "mode", "") == "repo-rooted"
        Sys.which("git") === nothing && error("expand: this is a repo-rooted bundle but `git` isn't available")
        clone = joinpath(mktempdir(), "r")
        run(pipeline(`git clone -q $(joinpath(dir, "repo.gitbundle")) $clone`; stdout = devnull, stderr = devnull))
        urlf = joinpath(dir, "git-remote.txt")
        if isfile(urlf)
            url = strip(read(urlf, String))
            isempty(url) || try
                run(pipeline(`git -C $clone remote set-url origin $url`; stdout = devnull, stderr = devnull))
            catch
                try; run(pipeline(`git -C $clone remote add origin $url`; stdout = devnull, stderr = devnull)); catch; end
            end
        end
        ov = joinpath(dir, "overlay")
        for f in ("repo.gitbundle", "git-remote.txt", "bundle.json")   # drop the scaffolding
            rm(joinpath(dir, f); force = true)
        end
        ovkeep = isdir(ov) ? mktempdir() : ""
        isempty(ovkeep) || _move_contents!(ov, ovkeep)                 # stash overlay before the repo lands
        rm(ov; recursive = true, force = true)
        _move_contents!(clone, dir)                                    # the repo IS the root (incl .git)
        isempty(ovkeep) || _copy_tree_overlay!(dir, ovkeep)           # live env + notebook overwrite committed
        env = String(get(meta, "env", ".")); nb = String(get(meta, "notebook", ""))
        _write_coords!(dir; mode = "repo-rooted", env = env, parent = ".", notebook = nb)
        return _read_coords(dir)
    end
    # FLAT
    repo = _attach_git_repo(dir)                     # clone repo.gitbundle + wire origin → dir/repo
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
    _reconstruct_bundle!(jl_path) -> (root, envdir, parent, notebook, fresh)

Reconstruct a standalone `.jl`'s embedded environment into the content-addressed depot cache
(`_bundle_cache_dir`) and return its coordinates — the project ROOT, the ENV dir the kernel should
activate, the PARENT package dir (`""` if none), the reconstructed NOTEBOOK path, and `fresh`
(`false` when the cache was already populated, reused instantly). Does not instantiate (the caller
does, so download/precompile can be streamed). Extraction is staged in a sibling `.partial` dir and
swapped in, so a crash mid-extract can't leave a half-populated cache.
"""
function _reconstruct_bundle!(jl_path::AbstractString)
    b64 = _read_bundle_b64(read(jl_path, String))
    dir = _bundle_cache_dir(b64)
    isfile(joinpath(dir, ".slatebundle.json")) && return (; _read_coords(dir)..., fresh = false)   # cache hit
    mkpath(dirname(dir))
    staging = dir * ".partial"
    rm(staging; recursive = true, force = true)
    _extract_bundle!(b64, staging)
    if isfile(joinpath(dir, ".slatebundle.json"))    # someone raced us → keep theirs
        rm(staging; recursive = true, force = true)
        return (; _read_coords(dir)..., fresh = false)
    end
    rm(dir; recursive = true, force = true)
    mv(staging, dir)
    return (; _read_coords(dir)..., fresh = true)
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
    println("Expanded to: $tdir\n" *
            "  • notebook:   $(co.notebook)\n" *
            "  • instantiate: julia --project=$(co.envdir) -e 'using Pkg; Pkg.instantiate()'" *
            (isdir(joinpath(tdir, "local")) ? "\n  • local package source: $(joinpath(tdir, "local"))" : "") *
            (isrepo ? "\n  • git checkout wired to origin (matching SHAs) — ready to branch & PR" : "") * "\n")
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
