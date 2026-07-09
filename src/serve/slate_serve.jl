# slate_serve.jl — minimal static file server for a published Slate site.
#
# The deployable half of the `rsync-serve` publish target: rsync drops the built
# site next to this script, which serves it over HTTP. Config via ENV so a systemd
# unit (or `julia slate_serve.jl`) needs no arguments:
#   SLATE_SERVE_ROOT  directory to serve            (default: ./site)
#   SLATE_SERVE_HOST  bind address                  (default: 127.0.0.1)
#   SLATE_SERVE_PORT  bind port                     (default: 8080)
#
# HTTP.jl (2.x) is the foundation deliberately: static today, but its router +
# WebSocket support are what a future "serve the live interactivity" mode needs.
using HTTP, Sockets

const ROOT = abspath(get(ENV, "SLATE_SERVE_ROOT", "site"))
const HOST = get(ENV, "SLATE_SERVE_HOST", "127.0.0.1")
const PORT = parse(Int, get(ENV, "SLATE_SERVE_PORT", "8080"))

const MIME_BY_EXT = Dict(
    ".html" => "text/html; charset=utf-8", ".htm" => "text/html; charset=utf-8",
    ".js" => "text/javascript; charset=utf-8", ".mjs" => "text/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8", ".json" => "application/json; charset=utf-8",
    ".map" => "application/json", ".svg" => "image/svg+xml", ".png" => "image/png",
    ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif",
    ".webp" => "image/webp", ".ico" => "image/x-icon", ".wasm" => "application/wasm",
    ".woff" => "font/woff", ".woff2" => "font/woff2", ".ttf" => "font/ttf",
    ".pdf" => "application/pdf", ".txt" => "text/plain; charset=utf-8",
    ".toml" => "text/plain; charset=utf-8", ".wgsl" => "text/plain; charset=utf-8",
)
content_type(p) = get(MIME_BY_EXT, lowercase(splitext(p)[2]), "application/octet-stream")

# Resolve a request target to a real file under ROOT (index.html for directories),
# rejecting path traversal. Returns the absolute file path or nothing.
function resolve_path(target::AbstractString)
    path = HTTP.URIs.unescapeuri(first(split(target, '?')))
    full = normpath(joinpath(ROOT, lstrip(path, '/')))
    (full == ROOT || startswith(full, ROOT * "/")) || return nothing   # traversal guard
    if isdir(full)
        idx = joinpath(full, "index.html")
        return isfile(idx) ? idx : nothing
    end
    return isfile(full) ? full : nothing
end

function handler(req::HTTP.Request)
    (req.method == "GET" || req.method == "HEAD") || return HTTP.Response(405, "method not allowed")
    file = resolve_path(req.target)
    file === nothing && return HTTP.Response(404, ["Content-Type" => "text/plain"], body = "404 not found")
    hdrs = ["Content-Type" => content_type(file)]
    body = req.method == "HEAD" ? UInt8[] : read(file)
    return HTTP.Response(200, hdrs; body = body)
end

@info "slate_serve starting" ROOT HOST PORT
HTTP.serve(handler, HOST, PORT)
