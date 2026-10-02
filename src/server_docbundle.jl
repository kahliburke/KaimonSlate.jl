# Part of the NotebookServer submodule — included by server.jl. Names here resolve in NotebookServer.

# ── Doc bundles: a rendered notebook for a documentation site ─────────────────────────────────────
# A doc bundle is a directory a docs build reads instead of running the notebook:
#
#     slate-bundle.json     manifest: notebook, source key, theme, libraries, assets, cells[]
#     cells/<id>.json       one cell's rendered payload (html, charts, replay marks), loaded on demand
#     data/, assets/, ext-assets/, frontend/   everything the payloads reference, as plain files
#     runtime/slate-embed.js                   the `<slate-cell>` element that draws a payload
#
# Markdown cells also carry a Documenter-flavoured markdown rendering, so a docs page can use them as
# its own prose (cross-references, search, table of contents) and embed only what needs Slate to draw.
# The bundle is written by the same per-cell emitter as `export_html`, so a cell looks the same in an
# exported page, a published site and a docs page.

import SHA

const DOC_BUNDLE_SCHEMA = 1
const DOC_BUNDLE_MANIFEST = "slate-bundle.json"

"""
    doc_bundle_inputs(notebook_path) -> Vector{Pair{String,String}}

What a notebook's rendered output depends on, as `file => SHA-256` pairs sorted by file, each file
named relative to the notebook's directory:

- the notebook itself, under `"(notebook)"` so that its name does not enter the key;
- its environment: the project it runs in (the nearest `Project.toml` above it), any workspace roots
  over that, and the manifest that resolves them;
- every package that environment takes by `path` in `[sources]`: its project file and the files in
  its directories, apart from hidden ones, `docs/` and `test/` (and, in a git repository, files git
  ignores);
- files the notebook names by a literal path in `include("…")` or `@asset "…"`.

Line endings are normalised throughout, so a checkout with `core.autocrlf` agrees with the machine
that rendered the bundle.
"""
function doc_bundle_inputs(path::AbstractString)
    nb = abspath(String(path))
    base = dirname(nb)
    files = Dict{String,String}()
    add!(f) = isfile(f) && (files[relpath(f, base)] = _docbundle_sha(f))
    files["(notebook)"] = _docbundle_sha(nb)       # its content, whatever the file is called
    proj = Base.current_project(base)
    if proj !== nothing
        add!(proj)
        roots = ReportEngine.workspace_chain(proj)
        foreach(add!, roots)
        man = ReportEngine._manifest_for(proj)
        isempty(man) || add!(man)
        envdir = dirname(proj)
        for pf in (proj, roots...)
            isfile(pf) || continue
            for (_, s) in get(ReportEngine._toml(pf), "sources", Dict{String,Any}())
                (s isa AbstractDict && haskey(s, "path")) || continue
                pkg = normpath(joinpath(dirname(pf), String(s["path"])))
                isdir(pkg) && foreach(add!, _shipped_files(pkg, envdir))
            end
        end
    end
    src = read(nb, String)
    for m in eachmatch(r"(?:\binclude\(\s*|@asset\s*\(?\s*)\"([^\"$]+)\"", src)
        add!(normpath(joinpath(base, m.captures[1])))
    end
    return sort!(collect(files); by = first)
end

"""
    doc_bundle_key(notebook_path) -> String

The key a doc bundle is stored under: one SHA-256 over [`doc_bundle_inputs`](@ref), so a bundle is
current while the notebook, its environment, the packages that environment takes by path and the
files the notebook reads are all as they were when it was rendered. A docs build compares this
against the key recorded in the bundle.
"""
doc_bundle_key(path::AbstractString) = doc_bundle_key(doc_bundle_inputs(path))
doc_bundle_key(inputs::AbstractVector{<:Pair}) =
    bytes2hex(SHA.sha256(join((string(f, '\0', h, '\n') for (f, h) in inputs))))

_docbundle_sha(f) = bytes2hex(SHA.sha256(replace(read(f, String), "\r\n" => "\n")))

# The files that make up what a package does: its project file and the files in its directories,
# apart from hidden ones, `docs/`, `test/` and the notebook environment `skip` when that sits inside
# it. Within those, what git knows of (tracked, or new and not ignored), or everything outside git. A package whose tree holds the notebooks (a docs directory taking its own package
# by `path = "../.."`) would otherwise re-key every bundle on an edit to any page or notebook.
function _shipped_files(pkg::AbstractString, skip::AbstractString)
    out = String[]
    listed = _git_files(pkg)
    rels = listed === nothing ?
        [relpath(joinpath(d, f), pkg) for (d, _, fs) in walkdir(pkg) for f in fs
         if !any(startswith("."), splitpath(relpath(joinpath(d, f), pkg)))] : listed
    sk = relpath(abspath(skip), abspath(pkg))
    skipparts = startswith(sk, "..") ? nothing : splitpath(sk)
    for r in rels
        parts = splitpath(r)
        # Top-level files (a README, a licence, CI settings) do not change what the package does,
        # apart from its project file.
        length(parts) == 1 && !(parts[1] in ReportEngine._PROJECT_NAMES) && continue
        (startswith(parts[1], ".") || parts[1] == "docs" || parts[1] == "test") && continue
        (skipparts !== nothing && length(parts) > length(skipparts) &&
         parts[1:length(skipparts)] == skipparts) && continue
        push!(out, joinpath(pkg, r))
    end
    return out
end

function _git_files(dir::AbstractString)
    Sys.which("git") === nothing && return nothing
    txt = try
        read(pipeline(`git -C $dir ls-files -z --cached --others --exclude-standard .`; stderr = devnull), String)
    catch
        return nothing
    end
    return [String(f) for f in split(txt, '\0'; keepempty = false) if isfile(joinpath(dir, f))]
end

# A file-name-safe form of an id. Cell ids are author-chosen and may hold characters a URL or a file
# system treats specially; the manifest maps each id to its file, so this only has to be safe and stable.
_docbundle_slug(s::AbstractString) = (t = replace(String(s), r"[^A-Za-z0-9_-]" => "_"); isempty(t) ? "_" : t)

_cell_kind_name(c::Cell) = c.kind == MARKDOWN ? "markdown" : c.kind == WEB ? "web" :
                           c.kind == TOOL ? "tool" : "code"

# Math in Documenter's spelling: ``x`` inline and a ```math block for display. A prose `$` is written
# `\$`, since Julia's markdown parser reads a bare one as interpolation.
function _documenter_math(s::AbstractString)
    b = IOBuffer()
    for (kind, t) in ReportRender._md_segments(s)
        if kind === :math
            tex, display = ReportRender._math_parts(t)
            print(b, display ? string("\n\n```math\n", strip(tex), "\n```\n\n") : string("``", tex, "``"))
        elseif kind === :dollar
            print(b, "\\\$")
        else
            print(b, t)
        end
    end
    return String(take!(b))
end

# ── Citations on a docs page ──────────────────────────────────────────────────────────────────────
# A citation whose `.bib` entry says where the cited work lives becomes a link labelled the way the
# notebook's bibstyle labels it, so the cell stays plain markdown: `docpage` is a path under the docs
# source (the cited work's own page in the same site), written as a `slate-docpage:` link that
# DocumenterSlate makes relative to the page holding the cell, and `url` is the fallback. A citation
# with neither still needs Slate's renderer. A bibliography cell becomes the list of what is cited.

const _DOC_LINK = "slate-docpage:"

# The raw text of the notebook's bibliographies: embedded BibTeX, and the `.bib` files the cells name.
function _bib_texts(report, nbdir::AbstractString)
    out = String[]
    for c in report.cells
        :bibliography in c.flags || continue
        if occursin(r"@\w+\s*\{", c.source)
            push!(out, c.source)
        else
            for ln in split(c.source, '\n')
                p = strip(ln); isempty(p) && continue
                src = isabspath(p) ? String(p) : joinpath(nbdir, p)
                isfile(src) && push!(out, read(src, String))
            end
        end
    end
    return out
end

# key => (docpage, url, rest) from the bibliographies, `rest` holding the fields a reference list shows.
function _bib_targets(report, nbdir::AbstractString)
    out = Dict{String,NamedTuple{(:docpage, :url, :journal, :eprint),NTuple{4,String}}}()
    field(body, name) = (m = match(Regex("(?i)\\b" * name * "\\s*=\\s*[{\"]([^{}\"]*)[}\"]"), body); m === nothing ? "" : strip(m.captures[1]))
    for text in _bib_texts(report, nbdir)
        for m in eachmatch(r"@\w+\s*\{\s*([^,\s]+)\s*,(.*?)(?=\n\s*@\w+\s*\{|\z)"s, text)
            body = m.captures[2]
            out[m.captures[1]] = (docpage = field(body, "docpage"), url = field(body, "url"),
                                  journal = field(body, "journal"), eprint = field(body, "eprint"))
        end
    end
    return out
end

_doc_cite_href(t) = !isempty(t.docpage) ? _DOC_LINK * t.docpage : t.url

# Each cited key's place in first-citation order across the notebook's prose, spliced prose included.
function _doc_cite_order(ctx)
    cc = ctx.citectx
    order = Dict{String,Int}()
    rec = (key, _sup, _form) -> (haskey(order, String(key)) || (order[String(key)] = length(order) + 1); "")
    for c in ctx.nb.report.cells
        (c.kind == MARKDOWN && !(:bibliography in c.flags)) || continue
        _rewrite_citations(_doc_spliced(c)[1], cc.citekeys; emit = rec)
    end
    return order
end

_doc_cite_labels(ctx) = _cite_labels(get(ctx.nb.report.meta, "bibstyle", "ieee"), ctx.citectx.bi, _doc_cite_order(ctx))

# Citations in `s` as linked labels, where every key of a group has somewhere to link to; the rest are
# left for `_doc_markdown` to notice. Groups keep the style's labels and brackets: `(A, 2025; B, 2024)`,
# `[3; 5]` or `[Sun 2026; Elder 2025]`.
function _doc_citations(ctx, s::AbstractString)
    cc = ctx.citectx
    cc === nothing && return s
    targets = _bib_targets(ctx.nb.report, dirname(abspath(ctx.nb.path)))
    (; labels, open, close) = _doc_cite_labels(ctx)
    linked(k) = haskey(targets, k) && !isempty(_doc_cite_href(targets[k]))
    # Each citation is first written as a marker, so a bracketed group's members can be gathered.
    emit = (key, sup, form) -> string(form == "p" ? "\x02" : "\x01", key, "\x03", strip(sup), form == "p" ? "\x02" : "\x01")
    t = _rewrite_citations(String(s), cc.citekeys; emit)
    cite_link(key, sup) = string("[", get(labels, key, key), "](", _doc_cite_href(targets[key]), ")", isempty(sup) ? "" : ", " * sup)
    t = replace(t, r"(\x01[^\x01]*\x01)+" => function (run)
        parts = [split(m.captures[1], '\x03') for m in eachmatch(r"\x01([^\x01]*)\x01", run)]
        all(p -> linked(p[1]), parts) || return "[" * join(("@" * p[1] * (isempty(p[2]) ? "" : ", " * p[2]) for p in parts), "; ") * "]"
        return open * join((cite_link(p[1], p[2]) for p in parts), "; ") * close
    end)
    return replace(t, r"\x02([^\x02]*)\x02" => function (m)
        key, _ = split(m[2:end-1], '\x03')
        linked(key) ? cite_link(key, "") : "@" * key
    end)
end

# The bibliography as a docs page shows it: the entries the notebook cites, spliced prose included,
# each with its authors and year, its title linked to its page, and its arXiv record. A numeric style
# numbers them in citation order; `author-year-brackets` keys each by its label.
function _doc_references(ctx)
    cc = ctx.citectx
    cc === nothing && return ""
    targets = _bib_targets(ctx.nb.report, dirname(abspath(ctx.nb.path)))
    order = _doc_cite_order(ctx)
    style = get(ctx.nb.report.meta, "bibstyle", "ieee")
    labels = _cite_labels(style, cc.bi, order).labels
    keyed = _is_numeric_style(style) || _is_bracket_style(style)
    entries = [e for e in cc.bi if haskey(order, e.key)]
    isempty(entries) && return ""
    _is_numeric_style(style) ? sort!(entries; by = e -> order[e.key]) :
        sort!(entries; by = e -> (lowercase(e.surname), e.year, labels[e.key]))
    authors(a) = (names = strip.(split(_delatex(a), r"\s+and\s+")); length(names) > 3 ? join(names[1:3], ", ") * " et al." : join(names, ", "))
    io = IOBuffer()
    println(io, "## References\n")
    for e in entries
        t = get(targets, e.key, (docpage = "", url = "", journal = "", eprint = ""))
        href = _doc_cite_href(t)
        title = _delatex(e.title)
        print(io, "- ", keyed ? string("[", labels[e.key], "] ") : "", authors(e.author), " (", e.year, "). ",
              isempty(href) ? title : "[" * title * "](" * href * ")", ".")
        isempty(t.journal) || print(io, " *", _delatex(t.journal), "*.")
        isempty(t.eprint) || isempty(t.url) || isempty(t.docpage) || print(io, " [arXiv:", t.eprint, "](", t.url, ")")
        println(io)
    end
    return String(take!(io))
end

"""
    _doc_spliced(c) -> (markdown, native)

A markdown cell's source with its `{{ }}` values written in as text: a scalar's text, a markdown
value's markdown, a fence's code block when nothing claimed it. `native` is false when a value is
something plain markdown cannot carry (a rich or failed interpolation, an extension-rendered fence).
"""
function _doc_spliced(c::Cell)
    tmpl, exprs = ReportEngine._md_template(c.source)
    native = true
    s = tmpl
    for (i, e) in enumerate(exprs)
        o = i <= length(c.interp) ? c.interp[i] : nothing
        fence = ReportEngine._fence_call(e)
        md = o === nothing ? nothing : _doc_markdown_value(o)
        text = if fence !== nothing
            (o === nothing || ReportRender._is_empty_output(o)) ?
                ReportEngine._md_fence_block(fence.lang, fence.body) : (native = false; "")
        elseif o === nothing
            ""
        elseif md !== nothing
            md
        elseif o.exception !== nothing || !isempty(o.display) || !isempty(o.echarts) || !isempty(o.tables)
            native = false; ""
        else
            ReportRender._interp_scalar(o.value_repr)
        end
        s = replace(s, ReportEngine._interp_token(i) => text; count = 1)
    end
    return (s, native)
end

# A value whose only rich form is markdown is prose, spliced in as written.
function _doc_markdown_value(o)
    (o.exception === nothing && length(o.display) == 1 && only(o.display).mime == "text/markdown") || return nothing
    return String(copy(only(o.display).data))
end

"""
    _doc_markdown(ctx, c) -> (markdown, native)

A markdown cell as Documenter-flavoured markdown, with its `{{ }}` values written in as text. `native`
is false when the cell has something plain markdown cannot carry — a rich or failed interpolation, an
extension-rendered fence, a local image, a citation or figure reference, a `@replay`-driven value — in
which case a docs page embeds the rendered cell instead.
"""
function _doc_markdown(ctx::_ExportCtx, c::Cell)
    s, native = _doc_spliced(c)
    s = _doc_citations(ctx, s)
    # Things only Slate's renderer resolves. A local image would need copying into the docs source
    # tree and a path rewrite per writer; embedding the rendered cell carries it already.
    (occursin(r"!\[[^\]]*\]\((?!https?://)", s) || occursin(r"<img\s", s) ||
     occursin(r"\[@[\w:.-]", s) || occursin(r"\{\s*(width|height|align)\s*=", s)) && (native = false)
    haskey(ctx.figidx.numbers, c.id) && (native = false)
    # Prose whose values follow a control needs the embedded cell to follow it — but only when a sweep
    # actually shipped; with none, the values are fixed and plain markdown carries them.
    pm = get(ctx.chain_marks, string("prose:", c.id), nothing)
    (pm isa AbstractDict && haskey(ctx.replay_table, String(get(pm, "id", "")))) && (native = false)
    return (_documenter_math(s), native)
end

"""
    doc_bundle_name(nb) -> String

The name a docs page uses for this notebook's bundle (```` ```@slate <name> ````): the notebook's file
name without `.jl`.
"""
doc_bundle_name(nb::LiveNotebook) = splitext(basename(nb.path))[1]

"""
    doc_bundle_default_dir(nb) -> String

Where a notebook's bundle goes when nobody says: `docs/slate/<name>` under the nearest enclosing
directory whose `docs/` has a `make.jl` (a notebook inside `docs/` finds the one it is in). With none,
`docs/slate/<name>` under the notebook's project, or beside the notebook when it has no project (its
environment then lives in a directory the author never sees).
"""
function doc_bundle_default_dir(nb::LiveNotebook)
    name = doc_bundle_name(nb)
    d = dirname(abspath(nb.path))
    while true
        basename(d) == "docs" && isfile(joinpath(d, "make.jl")) && return joinpath(d, "slate", name)
        isfile(joinpath(d, "docs", "make.jl")) && return joinpath(d, "docs", "slate", name)
        p = dirname(d)
        p == d && break
        d = p
    end
    proj = Base.current_project(dirname(abspath(nb.path)))
    base = proj === nothing ? dirname(abspath(nb.path)) : dirname(proj)
    return joinpath(base, "docs", "slate", name)
end

# Does a code cell show anything below its (hidden) source? A cell that only defines things has no
# payload, and a docs page has nothing to embed for it.
function _doc_cell_has_output(c::Cell, ctrls::AbstractString)
    isempty(ctrls) || return true
    o = c.output
    o === nothing && return false
    return !isempty(o.stdout) || !isempty(o.stderr) || !isempty(o.value_repr) || !isempty(o.display) ||
           o.exception !== nothing || !isempty(o.echarts) || !isempty(o.tables)
end

# The libraries a bundle's cells need, as CDN URLs pinned by vendor.json. KaTeX always: math appears
# in ordinary output (a `text/latex` display) as well as prose.
function _doc_bundle_libs(nb::LiveNotebook)
    libs = Dict{String,Any}[]
    add(pkg, sub, kind) = (u = _vendor_url(pkg, sub); u === nothing || push!(libs, Dict{String,Any}("name" => pkg, kind => u)))
    add("katex", "katex.min.css", "css")
    add("katex", "katex.min.js", "js")
    add("katex", "contrib/auto-render.min.js", "js")
    pl = _page_libs(nb)
    pl.echarts && add("echarts", "echarts.min.js", "js")
    pl.dagre && add("dagre", "dagre.min.js", "js")
    return libs
end

# Placeholder a bundle's front-end scripts use for their own location; the runtime substitutes the
# bundle's URL before running them, since a docs page's URL says nothing about where the bundle is.
const _DOC_BUNDLE_BASE_TOKEN = "__SLATE_BUNDLE_BASE__"

"""
    export_doc_bundle(nb, dir; light = "daylight", dark = "midnight", render_info = Dict()) -> Dict

Write `nb`'s doc bundle into `dir`, replacing any bundle already there, and return the manifest.
`light`/`dark` are the Slate palettes the embedded cells use under the docs site's light and dark
themes. `render_info` is merged into the manifest's `rendered` record (how and where it was run).

The bundle is assembled in a sibling temporary directory and moved into place at the end, so a render
that fails leaves the previous bundle intact.
"""
function export_doc_bundle(nb::LiveNotebook, dir::AbstractString; light::AbstractString = "daylight",
                           dark::AbstractString = "midnight", render_info::AbstractDict = Dict{String,Any}())
    dir = abspath(dir)
    mkpath(dirname(dir))
    stage = mktempdir(dirname(dir); prefix = "." * basename(dir) * ".tmp-", cleanup = false)
    try
        manifest = _write_doc_bundle!(stage, nb; light, dark, render_info)
        isdir(dir) && rm(dir; recursive = true, force = true)
        mv(stage, dir)
        return manifest
    catch
        rm(stage; recursive = true, force = true)
        rethrow()
    end
end

function _write_doc_bundle!(out::AbstractString, nb::LiveNotebook; light, dark, render_info)
    nbslug = _docbundle_slug(splitext(basename(nb.path))[1])
    sink = Dict{String,Any}()
    cells = Dict{String,Any}[]
    payloads = Pair{String,String}[]
    used = Set{String}()
    local ctx, fm, entries
    lock(nb.lock) do
        # Sibling assets (a docs site serves files), no source in the payloads (the docs page shows code
        # itself, highlighted by the site), ids prefixed so two notebooks on one page cannot collide.
        ctx = _export_ctx(nb; inline = false, show_source = false, outputs = "all", palette = dark,
                          idprefix = nbslug * "-")
        fm = report_frontmatter(nb.report)
        entries = _export_asset_entries(ctx; asset_sink = sink)
        for c in nb.report.cells
            :docindex in c.flags && continue
            if :bibliography in c.flags
                # The reference list, as plain markdown (or nothing, when nothing is cited).
                refs = _doc_references(ctx)
                isempty(refs) || push!(cells, Dict{String,Any}("id" => c.id, "kind" => "markdown",
                    "tags" => sort!([string(f) for f in c.flags]), "markdown" => refs, "native" => true, "output" => false))
                continue
            end
            entry = Dict{String,Any}("id" => c.id, "kind" => _cell_kind_name(c),
                                     "tags" => sort!([string(f) for f in c.flags]))
            n0, t0 = length(ctx.charts), length(ctx.tablemarks)
            io = IOBuffer()
            _export_cell_html!(io, ctx, c)
            html = String(take!(io))
            if c.kind == MARKDOWN
                md, native = _doc_markdown(ctx, c)
                entry["markdown"] = md
                entry["native"] = native
                has = true                       # the rendered form is the fallback for a non-native cell
            else
                entry["source"] = c.source
                entry["hidecode"] = (:hidecode in c.flags) || _is_web_cell(c) || !isempty(c.binds)
                has = _doc_cell_has_output(c, _export_controls_html(c, ctx.bind_by_name, ctx.surfaced_names))
            end
            entry["output"] = has
            if has
                slug = _docbundle_slug(c.id)
                while slug in used; slug *= "_"; end
                push!(used, slug)
                file = "cells/" * slug * ".json"
                entry["file"] = file
                charts = ctx.charts[(n0 + 1):end]
                pm = get(ctx.chain_marks, string("prose:", c.id), nothing)
                # Chart options are already JSON (the page writer embeds them verbatim); splice them in
                # rather than parsing each back into a Dict just to print it again.
                push!(payloads, file => string(
                    "{\"id\":", JSON.json(c.id), ",\"html\":", JSON.json(html),
                    ",\"charts\":[", join((string("[", JSON.json(id), ",", spec, "]") for (id, spec) in charts), ","), "]",
                    ",\"tablemarks\":", JSON.json(ctx.tablemarks[(t0 + 1):end]),
                    ",\"prosemarks\":", JSON.json(pm isa AbstractDict ? [pm] : Any[]), "}"))
            end
            push!(cells, entry)
        end
    end

    # Files. Everything a payload references, at the relative path it references it by.
    for (rel, src) in _referenced_page_assets(nb)
        dst = joinpath(out, rel); mkpath(dirname(dst))
        src isa AbstractVector{UInt8} ? write(dst, src) : cp(src, dst; force = true)
    end
    _write_sibling_assets!(out, sink)
    for (file, json) in payloads
        dst = joinpath(out, file); mkpath(dirname(dst)); write(dst, json)
    end
    frontend = Dict{String,Any}[]
    for (i, e) in enumerate(_frontend_scripts(nb))
        file = string("frontend/", i, "-", _docbundle_slug(e.id), ".js")
        dst = joinpath(out, file); mkpath(dirname(dst))
        write(dst, replace(e.js, "/ext-assets/" => _DOC_BUNDLE_BASE_TOKEN * "ext-assets/"))
        push!(frontend, Dict{String,Any}("id" => e.id, "file" => file, "esm" => e.esm, "kind" => e.kind))
    end
    rt = joinpath(out, "runtime", "slate-embed.js"); mkpath(dirname(rt))
    write(rt, _embed_runtime_js())

    rendered = Dict{String,Any}("at" => string(Dates.now(Dates.UTC), "Z"), "julia" => string(VERSION),
                                "kernel" => _doc_kernel_kind(nb),
                                "errors" => [c.id for c in nb.report.cells
                                             if c.output !== nothing && c.output.exception !== nothing],
                                "frozen" => ctx.replay_frozen)
    merge!(rendered, Dict{String,Any}(String(k) => v for (k, v) in render_info))
    inputs = isfile(nb.path) ? doc_bundle_inputs(nb.path) : Pair{String,String}[]
    manifest = Dict{String,Any}(
        "schema" => DOC_BUNDLE_SCHEMA,
        "generator" => string("KaimonSlate ", try; string(pkgversion(@__MODULE__)); catch; "?"; end),
        "notebook" => Dict{String,Any}("id" => nb.id, "file" => basename(nb.path), "title" => fm.title,
                                       "subtitle" => fm.subtitle, "byline" => fm.byline, "abstract" => fm.abstract),
        "key" => isempty(inputs) ? "" : doc_bundle_key(inputs),
        # What the key covers, so a docs build can say which of them changed.
        "inputs" => Dict{String,Any}(f => h for (f, h) in inputs),
        "rendered" => rendered,
        "theme" => Dict{String,Any}(
            "light" => Dict{String,Any}("palette" => String(light), "vars" => _export_theme_vars(_resolve_export_theme(light))),
            "dark"  => Dict{String,Any}("palette" => String(dark),  "vars" => _export_theme_vars(_resolve_export_theme(dark)))),
        "libs" => _doc_bundle_libs(nb),
        "assets" => entries === nothing ? Dict{String,Any}() : Dict{String,Any}(p => e for (p, e) in entries),
        "replays" => ctx.replay_table,
        "frontend" => frontend,
        "runtime" => "runtime/slate-embed.js",
        "cells" => cells,
    )
    open(io -> JSON.print(io, manifest, 1), joinpath(out, DOC_BUNDLE_MANIFEST), "w")
    return manifest
end

# How the notebook was run, for the manifest: a docs reader cannot see it, but a maintainer looking at
# why a bundle differs from what CI produced can.
_doc_kernel_kind(nb::LiveNotebook) = nb.kernel isa ReportEngine.InProcessKernel ? "inprocess" : "worker"

# ── The embed runtime ──────────────────────────────────────────────────────────────────────────────
# One script: the static export's runtime (assets, replay, charts, tables, media, component mount),
# the export component CSS, and the `<slate-cell>` element (assets/js/slate-embed.js). Everything is
# inside one closure, so the export's top-level helpers do not become globals on a docs page.

_export_embed_css(code::AbstractString = "normal") = string(
    ":host{display:block;margin:1em 0;color:var(--text);line-height:1.6;}",
    ":host([hidden]){display:none;}",
    "*{box-sizing:border-box;}",
    _export_component_css(code),
    # A cell on a docs page is one output, not a notebook card: no outer margin, and a frame that lets
    # the site's own background show through, so a palette never paints a block of a different colour
    # onto a docs theme it was not chosen for. The border is mixed from the text colour for the same
    # reason: it reads as a hairline on any background.
    # Surfaces (table headers, inputs, control tracks) as tints of the text colour for the same reason.
    # Set on the wrapper, not the host: chart tooltips read the host's palette and stay opaque.
    ".slate-embed{--bg2:color-mix(in srgb,var(--text) 4%,transparent);",
    "--bg3:color-mix(in srgb,var(--text) 8%,transparent);}",
    ".slate-embed>section.exp-code{margin:0;background:transparent;",
    "border-color:color-mix(in srgb,var(--text) 16%,transparent);}",
    ".slate-embed .exp-ctls{border-bottom:1px solid color-mix(in srgb,var(--text) 10%,transparent);}",
    ".slate-embed .exp-ctls:last-child{border-bottom:none;}",
    ".slate-embed>section.exp-md{margin:0;}",
    ".slate-embed-msg{padding:8px 12px;border:1px dashed var(--border);border-radius:6px;color:var(--dim);",
    "font-size:.85rem;}")

function _embed_runtime_js()
    return string(
        "/* Slate embed runtime (doc bundle schema ", DOC_BUNDLE_SCHEMA, "), generated by KaimonSlate. */\n",
        "(function(){\nif(window.__slateEmbedRuntime)return;window.__slateEmbedRuntime=",
        DOC_BUNDLE_SCHEMA, ";\n",
        _export_asset_js(), "\n",
        _EXPORT_ECHARTS_THEME_JS, "\n",
        "var _slateMaps={};\n",
        _EXPORT_CHART_RUNTIME_JS, "\n",
        _EXPORT_TABLE_JS, "\n",
        _EXPORT_TABLE_REPLAY_JS, "\n",
        _EXPORT_PROSE_REPLAY_JS, "\n",
        _EXPORT_MEDIA_JS, "\n",
        _EXPORT_COMPONENT_MOUNT_JS, "\n",
        "var _SLATE_EMBED_CSS=", JSON.json(_export_embed_css()), ";\n",
        "var _SLATE_BASE_TOKEN=", JSON.json(_DOC_BUNDLE_BASE_TOKEN), ";\n",
        read(joinpath(_JS_DIR, "slate-embed.js"), String),
        "\n})();\n")
end

# ── Rendering a notebook headlessly ────────────────────────────────────────────────────────────────

"""
    render_doc_bundle_inprocess(notebook, dir; light = "daylight", dark = "midnight", timeout = 3600) -> Dict

Run `notebook` in this process and write its doc bundle to `dir`, returning the manifest. No hub, no
browser, no worker — `KaimonSlate.render_doc_bundle(…; backend = :inprocess)`.

The notebook runs in THIS process, in its own environment (the in-process kernel swaps the load path
around each cell), so its packages must be installed. Nothing is written to Slate's own state: no
preview snapshot, no history, no docs index. Cells that error are reported and still bundled, as the
error output they produced — a docs build decides whether that is acceptable.
"""
function render_doc_bundle_inprocess(path::AbstractString, dir::AbstractString; light::AbstractString = "daylight",
                           dark::AbstractString = "midnight", timeout::Real = 3600)
    path = abspath(path)
    isfile(path) || throw(ArgumentError("no notebook at $path"))
    base = splitext(basename(path))[1]
    rid = replace(base, r"[^A-Za-z0-9]" => "_")
    r = parse_report(read(path, String); id = rid, title = base)
    build_dependencies!(r)
    kernel = _select_kernel(path, r)
    nb = LiveNotebook(rid, path, r, kernel, 0, String[], String[], ReentrantLock(), Channel{String}[],
                      ReentrantLock(), "", false, Dict{String,String}())
    t0 = time()
    run = Threads.@spawn _drain!(nb)
    while !istaskdone(run)
        time() - t0 > timeout && error("render_doc_bundle: $base did not finish within $(timeout)s")
        sleep(0.1)
    end
    fetch(run)                                    # surface a runner failure here, not as a half bundle
    _refresh_extensions!(nb)                      # extension front-ends the outputs need (normally the run loop's job)
    man = export_doc_bundle(nb, dir; light, dark,
                            render_info = Dict{String,Any}("seconds" => round(time() - t0; digits = 1)))
    errs = man["rendered"]["errors"]
    isempty(errs) || @warn "render_doc_bundle: cells raised errors; their error output is in the bundle" notebook = base cells = errs
    return man
end
