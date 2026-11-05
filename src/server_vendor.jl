# ── Front-end vendor cache (offline support) ──────────────────────────────────
# Third-party assets (KaTeX, ECharts, Preact/signals/htm, dagre, html2canvas) are pinned in
# assets/vendor.json (package → version, base URL, and the files used) and served from
# /assets/vendor/<pkg>@<version>/<sub>. Each file is fetched from `<base><sub>`, checked against the
# SHA-384 recorded for it in assets/vendor.lock.json, cached OUTSIDE the repo, and served from disk
# after, so the notebook works offline once warm. A file the lock doesn't list, or one whose bytes
# don't match, is refused.
#
# To upgrade: bump a `version` in vendor.json, run `KaimonSlate.NotebookServer.update_vendor_lock()`,
# and commit both files. The new files download under a version-keyed cache path; the old version's
# directory is removed by the next warm.
const _VENDOR_JSON = joinpath(@__DIR__, "assets", "vendor.json")
const _VENDOR_LOCK_JSON = joinpath(@__DIR__, "assets", "vendor.lock.json")
const _VENDOR_CACHE = get(ENV, "KAIMONSLATE_ASSET_CACHE",
                          joinpath(get(DEPOT_PATH, 1, joinpath(homedir(), ".julia")), "scratchspaces", "kaimonslate-assets"))
const _VENDOR_LOCK = ReentrantLock()

_vendor_ctype(p) = site_content_type(String(p))   # serve/mime_types.jl

_vendor_manifest() = try; JSON.parsefile(_VENDOR_JSON); catch; Dict{String,Any}(); end
_vendor_lockfile() = try; JSON.parsefile(_VENDOR_LOCK_JSON); catch; Dict{String,Any}(); end

# The packages vendor.json pins (its other keys are comments).
_vendor_packages(man = _vendor_manifest()) =
    sort!([k for (k, e) in man if e isa AbstractDict && haskey(e, "version") && haskey(e, "base")])

# The version vendor.json pins for `pkg`, or "" for a package it doesn't list.
function _vendor_version(pkg::AbstractString, man = _vendor_manifest())
    entry = get(man, pkg, nothing)
    return entry isa AbstractDict && haskey(entry, "version") ? String(entry["version"]) : ""
end

# The CDN directory `pkg`'s files come from: `base` with `{version}` substituted.
_vendor_base(pkg::AbstractString, man = _vendor_manifest()) =
    replace(String(man[pkg]["base"]), "{version}" => _vendor_version(pkg, man))

# The subresource-integrity string of `bytes`, the form the lock records and `integrity=` takes.
_vendor_sri(bytes::AbstractVector{UInt8}) = "sha384-" * Base64.base64encode(SHA.sha384(bytes))

# The SRI the lock records for `pkg`'s file `sub` at `ver`, or `nothing` if it records none, for a
# file the package doesn't use, or for a version the lock wasn't generated for.
function _vendor_locked_sri(pkg::AbstractString, sub::AbstractString, ver::AbstractString = _vendor_version(pkg),
                            lk = _vendor_lockfile())
    entry = get(lk, pkg, nothing)
    (entry isa AbstractDict && get(entry, "version", nothing) == ver) || return nothing
    h = get(get(entry, "files", Dict()), sub, nothing)
    return h isa AbstractString ? String(h) : nothing
end

# A page's `/assets/vendor/<pkg>/…` URLs with the pinned version in them, `/assets/vendor/<pkg>@<ver>/…`.
# The files are served as immutable under such a URL, so a browser keeps them until a bump in
# vendor.json changes the URL. (A file referencing its neighbours by relative path, like KaTeX's CSS
# and its fonts, carries the version along.)
function _vendor_versioned(body::AbstractString)
    out = String(body)
    occursin("/assets/vendor/", out) || return out
    man = _vendor_manifest()
    for pkg in _vendor_packages(man)
        out = replace(out, "/assets/vendor/$pkg/" => "/assets/vendor/$pkg@$(_vendor_version(pkg, man))/")
    end
    return out
end
_vendor_versioned(body) = body

# Resolve `<pkg>/<sub>` to a cached local file, fetching it from the pinned base URL on first request
# (atomic write under a lock) and checking it against the lock. Returns the path, or `nothing` on bad
# input, a package or file the lock doesn't list, a fetch failure, or bytes that don't match.
function _vendor_file(pkg::AbstractString, sub::AbstractString)
    (isempty(sub) || occursin("..", sub) || startswith(sub, "/")) && return nothing
    man = _vendor_manifest()
    pkg in _vendor_packages(man) || return nothing
    ver = _vendor_version(pkg, man)
    sri = _vendor_locked_sri(pkg, sub, ver)
    sri === nothing && return nothing
    dest = joinpath(_VENDOR_CACHE, pkg, ver, sub)
    isfile(dest) && return dest
    return lock(_VENDOR_LOCK) do
        isfile(dest) && return dest
        mkpath(dirname(dest))
        tmp = dest * ".part"
        try
            # BOUNDED: a request that never returns would otherwise wedge its caller forever — and the
            # caller can be the notebook server answering a page request, or an export warming a few dozen
            # font files in a row. A slow/blocked CDN must degrade to "unresolved" (the caller then falls
            # back to a CDN url), never to a hang.
            r = HTTP.get(_vendor_base(pkg, man) * sub; redirect = true, retry = false, status_exception = true,
                         connect_timeout = 10, request_timeout = 60)
            if _vendor_sri(r.body) != sri
                @warn "KaimonSlate: a vendored file doesn't match its recorded hash; refusing it" pkg ver sub
                return nothing
            end
            write(tmp, r.body); mv(tmp, dest; force = true); dest
        catch
            rm(tmp; force = true); nothing
        end
    end
end

# The response for `/assets/vendor/<pkg>[@<ver>]/<sub>`. Immutable only under the pinned version's URL:
# a bare path, or one naming another version, gets the pinned file too but must be re-checked, or a
# browser would keep it past a bump. The ETag is the file's hash, so re-checking costs a 304.
function _vendor_response(req::HTTP.Request, pkg::AbstractString, ver::AbstractString, sub::AbstractString)
    f = _vendor_file(pkg, sub)
    f === nothing && return HTTP.Response(404, "vendor asset unavailable (offline & uncached, or not in the lock?)")
    etag = "\"" * something(_vendor_locked_sri(pkg, sub), "") * "\""
    cache = ver == _vendor_version(pkg) ? "public, max-age=31536000, immutable" : "no-cache"
    headers = ["Content-Type" => _vendor_ctype(sub), "Cache-Control" => cache, "ETag" => etag]
    HTTP.header(req, "If-None-Match") == etag && return HTTP.Response(304, headers)
    return HTTP.Response(200, headers, read(f))
end

# Fetch every file the lock lists for the pinned versions, re-fetching any cached copy whose bytes no
# longer match, then remove cached versions no longer pinned. Run in the background at hub start, so
# offline use has the whole set rather than only what some page happened to request. Each fetch is
# bounded and a failure leaves that file to be fetched on request, so this never blocks or throws.
function _vendor_warm!()
    man, lk = _vendor_manifest(), _vendor_lockfile()
    for pkg in _vendor_packages(man)
        ver = _vendor_version(pkg, man)
        entry = get(lk, pkg, nothing)
        if entry isa AbstractDict && get(entry, "version", nothing) == ver
            for (sub, sri) in get(entry, "files", Dict())
                dest = joinpath(_VENDOR_CACHE, pkg, ver, sub)
                isfile(dest) && _vendor_sri(read(dest)) != sri && rm(dest; force = true)
                _vendor_file(pkg, sub)
            end
        end
        _vendor_prune!(pkg, ver)
    end
end

# Remove the cached versions of `pkg` other than `keep`.
function _vendor_prune!(pkg::AbstractString, keep::AbstractString)
    dir = joinpath(_VENDOR_CACHE, pkg)
    isdir(dir) || return
    for v in readdir(dir)
        v == keep || rm(joinpath(dir, v); recursive = true, force = true)
    end
end

# A glob over a package's file paths: `*` within one directory, `**` across directories.
function _vendor_glob(g::AbstractString)
    parts = map(split(g, "**")) do p
        join((replace(q, r"([.+?^${}()|\[\]\\])" => s"\\\1") for q in split(p, '*')), "[^/]*")
    end
    return Regex("^" * join(parts, ".*") * "\$")
end

# The files of the npm package version `base` points into (a jsDelivr URL), as paths relative to `base`.
function _jsdelivr_files(base::AbstractString)
    m = match(r"cdn\.jsdelivr\.net/npm/((?:@[^/]+/)?[^@/]+)@([^/]+)/(.*)$", base)
    m === nothing && error("not a jsDelivr npm URL: $base")
    name, ver, prefix = m.captures
    r = HTTP.get("https://data.jsdelivr.com/v1/packages/npm/$name@$ver?structure=flat";
                 connect_timeout = 10, request_timeout = 60)
    names = [String(f["name"]) for f in JSON.parse(String(r.body))["files"]]
    lead = "/" * prefix
    return sort!([n[length(lead)+1:end] for n in names if startswith(n, lead)])
end

"""
    update_vendor_lock()

Write `assets/vendor.lock.json`: for each package in `assets/vendor.json`, every file of its pinned
version that matches the package's `files` patterns, with the SHA-384 of its bytes. Run it after
changing vendor.json and commit the result; the server refuses vendored files the lock doesn't list
or whose bytes don't match. Needs network.
"""
function update_vendor_lock(; path::AbstractString = _VENDOR_LOCK_JSON)
    man = _vendor_manifest()
    lines = String[]
    for pkg in _vendor_packages(man)
        ver, base = _vendor_version(pkg, man), _vendor_base(pkg, man)
        globs = _vendor_glob.(get(man[pkg], "files", String[]))
        subs = filter(s -> any(g -> occursin(g, s), globs), _jsdelivr_files(base))
        isempty(subs) && error("$pkg@$ver: no files match its `files` patterns in vendor.json")
        files = map(subs) do s
            r = HTTP.get(base * s; redirect = true, status_exception = true, connect_timeout = 10, request_timeout = 60)
            "      " * JSON.json(s) * ": " * JSON.json(_vendor_sri(r.body))
        end
        push!(lines, "  " * JSON.json(pkg) * ": {\n    \"version\": " * JSON.json(ver) * ",\n    \"files\": {\n" *
                     join(files, ",\n") * "\n    }\n  }")
    end
    write(path, "{\n" * join(lines, ",\n") * "\n}\n")
    return path
end
