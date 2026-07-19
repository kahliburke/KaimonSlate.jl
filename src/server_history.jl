# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Durable history (the time machine) ───────────────────────────────────────
# Capture the *current* notebook state into the append-only store. Dedup-by-hash
# makes a no-op capture free, so this is safe to call liberally (every op, every
# sync, the periodic draft net). Per-cell digests let the UI attribute + recover
# individual cells. Never throws into the caller.
_cells_of(report) = [(c.id, c.kind == MARKDOWN ? "md" : "code", c.source) for c in report.cells]
function _history!(nb::LiveNotebook; source::AbstractString = "browser", kind::AbstractString = "checkpoint",
                   label::AbstractString = "")
    try
        SlateHistory.record!(nb.path, serialize_report(nb.report);
                             source_label = source, kind = kind, cells = _cells_of(nb.report), label = label)
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
function _persist!(nb::LiveNotebook; source::AbstractString = "browser", label::AbstractString = "")
    s = serialize_report(nb.report)
    # Preserve a self-contained `.jl`'s env artifacts. `serialize_report` writes only the lightweight
    # env/config footers, so without this the FIRST edit-save silently strips the `Slate.bundle` (and
    # `Slate.preview`) footer — the file stops being self-contained: it no longer `expand`s, and a
    # detached open can't reconstruct its env (stdlibs included). Carry the verbatim footers from the
    # current on-disk file forward. Idempotent: once carried, the next serialize re-finds them here.
    try
        if isfile(nb.path)
            carry = _carry_env_footers(read(nb.path, String))
            isempty(carry) || (s = rstrip(s, '\n') * "\n\n" * carry * "\n")
        end
    catch e
        @warn "KaimonSlate: could not preserve bundle footer on save" exception = (e, catch_backtrace())
    end
    _note_server_write!(nb.report.id, hash(s))   # register BEFORE writing: a watcher tick fired by
    write(nb.path, s)                             # this write must recognize it as OURS, not external
    nb.version += 1                               # every in-app commit advances the version (CAS basis)
    _history!(nb; source = source, label = label)
    return nb
end

# Infra packages the remote provisioner adds INTO the worker's env (the single-env fix) — filtered out
# of the notebook's package view + footer so they don't masquerade as the user's own deps.
const _WORKER_INFRA_PKGS = Set(["KaimonGate", "Revise", "ExpressionExplorer"])

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
    # Worker infra injected into a REMOTE worker's env (one-env fix) — not the user's notebook deps, so
    # hide them from the package viewer + the reproducibility footer (the remote provisioner adds them).
    union!(pnames, _WORKER_INFRA_PKGS)
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

# Add/remove a package in THIS NOTEBOOK's own forked env (not the parent project), then re-run the
# code cells so a `using` lights up, sync the `.jl` Slate.env footer, and refresh docs/agent view.
# The single source of truth for the browser package panel (`POST /api/{id}/package`) AND the
# `slate.pkg` agent tool — so both paths behave identically. `op` is "add" or "rm".
function notebook_pkg_op!(nb::LiveNotebook, op::AbstractString, name::AbstractString;
                          target::AbstractString = "notebook")
    (op in ("add", "rm")) || return Dict{String,Any}("ok" => false, "message" => "bad op '$op'")
    res = lock(nb.lock) do
        r = ReportEngine.pkg_op(nb.kernel, nb.report, op, name; target = target)
        if get(r, "ok", false) === true              # env changed → re-run so `using` cells pick it up
            for c in nb.report.cells; c.kind == CODE && (c.state = STALE); end
            _eval!(nb)
            _refresh_env_meta!(nb)                   # update the .jl reproducibility footer
        end
        r
    end
    get(res, "ok", false) === true && (_autoindex!(nb); _agent_push!(nb))
    return res
end

# ── Durable per-notebook config registry (the "Notebook config" panel SSOT) ────────────────────────
# One entry per Slate.config footer key the panel exposes: its UI group/label/type, its built-in
# default, an optional server-global default (the slate.json tier — `nothing` means the only tiers
# are notebook-override and built-in, e.g. a client-side global like the browser agent-model pref),
# and whether changing it respawns the worker. Drives GET/POST /api/{id}/config. NOTE: agent
# *permission* is deliberately NOT here — it must never travel in a file (a `bypass` preset riding a
# shared notebook is a privilege-escalation footgun); the client remembers it locally per notebook.
const _CONFIG_UI = (
    (key = "agentmodel", group = "Agent", label = "Agent model", type = :string, default = "",
     choices = String[], global_default = nothing, restart = false),
    (key = "threads", group = "Execution", label = "Worker threads", type = :string, default = "",
     choices = String[], global_default = () -> ReportEngine.WORKER_THREADS[], restart = true),
    (key = "juliaflags", group = "Execution", label = "Extra Julia flags", type = :string, default = "",
     choices = String[], global_default = () -> ReportEngine.WORKER_EXTRA_FLAGS[], restart = true),
    (key = "parallel", group = "Execution", label = "Parallel cells", type = :bool, default = true,
     choices = String[], global_default = () -> PARALLEL_DEFAULT[], restart = false),
    (key = "hotreload", group = "Execution", label = "Hot-reload /src edits", type = :bool, default = true,
     choices = String[], global_default = nothing, restart = false),
    (key = "macroexpand", group = "Execution", label = "Macro-aware deps", type = :bool, default = true,
     choices = String[], global_default = nothing, restart = false),
    (key = "slidelevel", group = "Slides", label = "Slide heading level", type = :int, default = 2,
     choices = String[], global_default = nothing, restart = false),
    (key = "slidetransition", group = "Slides", label = "Slide transition", type = :enum, default = "fade",
     choices = ["none", "fade", "slide"], global_default = nothing, restart = false),
    (key = "slideratio", group = "Slides", label = "PDF slide ratio", type = :enum, default = "16:9",
     choices = ["16:9", "4:3"], global_default = nothing, restart = false),
    (key = "bibstyle", group = "Slides", label = "Bibliography style", type = :string, default = "ieee",
     choices = String[], global_default = nothing, restart = false),
    (key = "series", group = "Publishing", label = "Series", type = :string, default = "",
     choices = String[], global_default = nothing, restart = false),
)

_config_item(key) = (i = findfirst(x -> x.key == key, _CONFIG_UI); i === nothing ? nothing : _CONFIG_UI[i])

# The config panel's view: each setting with its effective value, whether the notebook overrides it,
# and the global/built-in it would fall back to. The client layers its own browser-global (agent
# model) on top for keys whose `global` is null.
function notebook_config_payload(nb::LiveNotebook)
    meta = nb.report.meta
    items = map(_CONFIG_UI) do it
        gd = it.global_default === nothing ? nothing : it.global_default()
        overridden = haskey(meta, it.key)
        Dict{String,Any}("key" => it.key, "group" => it.group, "label" => it.label,
                         "type" => String(it.type), "choices" => it.choices,
                         "overridden" => overridden,
                         "value" => overridden ? meta[it.key] : (gd === nothing ? it.default : gd),
                         "default" => it.default, "global" => gd)
    end
    return Dict{String,Any}("items" => collect(items))
end

# Set (or clear) one per-notebook config override, persist the footer, and run its side effect.
# `clear=true` or an empty string value removes the override so the setting follows the global/default.
function set_notebook_config!(nb::LiveNotebook, key::AbstractString, value; clear::Bool = false)
    it = _config_item(String(key))
    it === nothing && return Dict{String,Any}("ok" => false, "message" => "unknown config key '$key'")
    if clear || (value isa AbstractString && isempty(strip(String(value))))
        delete!(nb.report.meta, it.key)
    else
        nb.report.meta[it.key] = it.type === :bool ? (value === true || value == "true") :
                                 it.type === :int  ? something(tryparse(Int, string(value)), it.default) :
                                 String(string(value))
    end
    it.key == "threads" && nb.kernel isa ReportEngine.GateKernel &&
        (nb.kernel.threads = get(nb.report.meta, "threads", ""))
    it.key == "juliaflags" && nb.kernel isa ReportEngine.GateKernel &&
        (nb.kernel.extra_flags = get(nb.report.meta, "juliaflags", ""))
    _persist!(nb)
    it.restart && restart_kernel!(nb)
    return Dict{String,Any}("ok" => true)
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

# JSON has no NaN/±Inf — one non-finite float anywhere in a chart option made JSON.json throw,
# turning the WHOLE state pull into a 500 (a blank notebook in the browser). Sanitize at the
# egress choke point: non-finite → nothing (null), which ECharts renders as a gap — the correct
# chart semantic for NaN anyway. Recurses the shapes an option is built from (Dict / NamedTuple /
# Vector / Tuple / Pair); everything else passes through untouched.
_json_finite(x) = x
_json_finite(x::AbstractFloat) = isfinite(x) ? x : nothing
_json_finite(x::AbstractDict) = Dict{Any,Any}(k => _json_finite(v) for (k, v) in x)
_json_finite(x::NamedTuple) = NamedTuple{keys(x)}(map(_json_finite, values(x)))
_json_finite(x::Union{AbstractVector,Tuple}) = Any[_json_finite(v) for v in x]
_json_finite(x::Pair) = _json_finite(x.first) => _json_finite(x.second)

_echarts_specs(c::Cell) = c.output === nothing ? Any[] : Any[_json_finite(e) for e in c.output.echarts]
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
# A generated-asset record → its bytes. A byte/string/array asset carries `bytes`; a JSON-value asset
# carries `value` and is encoded HERE (the worker has no JSON dep — mirrors echarts/tables). Shared by
# state-serving and the static export so both agree on the exact bytes + their content hash.
_asset_bytes(a) = hasproperty(a, :bytes) ? Vector{UInt8}(getfield(a, :bytes)) :
                  Vector{UInt8}(codeunits(JSON.json(getfield(a, :value))))
# Typed-array metadata for a packed numeric asset (`{dtype, shape, order}`), empty otherwise — rides in
# the spec so the client hands back an ndarray-lite instead of a raw ArrayBuffer.
_asset_meta(a) = hasproperty(a, :dtype) ?
    Dict{String,Any}("dtype" => getfield(a, :dtype), "shape" => collect(getfield(a, :shape)), "order" => getfield(a, :order)) :
    Dict{String,Any}()

# Shared metadata for a generated asset — everything but the transport (`url`/`data`, set by each caller):
# path, mime, original name, byte size, content sha, PRODUCING CELL, creation time, and typed-array
# shape/dtype/order. Both live serving and the static export build their registry entries on this, so a
# widget's `Slate.assetInfo(path)` reports the same facts everywhere. `sha` is the content hash (also the
# blob key + a stable id).
function _asset_common(a, bytes::Vector{UInt8}, cellid::AbstractString)
    d = Dict{String,Any}("path" => String(getfield(a, :path)), "mime" => String(getfield(a, :mime)),
                         "name" => String(getfield(a, :name)), "bytes" => length(bytes),
                         "sha" => string(hash(bytes); base = 16), "cell" => String(cellid))
    hasproperty(a, :created) && (d["created"] = getfield(a, :created))
    merge!(d, _asset_meta(a))
    return d
end

# Generated assets (`save_asset`) a cell produced → wire specs (see `_asset_common`) + the served blob
# `url`. The bytes go into the content-addressed store (served at `/api/<id>/blob/<sha>`); the client
# builds a `path → asset` registry from these so `Slate.asset(path)` resolves live. Mirrors `_animation_specs`.
function _asset_specs(c::Cell, nbid::AbstractString = "")
    (c.output === nothing || isempty(c.output.assets) || isempty(nbid)) && return Any[]
    specs = Any[]
    for a in c.output.assets
        bytes = _asset_bytes(a); d = _asset_common(a, bytes, c.id)
        _blob_put_durable!(string(nbid, "/", d["sha"]), d["mime"], bytes)
        d["url"] = string("/api/", nbid, "/blob/", d["sha"])
        push!(specs, d)
    end
    return specs
end
# Specs from a markdown cell's `{{ }}` interpolations, in document order (matches
# the `.ichart`/`.itable` placeholder indices the renderer emits).
_md_interp_echarts(c::Cell) = (e = Any[]; for o in c.interp, s in o.echarts; push!(e, _json_finite(s)); end; e)
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
# Preview-asset size caps (shared by the durable-blob tier, the interim-render sidecar, and the
# export-embedded preview). A single rendered asset over `_PREVIEW_MAX_ASSET` isn't persisted for
# interim display — it recomputes live on reopen rather than bloating the sidecar / export. The
# `_PREVIEW_MAX_TOTAL` cap bounds a whole notebook's persisted preview (enforced at snapshot/export
# time, where the running total is known).
const _PREVIEW_MAX_ASSET = 5 * 1024 * 1024
const _PREVIEW_MAX_TOTAL = 50 * 1024 * 1024

# Replace inlined base64 image <img>s in `html` with cached `/api/<nbid>/blob/<hash>` URLs, adding
# width/height so the layout reserves space before the (async, cached) image loads.
function _externalize_blobs(nbid::AbstractString, html::AbstractString)
    (isempty(nbid) || !occursin("data:image", html)) && return html
    replace(html, _IMG_RE => function (s)
        m = match(_IMG_RE, s)
        pre, mime, b64, post = m.captures
        bytes = try; Base64.base64decode(b64); catch; return s; end
        h = string(hash(bytes); base = 16)
        key = string(nbid, "/", h)
        _blob_put!(key, mime, bytes)
        # Also persist to the durable tier (under the per-asset cap), so the interim-render preview
        # survives a server restart AND has a real byte source to re-inline into a travelling export.
        # Content-addressed → write-once; an oversized asset stays memory-only and recomputes on reopen.
        length(bytes) <= _PREVIEW_MAX_ASSET && _blob_put_durable!(key, mime, bytes)
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
        d = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(get(ENV, "HOME", tempdir()), ".cache")), "kaimonslate", "blobs")
        try; mkpath(d); catch; d = joinpath(tempdir(), "kaimonslate-blobs"); mkpath(d); end
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

# ── Rendered cells array ──────────────────────────────────────────────────────────────────────
# The document's cells as JSON (`state_json`'s `cells`), factored out so the interim-render snapshot
# (below) and the export-embedded preview build the SAME shape from the SAME code path. Recomputes
# the render context (bind index, citations, figure numbering) when not supplied by the caller.
function _render_cells(nb::LiveNotebook; bindref = nothing, hostednames = nothing,
                       md = nothing, nbdir = nothing, cited = nothing, bibctx = :unset,
                       figidx = :unset, br = nothing)
    if bindref === nothing || hostednames === nothing
        bindref, hostednames = _bind_index(nb.report)
    end
    md === nothing && (md = Set{String}(get(nb.report.meta, "multidef", String[])))
    br === nothing && (br = get(nb.report.meta, "backref", Dict{String,Vector{String}}()))
    nbdir === nothing && (nbdir = dirname(abspath(nb.path)))
    cited === nothing && (cited = cited_citation_keys(nb.report))
    bibctx === :unset && (bibctx = _bib_link_ctx(nb))
    figidx === :unset && (figidx = figure_index(nb.report))
    return [cell_json(c, bindref, hostednames; multidef = md, nbid = nb.id, nbdir = nbdir,
        cited = cited, bibctx = bibctx, figidx = figidx, backref = br, report = nb.report)
            for c in nb.report.cells]
end

# ── Interim-render preview sidecar ──────────────────────────────────────────────────────────────
# Persist the last rendered cells array (with rich display) so REOPENING a notebook shows the
# last-known figures at full fidelity INSTANTLY while the live env boots and cells recompute — the
# notebook "springs to life" instead of showing everything un-run. Keyed by the notebook's abspath
# (mirrors the chat-log sidecar); the display BYTES already live in the durable blob tier, so the
# manifest is small (blob URLs, not inline rasters). Cache-tier and fully disposable: a missing or
# corrupt sidecar just means no interim preview, never a correctness issue. Live cells supersede it
# cell-by-cell as each `celldone:` lands (the browser reconciles by id + content hash).
_preview_file(path) = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
    "kaimonslate", "preview", SlateHistory._sha(abspath(String(path)))[1:16] * ".json")

const _PREVIEW_SAVE_AT = Dict{String,Float64}()   # nbid → last flush time (debounce)
const _PREVIEW_SAVE_LOCK = ReentrantLock()
const _PREVIEW_DEBOUNCE_S = 2.0

# Any cell carrying rich display output (figure/image/rich HTML/table/echart/animation) — the signal
# that a notebook is worth snapshotting for interim display. Cheap text-only cells recompute fast and
# don't need a preview.
function _has_rich_display(nb::LiveNotebook)
    for c in nb.report.cells
        o = c.output
        o === nothing && continue
        (isempty(o.display) && isempty(_echarts_specs(c)) && isempty(_table_specs(c)) &&
         isempty(_animation_specs(c, nb.id))) || return true
    end
    return false
end

# Every blob hash the rendered `cells` still reference (across output HTML, animation manifests,
# echart specs, tables) — the SET the durable tier must keep for this notebook. Anything else under
# this notebook's id is a superseded render, safe to evict.
const _BLOBHASH_RE = r"/blob/([A-Za-z0-9]+)"
function _live_blob_hashes(cells)
    live = Set{String}()
    for e in cells
        e isa AbstractDict || continue
        for k in ("output", "animations", "echarts", "tables", "assets")
            v = get(e, k, nothing); v === nothing && continue
            s = v isa AbstractString ? v : JSON.json(v)
            for m in eachmatch(_BLOBHASH_RE, s); push!(live, String(m.captures[1])); end
        end
    end
    return live
end

# Superseded rendered figures pile up in the durable blob tier (content-addressed, write-once): every
# edit that changes a plot mints a NEW hash, so the old raster would otherwise linger forever. The
# freshly-snapshotted render tells us EXACTLY which blobs this notebook still references — so drop
# every durable blob under this notebook's id whose hash isn't among them. Bounds the tier to the
# live render; another notebook's blobs (its own id prefix) are untouched. Best-effort.
function _prune_preview_blobs!(nbid::AbstractString, live::AbstractSet)
    try
        dir = _dblob_dir()
        base = basename(_dblob_file(string(nbid, "/")))   # "<nbid>__" (key sep "/" → "__")
        for fn in readdir(dir)
            (startswith(fn, base) && !endswith(fn, ".meta")) || continue
            h = fn[nextind(fn, lastindex(base)):end]
            h in live && continue
            rm(joinpath(dir, fn); force = true)
            rm(joinpath(dir, fn * ".meta"); force = true)
        end
    catch e
        @debug "KaimonSlate: preview blob prune failed" exception = (e, catch_backtrace())
    end
    return nothing
end

# Snapshot the current render to the sidecar. Debounced (a burst of `celldone:`s during a run
# coalesces into a couple of writes); pass `force=true` to flush the final state (run complete /
# close). Best-effort — a failed snapshot must never disturb evaluation.
function _save_preview!(nb::LiveNotebook; force::Bool = false)
    do_save = lock(_PREVIEW_SAVE_LOCK) do
        now = time()
        last = get(_PREVIEW_SAVE_AT, nb.id, 0.0)
        (force || now - last > _PREVIEW_DEBOUNCE_S) ? (_PREVIEW_SAVE_AT[nb.id] = now; true) : false
    end
    do_save || return nothing
    try
        cells = lock(nb.lock) do
            _has_rich_display(nb) ? _render_cells(nb) : nothing
        end
        cells === nothing && return nothing   # nothing rich to preview — leave any stale sidecar for now
        f = _preview_file(nb.path)
        mkpath(dirname(f))
        tmp = f * ".tmp"
        open(tmp, "w") do io; JSON.print(io, cells); end
        mv(tmp, f; force = true)
        _prune_preview_blobs!(nb.id, _live_blob_hashes(cells))   # evict superseded figure rasters
    catch e
        @debug "KaimonSlate: preview snapshot failed" exception = (e, catch_backtrace())
    end
    return nothing
end

# The persisted interim render for `path`, marked up for hydration: each entry gets `preview=true`
# (a stored-render marker → full-fidelity display + a "stored" badge) and `previewStale=true` when
# the saved source hash no longer matches the freshly-parsed cell (edited since the snapshot, so the
# figure may be out of date). Returns nothing when there's no usable sidecar.
function _load_preview_marked(path::AbstractString, report)
    f = _preview_file(path)
    isfile(f) || return nothing
    cells = try; JSON.parse(read(f, String)); catch; nothing; end
    (cells isa AbstractVector && !isempty(cells)) || return nothing
    live = Dict{String,String}()
    for c in report.cells
        live[c.id] = SlateHistory._sha(c.source)
    end
    for e in cells
        e isa AbstractDict || continue
        e["preview"] = true
        id = String(get(e, "id", "")); h = String(get(e, "hash", ""))
        e["previewStale"] = !(haskey(live, id) && live[id] == h)
    end
    return cells
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

# HTML link for a live citation, formatted to TRACK the notebook's bibstyle: `[1]` for numeric
# styles, `(Knuth, 1984)` for author-date. Jumps to the bibliography cell; the tooltip is the entry.
# A live `[@fig:label]` cross-reference → an HTML link that scrolls to the figure and shows "Figure N".
_fig_link_emit(num, anchor) =
    string("<a class=\"figref\" href=\"#cell-", replace(String(anchor), "\"" => ""), "\">Figure ", num, "</a>")
# Fallback bracket-cite emit for the live view when the notebook has NO bibliography: reconstruct the
# original `[@key]` literally so a stray citation isn't turned into a Typst sentinel (§c§…) on screen.
_cite_literal(key, sup, _form) = isempty(strip(sup)) ? string("[@", key, "]") : string("[@", key, ", ", strip(sup), "]")

function _cite_link_emit(ctx)
    esc(s) = replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
    return (key, sup, _form) -> begin
        core = get(ctx.labels, String(key), String(key))
        inner = isempty(strip(sup)) ? core : string(core, ", ", strip(sup))
        text = ctx.numeric ? string("[", inner, "]") : string("(", inner, ")")
        href = isempty(ctx.anchor) ? "" : " href=\"#cell-$(esc(ctx.anchor))\""
        string("<a class=\"cite\"", href, " title=\"", esc(get(ctx.tips, String(key), String(key))),
               "\">", esc(text), "</a>")
    end
end
# Live-citation context from the notebook's :bibliography cells — the anchor cell, per-key tooltips,
# per-key in-text label (a number for numeric styles, an author-year string otherwise), the
# numeric flag, and (numeric only) the card numbers. `nothing` when the notebook has no bibliography.
function _bib_link_ctx(nb)
    bi = bibliography_index(nb.report, dirname(abspath(nb.path)))
    isempty(bi) && return nothing
    idx = findfirst(c -> :bibliography in c.flags, nb.report.cells)
    anchor = idx === nothing ? "" : nb.report.cells[idx].id
    tips = Dict{String,String}(e.key => strip(join(filter(!isempty, [e.author, e.title]), " · ")) for e in bi)
    numeric = _is_numeric_style(get(nb.report.meta, "bibstyle", "ieee"))
    numbers = numeric ? citation_numbers(nb.report, Set(e.key for e in bi)) : Dict{String,Int}()
    labels = numeric ? Dict{String,String}(k => string(v) for (k, v) in numbers) :
                       Dict{String,String}(e.key => _author_year_label(e.author, e.year) for e in bi)
    return (anchor = anchor, tips = tips, labels = labels, numeric = numeric, numbers = numbers)
end
_bib_keys_meta(ctx) = ctx === nothing ? nothing : [Dict("key" => k, "label" => v) for (k, v) in ctx.tips]

function cell_json(c::Cell, bindref::Dict{String,Tuple{Cell,BindSpec}} = Dict{String,Tuple{Cell,BindSpec}}(),
                   hostednames::Dict{String,Vector{String}} = Dict{String,Vector{String}}();
                   multidef::Set{String} = Set{String}(), nbid::AbstractString = "",
                   nbdir::AbstractString = "", cited::Set{String} = Set{String}(),
                   bibctx = nothing, figidx = nothing, report = nothing,
                   backref::Dict{String,Vector{String}} = Dict{String,Vector{String}}())
    fignums = figidx === nothing ? Dict{String,Int}() : figidx.numbers
    figrefs = figidx === nothing ? Dict{String,Tuple{Int,String}}() : figidx.labels
    # Markdown citations → links to the bibliography cell (per bibstyle), and `[@fig:label]` → a live
    # "Figure N" link that jumps to the figure. Skips bibliography/caption cells' own bodies.
    _mdsrc = (c.kind == MARKDOWN && !(:bibliography in c.flags) && (bibctx !== nothing || !isempty(figrefs))) ?
        _rewrite_citations(c.source, bibctx === nothing ? Set{String}() : Set(keys(bibctx.tips));
                           emit = bibctx === nothing ? _cite_literal : _cite_link_emit(bibctx),
                           figrefs = figrefs, figemit = _fig_link_emit) : c.source
    d = Dict{String,Any}(
        "id"      => c.id,
        "kind"    => c.kind == MARKDOWN ? "md" : "code",
        "source"  => c.source,
        # Canonical per-cell content hash (the SAME SHA the history uses) — a version token the browser
        # keys reconcile off, instead of a fuzzy string comparison that can drift.
        "hash"    => SlateHistory._sha(c.source),
        "state"   => lowercase(string(c.state)),
        "output"  => _externalize_blobs(nbid, c.kind == MARKDOWN ? markdown_html(_mdsrc, c.interp) : output_html(c)),
        "echarts" => c.kind == MARKDOWN ? _md_interp_echarts(c) : _echarts_specs(c),
        "tables" => c.kind == MARKDOWN ? _md_interp_tables(c) : _table_specs(c),
        "animations" => c.kind == MARKDOWN ? Any[] : _animation_specs(c, nbid),
        "assets" => c.kind == MARKDOWN ? Any[] : _asset_specs(c, nbid),
        "duration" => c.output === nothing ? nothing : round(c.output.duration_ms; digits = 1),
        "deps"    => collect(c.deps),
        # Top-level names this cell defines — drives ⌘-click go-to-definition in the editor. A name the
        # cell only MUTATES (`prog[] = …`) isn't defined here, so it's excluded (go-to-def lands on the definer).
        "defs"    => c.kind == CODE ? sort!(String[string(w) for w in cell_definitions(c)]) : String[],
    )
    # Durable-cache badge. The RUNTIME verdict wins ("restored" = came back from the memo cache without
    # recompute, "stored" = computed then persisted, "handle" = a live handle, "uncacheable" = keyed +
    # expensive but the store failed — with a reason). When a cell has no runtime verdict (ran cheap, or
    # not yet run), fall back to a STATIC classification (`_memo_status`, needs the dep graph) so a
    # structurally-uncacheable cell (nocache/volatile/`using` barrier/impure upstream) still explains
    # itself. "cacheable"/"" ⇒ no badge. Drives the cell cache badge + the run-status restore counter
    # (a fast restore burst otherwise reads as a glitch), mirroring the DAG's cache indicator.
    memostate = ""; memowhy = ""    # computed once, shared by the cell badge (here) AND the DAG stats card (below)
    if c.kind == CODE
        o = c.output
        rt = o === nothing ? "" : o.memo
        memostate, memowhy = rt in ("restored", "stored", "handle", "uncacheable") ? (rt, o.memo_why) :
                             report !== nothing ? ReportEngine._memo_status(report, c) : ("", "")
        (memostate == "handle" && isempty(memowhy)) && (memowhy = "produces a live handle (DB/socket/file) — tag `resource`")
        memostate in ("restored", "stored", "handle", "uncacheable") || (memostate = "")   # "cacheable"/"" ⇒ no badge
        if !isempty(memostate)
            d["memo"] = memostate
            isempty(memowhy) || (d["memoWhy"] = memowhy)
        end
    end
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
    if :caption in c.flags                               # figure caption — numbered, rendered under its figure
        d["roleCaption"] = true
        if haskey(fignums, c.id)
            d["figNum"] = fignums[c.id]
            d["output"] = "<span class=\"figlabel\">Figure " * string(fignums[c.id]) * ".</span> " * d["output"]
        end
    end
    if :bibliography in c.flags                          # bibliography / references
        d["roleBib"] = true
        file, n, es = bib_cell_info(c, nbdir)            # external file (or "") + entry count + keys
        d["bibFile"] = file
        d["bibCount"] = n
        d["bibKeys"] = [Dict("key" => e.key, "title" => e.title, "author" => e.author) for e in es]
        nums = bibctx === nothing ? Dict{String,Int}() : bibctx.numbers
        d["output"] = _bib_card_html(file, n, es, nbid, cited, nums)  # card instead of raw BibTeX
    end
    # All user-facing tags (known behaviour tags + free-form) for the cell-header tag editor;
    # `:opaque` is inferred each eval, not a user tag, so it's excluded from tags — but shipped
    # as its own field: an opaque cell (parse error / barrier expr) has FABRICATED barrier deps
    # (all prior cells + all later cells depend on it), and the DAG must not draw those as real
    # dataflow edges.
    (:opaque in c.flags) && (d["opaque"] = true)
    d["tags"] = sort!(String[string(f) for f in c.flags if f !== :opaque])
    # Declared cell EFFECTS (the code→Slate channel): a compact list for the effect chip + the
    # cell-metadata popup — what the cell announced it did to Slate (e.g. a everywhere op registration),
    # which names it registered, and the statement that did it (deparse line-markers stripped for display).
    if c.output !== nothing && !isempty(c.output.effects)
        d["effects"] = [Dict{String,Any}(
            "kind"  => (hasproperty(e, :kind) ? String(string(e.kind)) : ""),
            "names" => String[string(n) for n in (hasproperty(e, :names) ? e.names : Symbol[])],
            "stmt"  => first(strip(replace(String(hasproperty(e, :stmt_src) ? e.stmt_src : ""),
                                           r"#=.*?=#" => "")), 200))
            for e in c.output.effects]
    end
    # Live run statistics (session-scoped, keyed by notebook id) — the DAG heat map + stats card.
    # Only present once the cell has completed at least one run this session.
    if !isempty(nbid)
        st = _cell_stats_json(nbid, c.id)
        if st !== nothing
            # Show the SAME durable-cache verdict on the DAG stats card as the cell badge — including the
            # STATIC `uncacheable` cases that the runtime `last_memo` alone doesn't record (nocache/
            # volatile/impure-upstream), so the two surfaces never disagree.
            st["memo"] = memostate
            isempty(memowhy) || (st["memoWhy"] = memowhy)
            d["stats"] = st
        end
    end
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
        dup = sort!(String[string(w) for w in cell_definitions(c) if string(w) in multidef])
        isempty(dup) || (d["dupdefs"] = dup)
    end
    # Names this cell reads at top level ABOVE their definition (the `backref` ordering footgun) —
    # flagged on the READER; the popup names the definer below so one click fixes the order.
    if !isempty(backref)
        br = sort!(String[name for (name, rw) in backref if first(rw) == c.id])
        isempty(br) || (d["backrefs"] = br)
    end
    # User-asserted effect edges (`needs=` tag), shipped parsed: the DAG styles these manual
    # edges dashed, and the client flags entries that resolve to no EARLIER CODE cell (dangling
    # after a delete/move) — the engine ignores those, and silence would mask the lost edge.
    nd = ReportEngine._manual_needs(c.flags)
    isempty(nd) || (d["needs"] = nd)
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
        # Push the value to the kernel the DEFINING cell runs on. A region-tagged `@bind` cell lives on
        # its region kernel, so the control must set the value THERE — else the region never sees the
        # slider move (and same-side readers like a remote plot re-run with the stale value). A local
        # bind cell keeps the main kernel; a cross-side reader picks the value up via boundary transfer.
        side = _region_active(nb) ? _cell_side(nb, cell) : ""
        bk = nb.kernel
        if !isempty(side)
            bk = _side_kernel!(nb, side)
            try; ReportEngine.prepare!(bk, nb.report); catch e
                ReportEngine._rlog("bind: region kernel prepare failed: " * first(sprint(showerror, e), 120))
            end
        end
        set_bind_value!(nb.report, cell, Symbol(name), value, bk)
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
            j === nothing && continue
            ReportEngine.restale!(nb.report.cells[j])
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

# One worker entry (side/host/status + latest telemetry) for the topbar pills. `side==""` is the main
# kernel; a region side is its own worker. `host` is the remote host or "" (local/in-process).
function _worker_entry(nb::LiveNotebook, side::AbstractString, k)
    st = _kernel_status(k)
    host = try; (k isa ReportEngine.GateKernel && k.target isa ReportEngine.RemoteTarget) ?
                String(k.target.ssh_host) : ""; catch; ""; end
    d = Dict{String,Any}("side" => String(side), "host" => host,
                         "kind" => st["kind"], "port" => st["port"], "connected" => st["connected"])
    # Latest telemetry (cpu/rss/host cpu/mem) → a JSON string the pill popup parses. Fully guarded: a
    # telemetry hiccup must NEVER throw here, or it takes the whole `state_json` (the notebook) down.
    if k isa ReportEngine.GateKernel
        try
            cn = k.conn === nothing ? "" : k.conn.name
            s = isempty(cn) ? nothing : ReportEngine.kernel_stats(cn)   # (latest::NamedTuple, history)
            s === nothing || (d["stats"] = JSON.json(s.latest))
        catch
        end
    end
    # Graduated health for the pill (green → muted-yellow "degraded" → amber "connecting/disconnected") + a
    # note saying WHY — surfacing what the liveness supervisor already knows so an unwell pill isn't a mystery.
    # Applies to EVERY worker, main included (the main/local worker is treated like any other pill now).
    if k isa ReportEngine.GateKernel
        remote = k.target isa ReportEngine.RemoteTarget || k.remote
        since = remote ? get(_KERNEL_UNRESPONSIVE_SINCE, k, nothing) : nothing   # liveness clock is remote-only
        if k.conn === nothing
            d["status"] = k.redial_hold ? "disconnected" : "connecting"
            d["note"]   = k.redial_hold ?
                "worker stopped responding — press ▶ or re-run to reconnect" : "starting up…"
        elseif since !== nothing
            el = round(Int, time() - something(since, time()))
            d["status"] = "degraded"
            d["note"]   = "no liveness reply for $(el)s — auto-drops & reconnects at $(round(Int, _DEAD_WIRE_GRACE))s"
        else
            d["status"] = "ok"
        end
    else
        d["status"] = "ok"   # in-process kernel — always up
    end
    return d
end

# The notebook's ACTIVE workers: the main kernel plus every region kernel currently spawned for it.
function _workers_json(nb::LiveNotebook)
    out = Any[_worker_entry(nb, "", nb.kernel)]
    regs = lock(_REGION_LOCK) do
        [(String(side), k) for ((id, side), k) in _REGION_KERNELS if id == nb.id]
    end
    for (side, k) in sort(regs; by = first)
        push!(out, _worker_entry(nb, side, k))
    end
    return out
end

# The active region kernel for `side` WITHOUT spawning one (unlike `_side_kernel!`); `nothing` if none.
_region_kernel_if_active(nb::LiveNotebook, side::AbstractString) =
    lock(_REGION_LOCK) do; get(_REGION_KERNELS, (nb.id, String(side)), nothing); end

# The tail of a worker's log (+ latest telemetry) for the worker/region status popup. `side==""` = main.
function _worker_log(nb::LiveNotebook, side::AbstractString, lines::Int)
    k = isempty(side) ? nb.kernel : _region_kernel_if_active(nb, side)
    k === nothing && return Dict{String,Any}("side" => side, "log" => "", "connected" => false,
                                             "note" => "no active worker for this region")
    log = try; ReportEngine.worker_log_tail(k; lines = lines)
          catch e; "log unavailable: " * first(sprint(showerror, e), 160); end
    return merge(_worker_entry(nb, side, k), Dict{String,Any}("log" => log))
end

function state_json(nb::LiveNotebook)
    meta = Dict{String,Any}(
        "id" => nb.id, "title" => nb.report.title, "path" => abspath(nb.path),
        "version" => nb.version, "worker" => _kernel_status(nb.kernel),
        # On-disk mtime (unix seconds) — lets the reconcile modal say when the saved version was written.
        "savedAt" => (try; round(Int, mtime(abspath(nb.path))); catch; 0; end))
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
    meta["agentModel"] = get(nb.report.meta, "agentmodel", "")               # per-notebook agent-model override ("" = browser global)
    meta["agentAvailable"] = _agent_available()   # false on a standalone hub (slate --own / serve_notebook) → the UI disables agent chat
    meta["publishRepo"] = get(nb.report.meta, "publishrepo", "")             # last GitHub publish target (owner/name); pre-fills the dialog
    meta["publishSlug"] = get(nb.report.meta, "publishslug", "")             # last publish slug ("" = home / default)
    meta["remoteWorker"] = get(nb.report.meta, "remoteworker", "")           # "port,stream" if running on a remote worker
    # Run-location (three layers → one effective value; see _effective_runon). The toolbar picker binds to these.
    meta["runLocation"] = _effective_runon(nb.report)                        # effective "host[,transport]" ("" = local)
    meta["runLocationSource"] = _runon_source(nb.report)                     # session | notebook | global | default(local)
    meta["runLocationNotebook"] = get(nb.report.meta, "runon", "")           # the DURABLE footer override ("" = none)
    meta["runLocationSession"] = get(nb.report.meta, "runon_session", "")    # the runtime session override ("" = none)
    meta["runLocationGlobal"] = RUNON_DEFAULT[]                              # the machine global default ("" = local)
    meta["regions"] = _regions_json(nb)                                     # declared per-cell destinations (regionon footer) → tag editor + DAG zones
    meta["health"] = _health_json(nb)                                       # watchdog status + alerts (stall/runaway) → health panel
    meta["workers"] = _workers_json(nb)                                     # ACTIVE workers (main + each region) → topbar pills + log/status popup
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
        # "run" = a normal open whose initial full run is happening in the background;
        # "remote" = bringing up a remote worker (provision + connect) before any cell can run.
        meta["hydratingKind"] = get(nb.report.meta, "hydratingKind",
                                    haskey(nb.report.meta, "preview") ? "env" : "run")
        haskey(nb.report.meta, "hydratingHost") && (meta["hydratingHost"] = nb.report.meta["hydratingHost"])
        return meta
    end
    bindref, hostednames = _bind_index(nb.report)
    md = Set{String}(get(nb.report.meta, "multidef", String[]))   # names defined in 2+ cells → per-cell flag
    meta["multidefCells"] = get(nb.report.meta, "multidef_cells", Dict{String,Vector{String}}())   # name → defining cells (popup)
    br = get(nb.report.meta, "backref", Dict{String,Vector{String}}())   # name → [reader, definer] (ordering footgun)
    meta["backrefCells"] = br
    nbdir = dirname(abspath(nb.path))
    cited = cited_citation_keys(nb.report)   # keys referenced in prose → adaptive references card
    bibctx = _bib_link_ctx(nb)   # live citation links (styled per bibstyle) → the bibliography cell
    figidx = figure_index(nb.report)            # caption numbering + [@fig:] cross-ref labels
    meta["cells"] = _render_cells(nb; bindref = bindref, hostednames = hostednames, md = md,
        nbdir = nbdir, cited = cited, bibctx = bibctx, figidx = figidx, br = br)
    # In-memory scratchpad cells (slate.eval) — a separate panel, never part of the document flow.
    isempty(nb.scratch) || (meta["scratch"] = [cell_json(c) for c in nb.scratch])
    # Citation keys defined across all :bibliography cells — drives `[@`-autocomplete in markdown.
    let bk = _bib_keys_meta(bibctx); bk === nothing || (meta["bibKeys"] = bk); end
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
        if cells[idx].source != String(source)
            _snapshot!(nb)
            _preempt_superseded!(nb, (cells[idx],))   # a RUNNING old-source eval is now worthless
        end
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
                frc = get!(Set{String}, _FORCE_RUN, nb.id)
                for did in dependents_of(nb.report, Set([id]))   # closure includes `id` itself
                    j = findfirst(c -> c.id == did, nb.report.cells)
                    j === nothing && continue
                    c = nb.report.cells[j]
                    # A locked dependent stays frozen against this cascade too — only its OWN
                    # ▶ (did == id) may re-run it, so the played cell itself bypasses the guard.
                    ok = did == id ? (c.state = STALE; true) : ReportEngine.restale!(c)
                    ok || continue
                    # ▶ means "actually re-evaluate" — for the WHOLE cascade, not just this cell.
                    # The memo key digests upstream SOURCES, so if the played cell is impure (a data
                    # fetch — the main reason to press ▶), its dependents' keys don't change and a
                    # restore would serve results computed from the PREVIOUS data. Force them all.
                    push!(frc, String(did))
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

