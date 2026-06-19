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
    [Dict("id" => nb.id, "title" => nb.report.title, "path" => abspath(nb.path),
          "cells" => length(nb.report.cells), "worker" => _worker_label(nb))
     for nb in values(h.notebooks)]
end

# A short "worker :port" tag for the index, when a notebook runs on a gate worker.
_worker_label(nb::LiveNotebook) =
    nb.kernel isa GateKernel && nb.kernel.port != 0 ? " · worker&nbsp;:$(nb.kernel.port)" : ""


_html(body) = HTTP.Response(200, ["Content-Type" => "text/html", "Cache-Control" => "no-store"], body)
_asset(body, ctype) = HTTP.Response(200, ["Content-Type" => ctype, "Cache-Control" => "no-store"], body)

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

# Run `f(nb)` for the notebook named by the request's `id` path param, else 404.
function _withnb(h::Hub, req, f)
    id = HTTP.getparam(req, "id")
    nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
    nb === nothing && return HTTP.Response(404, "no such notebook: $id")
    return f(nb)
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
    isempty(s) && (s = "~/")
    s == "~" && return (items = ["~/"], truncated = false)
    slash = findlast('/', s)
    prefix = slash === nothing ? "" : s[1:slash]
    leaf   = slash === nothing ? s : s[nextind(s, slash):end]
    base   = isempty(prefix) ? pwd() : expanduser(prefix)
    isdir(base) || return (items = String[], truncated = false)
    entries = try
        readdir(base)
    catch
        return (items = String[], truncated = false)
    end
    keep = String[]
    for e in entries
        startswith(e, leaf) || continue
        (startswith(e, ".") && !startswith(leaf, ".")) && continue
        full = joinpath(base, e)
        push!(keep, isdir(full) ? prefix * e * "/" : prefix * e)
    end
    sort!(keep; by = p -> (endswith(p, "/") ? 0 : (endswith(p, ".jl") ? 1 : 2), lowercase(p)))
    return (items = first(keep, limit), truncated = length(keep) > limit)
end

