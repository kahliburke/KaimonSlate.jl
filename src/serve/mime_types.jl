# The content type for each file extension a published site holds. One table for both servers: the
# hub (`_site_ctype`) and the standalone `slate_serve.jl`, which a deploy copies next to this file.
# A media element picks its decoder from the declared type, so a clip served as
# `application/octet-stream` does not play wherever the bytes are not content-sniffed.
const SITE_MIME_TYPES = Dict{String,String}(
    ".html" => "text/html; charset=utf-8", ".htm" => "text/html; charset=utf-8",
    ".js" => "text/javascript; charset=utf-8", ".mjs" => "text/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8", ".json" => "application/json; charset=utf-8",
    ".map" => "application/json",
    ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif",
    ".svg" => "image/svg+xml", ".webp" => "image/webp", ".avif" => "image/avif", ".bmp" => "image/bmp",
    ".ico" => "image/x-icon",
    ".mp4" => "video/mp4", ".m4v" => "video/x-m4v", ".webm" => "video/webm", ".mov" => "video/quicktime",
    ".ogv" => "video/ogg",
    ".mp3" => "audio/mpeg", ".wav" => "audio/wav", ".ogg" => "audio/ogg", ".oga" => "audio/ogg",
    ".opus" => "audio/ogg", ".flac" => "audio/flac", ".m4a" => "audio/mp4", ".aac" => "audio/mp4",
    ".pdf" => "application/pdf",
    ".woff" => "font/woff", ".woff2" => "font/woff2", ".ttf" => "font/ttf",
    ".wasm" => "application/wasm",              # WebAssembly.instantiateStreaming requires this exact type
    ".glb" => "model/gltf-binary", ".gltf" => "model/gltf+json",
    ".txt" => "text/plain; charset=utf-8", ".jl" => "text/plain; charset=utf-8",
    ".toml" => "text/plain; charset=utf-8", ".wgsl" => "text/plain; charset=utf-8",
)
site_content_type(p::AbstractString) = get(SITE_MIME_TYPES, lowercase(splitext(p)[2]), "application/octet-stream")
