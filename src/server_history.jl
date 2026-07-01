# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Durable history (the time machine) ───────────────────────────────────────
# Capture the *current* notebook state into the append-only store. Dedup-by-hash
# makes a no-op capture free, so this is safe to call liberally (every op, every
# sync, the periodic draft net). Per-cell digests let the UI attribute + recover
# individual cells. Never throws into the caller.
_cells_of(report) = [(c.id, c.kind == MARKDOWN ? "md" : "code", c.source) for c in report.cells]
function _history!(nb::LiveNotebook; source::AbstractString = "browser", kind::AbstractString = "checkpoint")
    try
        SlateHistory.record!(nb.path, serialize_report(nb.report);
                             source_label = source, kind = kind, cells = _cells_of(nb.report))
    catch e
        @warn "KaimonSlate: history capture failed" exception = (e, catch_backtrace())
    end
    return nothing
end

# Recent server-written content hashes per notebook (report id → ring). The async
# file-watcher must recognize our OWN writes — including *intermediate* ones from a
# rapid sequence of cell ops — and not revert newer in-memory state to a stale disk
# read. Matching only the latest state (as `sync_from_file!` did) races: the watcher
# can read write N while the report is already at N+1 and roll it back.
const _SERVER_WRITES = Dict{String,Vector{UInt64}}()
const _SWRITES_LOCK = ReentrantLock()
function _note_server_write!(report_id::AbstractString, h::UInt64)
    lock(_SWRITES_LOCK) do
        v = get!(_SERVER_WRITES, String(report_id), UInt64[])
        push!(v, h); length(v) > 64 && popfirst!(v)
    end
end
_is_server_write(report_id, h::UInt64) =
    lock(_SWRITES_LOCK) do; h in get(_SERVER_WRITES, String(report_id), UInt64[]); end

# Persist the notebook to its `.jl` AND record a durable checkpoint. The single
# write+capture chokepoint for in-app mutations (replaces bare `write(...)`).
function _persist!(nb::LiveNotebook; source::AbstractString = "browser")
    s = serialize_report(nb.report)
    _note_server_write!(nb.report.id, hash(s))   # register BEFORE writing: a watcher tick fired by
    write(nb.path, s)                             # this write must recognize it as OURS, not external
    nb.version += 1                               # every in-app commit advances the version (CAS basis)
    _history!(nb; source = source)
    return nb
end

# The notebook's OWN packages (the delta beyond the parent project) as sorted
# `{name, version, uuid}` — the set difference active − parent − parent-package. Shared by
# the package viewer's "notebook" group and the `.jl` reproducibility footer.
function _notebook_adds(nb::LiveNotebook)
    info = try
        ReportEngine.env_info(nb.kernel, nb.report)
    catch
        return (adds = Dict{String,Any}[], parent = Dict{String,Any}[], parentpath = "", detached = true)
    end
    pdeps = info.parent === nothing ? Dict{String,Any}[] : info.parent.deps
    pnames = Set(string(get(d, "name", "")) for d in pdeps)
    info.parent === nothing || push!(pnames, info.parent.name)
    adds = sort([d for d in info.notebook.deps if !(string(get(d, "name", "")) in pnames)];
                by = d -> string(get(d, "name", "")))
    return (adds = adds, parent = pdeps,
            parentpath = info.parent === nothing ? "" : info.parent.path,
            detached = info.parent === nothing)
end

# Sync the `.jl` reproducibility footer (`report.meta["env"]`) to the notebook's current
# package delta and persist if it changed. Called after package operations.
function _refresh_env_meta!(nb::LiveNotebook)
    env = Dict{String,Any}[Dict{String,Any}("name" => string(get(d, "name", "")),
                                             "version" => string(get(d, "version", "")),
                                             "uuid" => string(get(d, "uuid", "")))
                           for d in _notebook_adds(nb).adds]
    cur = get(nb.report.meta, "env", Dict{String,Any}[])
    if isempty(env)
        haskey(nb.report.meta, "env") || return nb
        delete!(nb.report.meta, "env")
    else
        env == cur && return nb
        nb.report.meta["env"] = env
    end
    return _persist!(nb; source = "packages")
end

# Restore the notebook to a recorded state (by content hash). Append-only and
# non-destructive: the current state goes onto the in-memory undo stack and the
# restore is itself recorded as a new "restore" checkpoint — you can always come
# straight back. Returns true on success.
function restore_history!(nb::LiveNotebook, hash::AbstractString)
    src = SlateHistory.content(nb.path, hash)
    src === nothing && return false
    lock(nb.lock) do
        _snapshot!(nb)
        _restore!(nb, src)            # applies, runs, persists as source="restore"
        nb.version += 1
    end
    _broadcast(nb, string(nb.version))
    return true
end

# Pull in external edits (VS Code, the agent, …). Re-reads the file; if it differs
# (canonically) from our state, reconciles → runs stale → bumps version. Returns
# true if changed. The server's own writes match canonically, so they don't loop.
function sync_from_file!(nb::LiveNotebook)
    isfile(nb.path) || return false
    disk = read(nb.path, String)
    norm = try
        serialize_report(parse_report(disk; id = nb.report.id))
    catch
        return false                     # mid-save / unparseable — skip this tick
    end
    norm == serialize_report(nb.report) && return false
    # An echo of one of OUR recent writes (incl. an intermediate one from a rapid
    # cell-op sequence) — never roll the live report back to it.
    _is_server_write(nb.report.id, hash(norm)) && return false
    update_source!(nb.report, disk)
    _eval!(nb)
    nb.version += 1
    # External write (agent mid-turn → "agent", else a human in another editor).
    _history!(nb; source = nb.agent_busy ? "agent" : "external")
    return true
end

_echarts_specs(c::Cell) = c.output === nothing ? Any[] : c.output.echarts
_table_specs(c::Cell) = c.output === nothing ? Any[] : c.output.tables

# Read a field from an animation payload whether it crossed as a NamedTuple (in-process) or a Dict
# (after the gate wire). Bytes are coerced to a real `Vector{UInt8}`.
_aget(a, k::Symbol) = a isa AbstractDict ? get(a, String(k), get(a, k, nothing)) :
                      (hasproperty(a, k) ? getproperty(a, k) : nothing)
_abytes(x) = x === nothing ? UInt8[] : (x isa Vector{UInt8} ? x : Vector{UInt8}(x))

# Animation specs for a cell: register the (gzipped) frame stack + LUT in the durable blob store and
# return manifests carrying `/blob/<hash>` URLs — so the heavy buffers never ride in the cell JSON.
function _animation_specs(c::Cell, nbid::AbstractString = "")
    (c.output === nothing || isempty(c.output.animations) || isempty(nbid)) && return Any[]
    specs = Any[]
    for a in c.output.animations
        manifest = _aget(a, :manifest); manifest === nothing && continue
        frames = _abytes(_aget(a, :frames)); lut = _abytes(_aget(a, :lut))
        (isempty(frames) || isempty(lut)) && continue
        fh = string(hash(frames); base = 16); lh = string(hash(lut); base = 16)
        _blob_put_durable!(string(nbid, "/", fh), "application/octet-stream",
                           transcode(GzipCompressor, frames); encoding = "gzip")
        _blob_put_durable!(string(nbid, "/", lh), "application/octet-stream", lut)
        m = Dict{String,Any}(string(k) => v for (k, v) in pairs(manifest))
        m["framesUrl"] = string("/api/", nbid, "/blob/", fh)
        m["lutUrl"]    = string("/api/", nbid, "/blob/", lh)
        push!(specs, m)
    end
    return specs
end
# Specs from a markdown cell's `{{ }}` interpolations, in document order (matches
# the `.ichart`/`.itable` placeholder indices the renderer emits).
_md_interp_echarts(c::Cell) = (e = Any[]; for o in c.interp; append!(e, o.echarts); end; e)
_md_interp_tables(c::Cell) = (t = Any[]; for o in c.interp; append!(t, o.tables); end; t)

# A bound control resolved for the frontend: enough to render the widget *and*
# POST value changes to `/api/bind/<id>` (the *defining* cell's id) keyed by
# variable name, regardless of which cell surfaces it.
_control_spec(cell::Cell, spec::BindSpec) =
    Dict{String,Any}("id" => cell.id, "name" => String(spec.name),
                     "widget" => spec.widget, "params" => spec.params, "value" => spec.value)

# `hosts` is the list of cell ids whose control strip surfaces this bind (usually one,
# possibly several, possibly the bind's OWN cell). `hosted` stays a simple bool for the
# common path; `hostedby` lets the frontend say *where* (jump link) and tell self-host apart.
_bind_json(spec::BindSpec, hosts::Vector{String}) =
    Dict{String,Any}("name" => String(spec.name), "widget" => spec.widget,
                     "params" => spec.params, "value" => spec.value,
                     "hosted" => !isempty(hosts), "hostedby" => hosts)

# ── Content-addressed blob store for output images ───────────────────────────────
# Plot rasters (CairoMakie `image/png`) are otherwise inlined into every cell's output HTML as
# base64 data-URIs — for a plot-heavy notebook that bloats the /state payload to megabytes, re-sent
# in full on every reload. Instead we pull each inlined image out into a content-addressed store and
# reference it by `/api/<id>/blob/<hash>` with an immutable cache header: the /state JSON shrinks
# ~10×, and a browser RELOAD serves the images from disk cache (never re-requests them). The hash is
# content-derived, so a changed plot gets a fresh URL and caching stays correct.
const _BLOBS = Dict{String,Tuple{String,Vector{UInt8}}}()   # "id/hash" → (mime, bytes)
const _BLOB_LOCK = ReentrantLock()
# Match a whole `<img …src="data:image/…;base64,…"…>` so we can swap the src for a blob URL AND
# inject width/height (reserving the aspect-ratio box → no layout shift when the image loads).
const _IMG_RE = r"<img([^>]*?)src=\"data:(image/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=]+)\"([^>]*)>"
function _blob_put!(key::AbstractString, mime::AbstractString, bytes::Vector{UInt8})
    lock(_BLOB_LOCK) do
        length(_BLOBS) > 800 && empty!(_BLOBS)   # crude cap; content-addressed keys re-populate on next render
        _BLOBS[String(key)] = (String(mime), bytes)
    end
end
blob_get(key::AbstractString) = lock(_BLOB_LOCK) do; get(_BLOBS, String(key), nothing); end
# Intrinsic (w, h) of a PNG from its IHDR header, else nothing — lets the <img> reserve its box.
function _png_dims(b::Vector{UInt8})
    (length(b) >= 24 && b[1] == 0x89 && b[2] == 0x50) || return nothing
    w = (Int(b[17]) << 24) | (Int(b[18]) << 16) | (Int(b[19]) << 8) | Int(b[20])
    h = (Int(b[21]) << 24) | (Int(b[22]) << 16) | (Int(b[23]) << 8) | Int(b[24])
    (w > 0 && h > 0) ? (w, h) : nothing
end
# Replace inlined base64 image <img>s in `html` with cached `/api/<nbid>/blob/<hash>` URLs, adding
# width/height so the layout reserves space before the (async, cached) image loads.
function _externalize_blobs(nbid::AbstractString, html::AbstractString)
    (isempty(nbid) || !occursin("data:image", html)) && return html
    replace(html, _IMG_RE => function (s)
        m = match(_IMG_RE, s)
        pre, mime, b64, post = m.captures
        bytes = try; Base64.base64decode(b64); catch; return s; end
        h = string(hash(bytes); base = 16)
        _blob_put!(string(nbid, "/", h), mime, bytes)
        dim = _png_dims(bytes)
        sz = dim === nothing ? "" : string(" width=\"", dim[1], "\" height=\"", dim[2], "\"")
        string("<img", pre, "src=\"/api/", nbid, "/blob/", h, "\"", sz, post, ">")
    end)
end

# ── Durable blob tier (content-addressed, on disk) ────────────────────────────────────────────
# The in-memory `_BLOBS` above is fine for small plot rasters but loses everything on a server
# restart and would be nuked by its crude 800-entry cap. Large, must-survive-restart artifacts —
# animation frame stacks especially — go to a content-addressed file store instead, so a worker /
# extension restart never has to recompute them and a browser reload serves them straight from disk.
# Key is "nbid/hash"; a `.meta` sidecar records (mime, Content-Encoding). Content-addressed → write once.
const _DBLOB_DIR = Ref{String}("")
function _dblob_dir()
    if _DBLOB_DIR[] == ""
        d = joinpath(get(ENV, "HOME", tempdir()), ".cache", "kaimon", "slate-blobs")
        try; mkpath(d); catch; d = joinpath(tempdir(), "kaimon-slate-blobs"); mkpath(d); end
        _DBLOB_DIR[] = d
    end
    return _DBLOB_DIR[]
end
_dblob_file(key::AbstractString) = joinpath(_dblob_dir(), replace(String(key), "/" => "__", r"[^A-Za-z0-9_.]" => "_"))

function _blob_put_durable!(key::AbstractString, mime::AbstractString, bytes::Vector{UInt8}; encoding::AbstractString = "")
    f = _dblob_file(key)
    try
        if !isfile(f)                                   # content-addressed: write once, atomically
            tmp = f * ".tmp" * string(hash(bytes); base = 16)
            write(tmp, bytes); mv(tmp, f; force = true)
            write(f * ".meta", string(mime, "\n", encoding))
        end
    catch
    end
    return nothing
end

# Route lookup: memory (`_BLOBS`) first, then the durable disk tier. Returns (mime, bytes, encoding).
function blob_lookup(key::AbstractString)
    m = lock(_BLOB_LOCK) do; get(_BLOBS, String(key), nothing); end
    m !== nothing && return (m[1], m[2], "")
    f = _dblob_file(key)
    isfile(f) || return nothing
    meta = isfile(f * ".meta") ? split(read(f * ".meta", String), "\n") : ["application/octet-stream", ""]
    return (String(meta[1]), read(f), length(meta) >= 2 ? String(meta[2]) : "")
end

# ── Overflow files (full results for truncated output) ───────────────────────────
# A truncated output's FULL result is written to a temp file by the worker (capture.jl); the path
# rides back in `CellOutput.overflow`. We register path-by-name here (confined: the serve route only
# hands out files we registered) and build a small access bar — open in a new tab / VS Code / download.
const _OUTFILES = Dict{String,String}()   # "id/<hashfile>" → absolute path
_outfile_put!(nbid, name, path) = lock(_BLOB_LOCK) do
    length(_OUTFILES) > 4000 && empty!(_OUTFILES)
    _OUTFILES[string(nbid, "/", name)] = String(path)
end
outfile_get(key) = lock(_BLOB_LOCK) do; get(_OUTFILES, String(key), nothing); end
_ovget(e, k, default = nothing) = e isa AbstractDict ? get(e, String(k), get(e, k, default)) :
                                  (hasproperty(e, k) ? getproperty(e, k) : default)
function _overflow_bar(nbid::AbstractString, entries)
    isempty(nbid) && return ""
    items = String[]
    for e in entries
        path = String(_ovget(e, :path, "")); isfile(path) || continue
        name = basename(path); _outfile_put!(nbid, name, path)
        url = string("/api/", nbid, "/output/", name)
        kind = String(_ovget(e, :kind, "output"))
        kb = round(Int, Int(_ovget(e, :bytes, 0)) / 1024)
        clipped = _ovget(e, :clipped, false) === true
        ext = endswith(path, ".html") ? "html" : "txt"
        push!(items, string(
            "<span class=\"ovitem\">⚠ full ", kind, " (", kb, " KB", clipped ? ", clipped at cap" : "", "): ",
            "<a href=\"", url, "\" target=\"_blank\" rel=\"noopener\">open ↗</a> · ",
            "<a href=\"vscode://file", path, "\">editor</a> · ",
            "<a href=\"", url, "\" download=\"", kind, "-", name, "\">download</a></span>"))
    end
    isempty(items) ? "" : string("<div class=\"ovbar\">", join(items, ""), "</div>")
end

# `bindref`: var-name → (defining cell, its BindSpec). `hostednames`: variable name →
# the cell ids that surface it via `controls=` (so each can collapse to a chip / jump link).
# `nbid` (when non-empty) externalizes inlined output images to cached blob URLs (see above).
# A friendly card for a `:bibliography` cell instead of dumping raw BibTeX. Adaptive: a small
# library (< _BIB_CARD_LIMIT) lists every entry, marking which are cited in the notebook vs not;
# a large library shows the count and lists ONLY the cited entries (so a 2000-entry Zotero file
# doesn't flood the cell). External files get a "view" link (the /bibfile route).
const _BIB_CARD_LIMIT = 10
function _bib_card_html(file::AbstractString, count::Integer, entries, nbid::AbstractString, cited,
                        numbers::Dict{String,Int} = Dict{String,Int}())
    esc(s) = replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
    ncited = Base.count(e -> e.key in cited, entries)
    meta(e) = strip(join(filter(!isempty, [String(e.author), String(e.title)]), " · "))
    # Cited entries get their [N] (matching the in-text numbers); uncited get a hollow marker.
    mark(e) = haskey(numbers, e.key) ? "<span class=\"bibcard-num\">[$(numbers[e.key])]</span>" :
              (e.key in cited ? "<span class=\"bibcard-tick\">●</span>" : "<span class=\"bibcard-tick\">○</span>")
    item(e) = string("<li class=\"", e.key in cited ? "cited" : "uncited", "\">", mark(e),
        "<code>", esc(e.key), "</code>",
        isempty(meta(e)) ? "" : "<span class=\"bibcard-meta\">" * esc(meta(e)) * "</span></li>")
    io = IOBuffer()
    print(io, "<div class=\"bibcard\"><div class=\"bibcard-hd\">📚 <strong>References</strong>",
          "<span class=\"bibcard-n\">", count, count == 1 ? " entry" : " entries",
          ncited > 0 ? " · $(ncited) cited" : "", "</span></div>")
    if !isempty(file)
        link = "/api/" * esc(nbid) * "/bibfile?name=" * esc(file)
        print(io, "<div class=\"bibcard-file\">External file: <a href=\"", link,
              "\" target=\"_blank\" rel=\"noopener\"><code>", esc(file), "</code></a></div>")
    end
    if count == 0
        print(io, "<div class=\"bibcard-empty\">No entries found", isempty(file) ? "." : " in this file.", "</div>")
    elseif count < _BIB_CARD_LIMIT
        # Small library: list all, highlighting cited vs uncited.
        print(io, "<ul class=\"bibcard-keys\">")
        for e in entries; print(io, item(e)); end
        print(io, "</ul>")
    elseif ncited == 0
        print(io, "<div class=\"bibcard-empty\">No entries cited yet — cite with <code>[@key]</code>.</div>")
    else
        # Large library: show only the cited entries.
        print(io, "<div class=\"bibcard-note\">Showing the $(ncited) cited of $(count) entries.</div>",
              "<ul class=\"bibcard-keys\">")
        for e in entries; e.key in cited && print(io, item(e)); end
        print(io, "</ul>")
    end
    print(io, "<div class=\"bibcard-hint\">Cite with <code>[@key]</code> in markdown.</div></div>")
    return String(take!(io))
end

# HTML link for a live citation: a numbered `[N]` (by appearance, matching the numeric PDF style),
# jumping to the bibliography cell, with the entry as a tooltip.
function _cite_link_emit(anchor::AbstractString, entries::Dict{String,String}, numbers::Dict{String,Int})
    esc(s) = replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
    return (key, sup, _form) -> begin
        n = get(numbers, String(key), 0)
        num = n == 0 ? String(key) : string(n)                       # fall back to the key if unnumbered
        lbl = isempty(strip(sup)) ? num : string(num, ", ", strip(sup))
        href = isempty(anchor) ? "" : " href=\"#cell-$(esc(anchor))\""
        string("<a class=\"cite\"", href, " title=\"", esc(get(entries, String(key), String(key))),
               "\">", esc(lbl), "</a>")
    end
end
# (anchor cell id, key→"author · title", key→number) for live citation links — read from the
# notebook's :bibliography cells. Empty anchor when the notebook has no bibliography.
function _bib_link_ctx(nb)
    bi = bibliography_index(nb.report, dirname(abspath(nb.path)))
    isempty(bi) && return ("", Dict{String,String}(), Dict{String,Int}())
    idx = findfirst(c -> :bibliography in c.flags, nb.report.cells)
    anchor = idx === nothing ? "" : nb.report.cells[idx].id
    entries = Dict{String,String}(e.key => strip(join(filter(!isempty, [e.author, e.title]), " · ")) for e in bi)
    numbers = citation_numbers(nb.report, Set(e.key for e in bi))
    return (anchor, entries, numbers)
end

function cell_json(c::Cell, bindref::Dict{String,Tuple{Cell,BindSpec}} = Dict{String,Tuple{Cell,BindSpec}}(),
                   hostednames::Dict{String,Vector{String}} = Dict{String,Vector{String}}();
                   multidef::Set{String} = Set{String}(), nbid::AbstractString = "",
                   nbdir::AbstractString = "", cited::Set{String} = Set{String}(),
                   bibanchor::AbstractString = "", bibentries::Dict{String,String} = Dict{String,String}(),
                   bibnumbers::Dict{String,Int} = Dict{String,Int}())
    # Markdown citations → numbered links to the bibliography cell (skips the bibliography cells).
    _mdsrc = (c.kind == MARKDOWN && !isempty(bibanchor) && !(:bibliography in c.flags)) ?
        _rewrite_citations(c.source, Set(keys(bibentries)); emit = _cite_link_emit(bibanchor, bibentries, bibnumbers)) : c.source
    d = Dict{String,Any}(
        "id"      => c.id,
        "kind"    => c.kind == MARKDOWN ? "md" : "code",
        "source"  => c.source,
        "state"   => lowercase(string(c.state)),
        "output"  => _externalize_blobs(nbid, c.kind == MARKDOWN ? markdown_html(_mdsrc, c.interp) : output_html(c)),
        "echarts" => c.kind == MARKDOWN ? _md_interp_echarts(c) : _echarts_specs(c),
        "tables" => c.kind == MARKDOWN ? _md_interp_tables(c) : _table_specs(c),
        "animations" => c.kind == MARKDOWN ? Any[] : _animation_specs(c, nbid),
        "duration" => c.output === nothing ? nothing : round(c.output.duration_ms; digits = 1),
        "deps"    => collect(c.deps),
        # Top-level names this cell defines — drives ⌘-click go-to-definition in the editor.
        "defs"    => c.kind == CODE ? sort!(String[string(w) for w in c.writes]) : String[],
    )
    if !isempty(c.controls)
        # resolve each column's names to (defining cell, spec); drop unknown names + empty columns
        cols = [[_control_spec(bindref[n]...) for n in col if haskey(bindref, n)] for col in c.controls]
        cols = filter(!isempty, cols)
        isempty(cols) || (d["controls"] = cols)
    end
    if !isempty(c.binds)
        d["binds"] = [_bind_json(b, get(hostednames, String(b.name), String[])) for b in c.binds]
    end
    (:collapsed in c.flags) && (d["collapsed"] = true)   # folded in the UI (persisted in the .jl)
    (:hidecode in c.flags) && (d["codeHidden"] = true)   # code editor hidden, output shown
    (:trace in c.flags) && (d["trace"] = true)           # @trace-wrapped on eval (collects trace rows)
    (:slide in c.flags) && (d["slide"] = true)           # explicit slide-start (presentation mode)
    (:notes in c.flags) && (d["notes"] = true)           # speaker notes — presenter view only
    (:title in c.flags) && (d["roleTitle"] = true)       # document title block (export metadata)
    (:abstract in c.flags) && (d["roleAbstract"] = true) # abstract — hoisted into the title block on export
    if :bibliography in c.flags                          # bibliography / references
        d["roleBib"] = true
        file, n, es = bib_cell_info(c, nbdir)            # external file (or "") + entry count + keys
        d["bibFile"] = file
        d["bibCount"] = n
        d["bibKeys"] = [Dict("key" => e.key, "title" => e.title, "author" => e.author) for e in es]
        d["output"] = _bib_card_html(file, n, es, nbid, cited, bibnumbers)  # card instead of raw BibTeX
    end
    # All user-facing tags (known behaviour tags + free-form) for the cell-header tag editor;
    # `:opaque` is inferred each eval, not a user tag, so it's excluded.
    d["tags"] = sort!(String[string(f) for f in c.flags if f !== :opaque])
    if c.output !== nothing && c.output.exception !== nothing
        el = ReportRender._cell_error_line(c.output, c.id)   # offending cell line → editor highlight + jump
        el === nothing || (d["errorLine"] = el)
    end
    # The trace rows ({line,name,value}) for the inspector popup — the cell's normal output is shown
    # in place; this rides alongside for the modal. Present only when the cell ran traced.
    (c.output === nothing || isempty(c.output.trace)) || (d["traceData"] = c.output.trace)
    # `@bind` variables this cell READS (so the header can one-click surface their controls) —
    # excluding any it defines itself.
    if c.kind == CODE && !isempty(c.reads)
        own = Set(String(b.name) for b in c.binds)
        uses = sort!(unique!(String[String(s) for s in c.reads if haskey(bindref, String(s)) && !(String(s) in own)]))
        isempty(uses) || (d["binduses"] = uses)
    end
    # Names this cell defines that are ALSO defined by another cell — a silent footgun in a shared
    # namespace (last-writer-wins). The UI flags it so collisions don't masquerade as dead reactivity.
    if c.kind == CODE && !isempty(multidef)
        dup = sort!(String[string(w) for w in c.writes if string(w) in multidef])
        isempty(dup) || (d["dupdefs"] = dup)
    end
    # Truncated outputs → append an access bar (open ↗ / editor / download) to the rendered output.
    if c.kind == CODE && c.output !== nothing && !isempty(c.output.overflow)
        bar = _overflow_bar(nbid, c.output.overflow)
        isempty(bar) || (d["output"] = String(d["output"]) * bar)
    end
    return d
end

# Set widget `name` (defined by cell `id`) → recompute its dependents (the
# reactive heart of @bind). A group cell's blast radius is by cell id, which is
# conservative (touches readers of any of its vars) but never under-invalidates.
function set_bind!(nb::LiveNotebook, id::AbstractString, name::AbstractString, value)
    idx = findfirst(c -> c.id == id, nb.report.cells)
    idx === nothing && return nb
    cell = nb.report.cells[idx]
    isempty(cell.binds) && return nb
    lock(nb.lock) do
        set_bind_value!(nb.report, cell, Symbol(name), value, nb.kernel)
        # Re-run the defining cell itself ONLY when it actually depends on the control
        # that changed — i.e. the changed var is in its `reads` (its own code or another
        # widget's args use it: `@bind a …; y = a*2`, or `@bind d Slider(1:a)`). The
        # registry preserves the value across that re-run. A cell that defines the control
        # but doesn't read it (incl. a pure bind cell) is skipped, so dragging its slider
        # never needlessly re-evaluates (and re-renders) the control.
        reruns_self = Symbol(name) in cell.reads
        for did in dependents_of(nb.report, Set([id]))
            (did == id && !reruns_self) && continue
            j = findfirst(c -> c.id == did, nb.report.cells)
            j === nothing || (nb.report.cells[j].state = STALE)
        end
        _eval!(nb)
    end
    return nb
end

# Index every bound variable by name → (defining cell, spec), and the set of
# variable names surfaced in some cell's control strip.
function _bind_index(report::Report)
    bindref = Dict{String,Tuple{Cell,BindSpec}}()
    for c in report.cells, b in c.binds
        bindref[String(b.name)] = (c, b)
    end
    hostednames = Dict{String,Vector{String}}()
    for c in report.cells, col in c.controls, n in col
        haskey(bindref, n) && push!(get!(hostednames, n, String[]), c.id)
    end
    return bindref, hostednames
end

# Worker/kernel status for the topbar dot.
_kernel_status(k::GateKernel) = Dict{String,Any}("kind" => "gate", "port" => k.port, "connected" => (k.conn !== nothing))
_kernel_status(::Kernel) = Dict{String,Any}("kind" => "inproc", "port" => 0, "connected" => true)

function state_json(nb::LiveNotebook)
    meta = Dict{String,Any}(
        "id" => nb.id, "title" => nb.report.title, "path" => abspath(nb.path),
        "version" => nb.version, "worker" => _kernel_status(nb.kernel))
    # The project ROOT (dir holding the nearest Project.toml above the notebook) — so "open
    # project in VS Code" opens the project, not the notebooks/ subdir. Omitted when detached.
    let proj = Base.current_project(dirname(abspath(nb.path)))
        proj === nothing || (meta["project"] = dirname(proj))
    end
    meta["hotreload"] = get(nb.report.meta, "hotreload", true)   # /src auto-reload toggle (default on)
    meta["parallel"] = get(nb.report.meta, "parallel", PARALLEL_DEFAULT[])   # effective state (default + per-nb override)
    meta["threads"] = get(nb.report.meta, "threads", "")                     # per-notebook worker thread override ("" = global)
    meta["threadsEffective"] = nb.kernel isa ReportEngine.GateKernel ?       # what the live worker spawns with
        ReportEngine.effective_worker_threads(nb.kernel.threads) : ""
    # Slide-deck presentation prefs (per-notebook, persisted in the Slate.config footer).
    meta["slideLevel"] = get(nb.report.meta, "slidelevel", 2)               # heading depth that starts a slide
    meta["slideTransition"] = get(nb.report.meta, "slidetransition", "fade") # none | fade | slide
    meta["slideTheme"] = get(nb.report.meta, "slidetheme", "")               # "" = follow the editor theme
    meta["slideRatio"] = get(nb.report.meta, "slideratio", "16:9")           # PDF deck aspect ratio
    meta["bibStyle"] = get(nb.report.meta, "bibstyle", "ieee")               # CSL citation/reference style
    meta["undoLabel"] = undo_label(nb)   # next undoable action ("paste 3 cells"/…) — labels the Undo button
    meta["redoLabel"] = redo_label(nb)
    if get(nb.report.meta, "hydrating", false) === true
        # While the env reconstructs: show the embedded frozen render if present (already
        # cell_json-shaped), else the parsed cells un-run. Live cells replace these on hydrate.
        meta["cells"] = if haskey(nb.report.meta, "preview")
            nb.report.meta["preview"]
        else
            bindref, hostednames = _bind_index(nb.report)
            [cell_json(c, bindref, hostednames) for c in nb.report.cells]
        end
        meta["hydrating"] = true
        # "env" = reconstructing a self-contained bundle's environment (shows a frozen preview);
        # "run" = a normal open whose initial full run is happening in the background.
        meta["hydratingKind"] = haskey(nb.report.meta, "preview") ? "env" : "run"
        return meta
    end
    bindref, hostednames = _bind_index(nb.report)
    md = Set{String}(get(nb.report.meta, "multidef", String[]))   # names defined in 2+ cells → per-cell flag
    meta["multidefCells"] = get(nb.report.meta, "multidef_cells", Dict{String,Vector{String}}())   # name → defining cells (popup)
    nbdir = dirname(abspath(nb.path))
    cited = cited_citation_keys(nb.report)   # keys referenced in prose → adaptive references card
    bibanchor, bibentries, bibnumbers = _bib_link_ctx(nb)   # live citation links → the bibliography cell
    meta["cells"] = [cell_json(c, bindref, hostednames; multidef = md, nbid = nb.id, nbdir = nbdir,
        cited = cited, bibanchor = bibanchor, bibentries = bibentries, bibnumbers = bibnumbers) for c in nb.report.cells]
    # Citation keys defined across all :bibliography cells — drives `[@`-autocomplete in markdown.
    isempty(bibentries) || (meta["bibKeys"] = [Dict("key" => k, "label" => v) for (k, v) in bibentries])
    haskey(nb.report.meta, "hydrate_error") && (meta["hydrateError"] = nb.report.meta["hydrate_error"])
    return meta
end

# Edit a cell's source → reconcile (mark it + dependents stale) → run stale →
# persist back to the `.jl`.
function edit_cell!(nb::LiveNotebook, id::AbstractString, source::AbstractString; announce::Bool = false, force::Bool = false)
    # MUST hold nb.lock around the report mutation + persist: with async eval the runner / set_bind!
    # (playhead) hold the lock intermittently, so an unlocked update_source!+_persist! here races them
    # and can lose the edit (it temporarily reverts the source mid-serialize). Reentrant-safe — the
    # agent edit path already wraps this in nb.lock.
    lock(nb.lock) do
        cells = nb.report.cells
        idx = findfirst(c -> c.id == id, cells)
        idx === nothing && return
        cells[idx].source == String(source) || _snapshot!(nb)
        # Build the new full source with this cell swapped, WITHOUT disturbing report state first —
        # otherwise update_source! compares the new source to itself, sees "unchanged", and never
        # marks the cell stale (so it never re-runs).
        saved = cells[idx].source
        cells[idx].source = String(source)
        new_full = serialize_report(nb.report)
        cells[idx].source = saved
        update_source!(nb.report, new_full)
        # force=true → re-run even when the source is unchanged (the explicit play/run button). A forced
        # re-run may change this cell's outputs (or clear an error), so its DEPENDENTS must re-run too —
        # otherwise downstream cells keep stale/errored results from the previous run (e.g. re-running a
        # producer that previously errored leaves its consumers stuck ERRORED). update_source! only
        # restales dependents when the SOURCE changed, so on an unchanged force-run we do it explicitly.
        if force
            i = findfirst(c -> c.id == id, nb.report.cells)
            if i !== nothing
                for did in dependents_of(nb.report, Set([id]))   # closure includes `id` itself
                    j = findfirst(c -> c.id == did, nb.report.cells)
                    j === nothing || (nb.report.cells[j].state = STALE)
                end
            end
        end
        # announce=true → show the edited source (stale) before its eval finishes.
        announce && _announce_cell!(nb, something(findfirst(c -> c.id == id, nb.report.cells), 0))
        _eval!(nb)                       # non-blocking kick (safe inside the lock)
        _persist!(nb)
    end
    _autoindex!(nb)                      # a new `using` in this cell → pick up its docs (outside lock)
    return nb
end

