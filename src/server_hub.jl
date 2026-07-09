# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Hub: one server, one port, many notebooks ────────────────────────────────
#
# Notebooks live in a registry keyed by a unique hub `id`. Routes are
# notebook-scoped (`/n/<id>` SPA, `/api/<id>/…`, `/api/<id>/events` SSE); `/` is
# an index/switcher page. One HTTP 2.0 server replaces the old one-port-per-file.
mutable struct Hub
    notebooks::Dict{String,LiveNotebook}
    server::Any
    host::String
    port::Int
    lock::ReentrantLock
end

_hub_url(h::Hub) = "http://$(h.host):$(h.port)"
_esc(s) = replace(String(s), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;")

# A unique id from the filename (deduped against the registry).
function _unique_id(h::Hub, path::AbstractString)
    base = replace(splitext(basename(path))[1], r"[^A-Za-z0-9]" => "_")
    isempty(base) && (base = "nb")
    id = base; i = 1
    while haskey(h.notebooks, id); i += 1; id = "$(base)_$i"; end
    return id
end

_notebooks_json(h::Hub) = lock(h.lock) do
    nbs = [begin
        cs = nb.report.cells
        Dict("id" => nb.id, "title" => nb.report.title, "path" => abspath(nb.path),
             "cells" => length(cs),
             "code" => count(c -> c.kind == CODE, cs),
             "md" => count(c -> c.kind == MARKDOWN, cs),
             "errors" => count(c -> c.state == ERRORED, cs),
             "stale" => count(c -> c.state == STALE, cs),
             "running" => count(c -> c.state == RUNNING, cs),
             "binds" => sum(c -> length(c.binds), cs; init = 0),
             "compute_ms" => sum(c -> c.output === nothing ? 0.0 : c.output.duration_ms, cs; init = 0.0),
             "mtime" => _file_mtime(nb.path),
             "worker" => _worker_label(nb), "port" => _worker_port(nb),
             "runLocation" => _worker_location(nb))
     end for nb in values(h.notebooks)]
    # Most-recently-edited first (the dict's iteration order is otherwise arbitrary).
    sort!(nbs; by = d -> d["mtime"], rev = true)
end

# A short "worker :port" tag for the index, when a notebook runs on a gate worker.
_worker_label(nb::LiveNotebook) =
    nb.kernel isa GateKernel && nb.kernel.port != 0 ? " · worker&nbsp;:$(nb.kernel.port)" : ""

# The gate worker's port (0 / nothing when in-process) — for the index card's running dot.
_worker_port(nb::LiveNotebook) =
    nb.kernel isa GateKernel && nb.kernel.port != 0 ? nb.kernel.port : nothing

# Where this notebook's worker actually runs — "" (local) or the ssh host — for the index card badge.
_worker_location(nb::LiveNotebook) =
    (nb.kernel isa GateKernel && nb.kernel.target isa ReportEngine.RemoteTarget) ? nb.kernel.target.ssh_host : ""

# File mtime as unix seconds (the index renders it as relative "edited Nm ago"); 0 if absent.
_file_mtime(path::AbstractString) = try; round(Int, mtime(abspath(path))); catch; 0; end


# `frame-ancestors 'none'` / X-Frame-Options: DENY — the notebook UI must never be framed by another
# page (clickjacking: the origin guard allows same-origin clicks, so a redressed frame could drive it).
# A stricter CSP is deliberately NOT set: cell output is allowed to render arbitrary HTML/JS by design.
const _FRAME_GUARD = ["X-Frame-Options" => "DENY", "Content-Security-Policy" => "frame-ancestors 'none'"]
_html(body) = HTTP.Response(200, ["Content-Type" => "text/html", "Cache-Control" => "no-store", _FRAME_GUARD...], body)
_asset(body, ctype) = HTTP.Response(200, ["Content-Type" => ctype, "Cache-Control" => "no-store", _FRAME_GUARD...], body)

# ── Front-end vendor cache (offline support) ──────────────────────────────────
# Third-party assets (CodeMirror, ECharts, KaTeX, Preact/signals/htm) are pinned in
# assets/vendor.json (package → version + base URL) and served from /assets/vendor/<pkg>/<sub>.
# Each file is fetched from `<base><sub>` on first request, cached OUTSIDE the repo, and
# served from disk after — so the notebook works offline once warm. Bump a version in
# vendor.json to upgrade (new files re-download under a version-keyed cache path).
const _VENDOR_JSON = joinpath(@__DIR__, "assets", "vendor.json")
const _VENDOR_CACHE = get(ENV, "KAIMONSLATE_ASSET_CACHE",
                          joinpath(get(DEPOT_PATH, 1, joinpath(homedir(), ".julia")), "scratchspaces", "kaimonslate-assets"))
const _VENDOR_LOCK = ReentrantLock()

function _vendor_ctype(p)
    e = lowercase(splitext(p)[2])
    return e in (".js", ".mjs")   ? "application/javascript; charset=utf-8" :
           e == ".css"            ? "text/css; charset=utf-8" :
           e == ".woff2"          ? "font/woff2" :
           e == ".woff"           ? "font/woff" :
           e == ".ttf"            ? "font/ttf" :
           e in (".map", ".json") ? "application/json; charset=utf-8" :
           "application/octet-stream"
end

# Resolve `<pkg>/<sub>` to a cached local file, fetching from the pinned base URL on first
# request (atomic write under a lock). Returns the path, or nothing on bad input / unknown
# package / fetch failure. The version is part of the cache path, so upgrades never collide.
function _vendor_file(pkg::AbstractString, sub::AbstractString)
    (isempty(sub) || occursin("..", sub) || startswith(sub, "/")) && return nothing
    man = try; JSON.parsefile(_VENDOR_JSON); catch; return nothing; end
    entry = get(man, pkg, nothing)
    (entry isa AbstractDict && haskey(entry, "version") && haskey(entry, "base")) || return nothing
    ver = String(entry["version"]); base = replace(String(entry["base"]), "{version}" => ver)
    dest = joinpath(_VENDOR_CACHE, pkg, ver, sub)
    isfile(dest) && return dest
    return lock(_VENDOR_LOCK) do
        isfile(dest) && return dest
        mkpath(dirname(dest))
        tmp = dest * ".part"
        try
            r = HTTP.get(base * sub; redirect = true, retry = false, status_exception = true)
            write(tmp, r.body); mv(tmp, dest; force = true); dest
        catch
            rm(tmp; force = true); nothing
        end
    end
end

# ── Persisted open-notebook registry (survive a server restart) ───────────────
# The in-memory hub registry is empty after a restart, so a browser polling
# /api/<id>/… gets a 404 and can't reconnect (and the watcher/worker are gone).
# We persist {id => abspath} to a small per-port file on every open/close, and
# LAZILY re-open a notebook the first time a request arrives for a known-but-
# unloaded id — under its ORIGINAL id, so the browser's existing /n/<id> URL
# resolves again and it resyncs automatically (no page reload, edits preserved).
const _REOPEN_LOCK = ReentrantLock()
_registry_file(h::Hub) = joinpath(_VENDOR_CACHE, "open-notebooks-$(h.port).json")

# Snapshot the current registry to disk. Reentrant-lock safe (callers may already hold h.lock).
function _persist_registry!(h::Hub)
    data = lock(h.lock) do
        Dict{String,String}(id => abspath(nb.path) for (id, nb) in h.notebooks)
    end
    try
        f = _registry_file(h); mkpath(dirname(f)); write(f, JSON.json(data))
    catch
    end
    return nothing
end

# Re-register a notebook by its persisted id after a restart. Returns the (re)loaded
# LiveNotebook, or nothing if the id isn't persisted / its file is gone. Serialized via
# _REOPEN_LOCK with a double-check, so concurrent probes (poll + SSE) can't double-load;
# the heavy load happens OUTSIDE h.lock so it doesn't block every other request.
function _reopen_persisted!(h::Hub, id::AbstractString)
    cur = lock(h.lock) do; get(h.notebooks, id, nothing); end
    cur === nothing || return cur
    path = try
        get(JSON.parsefile(_registry_file(h)), id, nothing)
    catch
        nothing
    end
    (path isa AbstractString && isfile(path)) || return nothing
    return lock(_REOPEN_LOCK) do
        again = lock(h.lock) do; get(h.notebooks, id, nothing); end
        again === nothing || return again
        nb = try
            load_notebook(abspath(path); id = id)
        catch err
            @warn "Kaimon Slate: failed to re-open notebook after restart" id path exception = err
            return nothing
        end
        lock(h.lock) do; h.notebooks[id] = nb; end
        _start_watcher!(nb)
        _persist_registry!(h)
        @info "Kaimon Slate: re-opened notebook after restart" id path
        return nb
    end
end

# Run `f(nb)` for the notebook named by the request's `id` path param. If the id isn't
# loaded (e.g. the server restarted), try to re-open it from the persisted registry first.
function _withnb(h::Hub, req, f)
    id = HTTP.getparam(req, "id")
    nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
    nb === nothing && (nb = _reopen_persisted!(h, id))
    nb === nothing && return HTTP.Response(404, "no such notebook: $id")
    try
        return f(nb)
    catch e
        # A handler that throws used to surface as a BARE 500 with nothing logged. The extension log
        # keeps only the FIRST LINE of an @error message (and not its `exception=` kwarg), so flatten
        # the error + backtrace to ONE line. Server-side only — the browser gets a GENERIC 500 (no leak).
        detail = replace(sprint(showerror, e, catch_backtrace()), r"\s*\n\s*" => " ⏎ ")
        @error "Kaimon Slate: request handler error [$(String(req.method)) $(String(req.target))] nb=$id :: $detail"
        return HTTP.Response(500, "internal error")
    end
end

# Filesystem path completions for the open box. Expands a leading `~`, lists the
# directory implied by the typed prefix, and returns full suggestions that PRESERVE
# the user's `~` (directories suffixed `/`). Dirs and `.jl` files surface first;
# dotfiles are hidden unless the prefix itself starts with a dot.
# Path completions for the open box's file-picker dropdown. Returns `(items, truncated)` —
# the (scrollable) dropdown shows every match in a directory; `limit` is a high guard against
# pathological dirs (node_modules, …), and `truncated` lets the UI say "keep typing to filter"
# rather than silently dropping entries. Directories sort first, then `.jl`, then the rest.
function _path_completions(q::AbstractString; limit::Int = 500)
    s = String(q)
    # Separator conventions differ by OS: accept BOTH `/` and `\` on input (a pasted
    # Windows path arrives with `\`), and echo back completions in whichever separator
    # the user is already typing — falling back to the host's native one.
    nativesep = Sys.iswindows() ? '\\' : '/'
    isempty(s) && (s = "~" * nativesep)
    (s == "~") && return (items = ["~" * nativesep], truncated = false)
    sepi   = findlast(c -> c == '/' || c == '\\', s)
    sep    = sepi === nothing ? nativesep : s[sepi]
    prefix = sepi === nothing ? "" : s[1:sepi]
    leaf   = sepi === nothing ? s : s[nextind(s, sepi):end]
    # `expanduser`/`readdir` can throw on a malformed prefix (e.g. a `~user` that doesn't
    # exist, or a foreign-separator path on this host) — treat any failure as "no matches"
    # so a stray keystroke never 500s the open box.
    base = pwd()
    entries = try
        base = isempty(prefix) ? pwd() : expanduser(prefix)
        isdir(base) || return (items = String[], truncated = false)
        readdir(base)
    catch
        return (items = String[], truncated = false)
    end
    keep = String[]
    for e in entries
        startswith(e, leaf) || continue
        (startswith(e, ".") && !startswith(leaf, ".")) && continue
        full = joinpath(base, e)
        push!(keep, isdir(full) ? string(prefix, e, sep) : string(prefix, e))
    end
    sort!(keep; by = p -> ((endswith(p, '/') || endswith(p, '\\')) ? 0 : (endswith(p, ".jl") ? 1 : 2), lowercase(p)))
    return (items = first(keep, limit), truncated = length(keep) > limit)
end

