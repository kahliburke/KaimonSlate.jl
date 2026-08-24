# ── Extension catalog ─────────────────────────────────────────────────────────
# The data behind the Extensions gallery: which Slate extension packages exist, what they do, and
# whether this notebook already has them.
#
# A curated Julia registry is the trust boundary — an extension is listed because it was registered,
# and installing one is an ordinary `Pkg.add` from that registry. Presentation (descriptions,
# screenshots, starter snippets) is NOT in the registry: it's a `catalog.json` artifact published
# alongside it, so a depot that adds the registry doesn't pay for images it will never look at.
#
# Three sources, in descending order of richness, and the gallery works on all three:
#
#   published   the artifact — full presentation. Fetched once and cached; revalidated with an ETag.
#   cached      the last artifact we fetched. Serves the gallery unchanged while offline.
#   local       the registry clone in the depot. Names and versions only, no prose — but it is
#               always correct about what is installable, which is what the Install button needs.
#
# Nothing here mutates the environment. Installing goes through `notebook_pkg_op!` like every other
# package operation, and adding the registry itself is a separate, explicitly consented step
# (`catalog_add_registry!`) because a registry is depot-global, not notebook-local.

# The registry this catalog is for. Overridable so a fork, a mirror, or a test can point elsewhere;
# `catalog_url` likewise, since the artifact need not be hosted next to the registry.
const _DEFAULT_REGISTRY_NAME = "SlateRegistry"
const _DEFAULT_REGISTRY_URL  = "https://github.com/kahliburke/SlateRegistry"
const _DEFAULT_CATALOG_URL   = "https://kahliburke.github.io/SlateRegistry/catalog.json"

# How long a cached artifact is served without revalidating. A catalog changes when a package is
# registered — rarely — so this is about not hitting the network on every gallery open, not freshness.
const _CATALOG_TTL = 6 * 3600

# The optional `"catalog"` object in slate.json — `{"catalog": {"url": …, "registry": …,
# "registry_url": …}}` — installed at init by KaimonSlate (which owns slate.json; NotebookServer
# doesn't). Precedence per key mirrors the `"remote"` block: slate.json → `KAIMONSLATE_*` env →
# built-in default. Pointing all three elsewhere is how a fork or a mirror runs its own catalog.
const _CATALOG_CFG = Ref{Dict{String,Any}}(Dict{String,Any}())
function _ccfg(key::AbstractString, env::AbstractString, default::AbstractString)
    v = get(_CATALOG_CFG[], key, nothing)
    (v isa AbstractString && !isempty(v)) && return String(v)
    e = get(ENV, env, "")
    return isempty(e) ? default : e
end

catalog_registry_name() = _ccfg("registry",     "KAIMONSLATE_CATALOG_REGISTRY",     _DEFAULT_REGISTRY_NAME)
catalog_registry_url()  = _ccfg("registry_url", "KAIMONSLATE_CATALOG_REGISTRY_URL", _DEFAULT_REGISTRY_URL)
catalog_url()           = _ccfg("url",          "KAIMONSLATE_CATALOG_URL",          _DEFAULT_CATALOG_URL)
catalog_cache_dir()     = joinpath(SlateHome.cache_home(), "catalog")

_catalog_cache_file() = joinpath(catalog_cache_dir(), "catalog.json")
_catalog_etag_file()  = joinpath(catalog_cache_dir(), "catalog.etag")

# ── fetching the published artifact ───────────────────────────────────────────

"""
    fetch_catalog(; force = false) -> (entries, meta)

The published catalog, cached under the cache home and revalidated with an ETag. Returns the entry
vector and a meta `Dict` describing where it came from (`source`, `fetched`, `error`).

Never throws: a network failure falls back to the cache, and an absent cache falls back to the
local registry clone. The gallery must open even with no network, because the packages it lists may
already be installed.
"""
function fetch_catalog(; force::Bool = false)
    cache = _catalog_cache_file()
    age = isfile(cache) ? time() - mtime(cache) : Inf
    if !force && age < _CATALOG_TTL
        entries = _read_cached_catalog()
        entries === nothing || return (entries, Dict{String,Any}("source" => "cache", "age" => round(Int, age)))
    end
    fetched, err = _http_get_catalog(force ? "" : _read_etag())
    if fetched === :notmodified
        touch(cache)                                    # revalidated: restart the TTL, keep the bytes
        entries = _read_cached_catalog()
        entries === nothing || return (entries, Dict{String,Any}("source" => "cache", "age" => 0))
    elseif fetched isa Vector
        return (fetched, Dict{String,Any}("source" => "published", "url" => catalog_url()))
    end
    # Network failed (or returned something unusable) — degrade, loudest source first.
    entries = _read_cached_catalog()
    entries === nothing ||
        return (entries, Dict{String,Any}("source" => "cache", "age" => round(Int, age), "error" => err))
    return (local_registry_entries(), Dict{String,Any}("source" => "local", "error" => err))
end

"GET the catalog, honouring `etag`. Returns `(:notmodified | Vector | nothing, error_message)`."
function _http_get_catalog(etag::AbstractString)
    url = catalog_url()
    try
        headers = isempty(etag) ? Pair{String,String}[] : ["If-None-Match" => etag]
        r = HTTP.get(url; headers, status_exception = false, retry = false,
                     readtimeout = 20, connect_timeout = 10)
        r.status == 304 && return (:notmodified, "")
        r.status == 200 || return (nothing, "catalog fetch returned HTTP $(r.status)")
        body = String(r.body)
        entries = _parse_catalog(body)
        entries === nothing && return (nothing, "catalog at $url is not in the expected format")
        _write_cache!(body, HTTP.header(r, "ETag", ""))
        return (entries, "")
    catch e
        return (nothing, first(sprint(showerror, e), 200))
    end
end

"Validate and unwrap a catalog document. `nothing` when it isn't one — a 404 HTML page reaching the
cache would otherwise poison the gallery until the TTL expired."
function _parse_catalog(body::AbstractString)
    try
        doc = JSON.parse(body)
        # `AbstractDict`, not `Dict`: JSON.jl parses objects into its own `JSON.Object` type, and an
        # `isa Dict` test silently rejects every well-formed catalog — which degrades to the local
        # registry permanently and looks like "there are no extensions".
        doc isa AbstractDict || return nothing
        entries = get(doc, "entries", nothing)
        entries isa AbstractVector || return nothing
        all(e -> e isa AbstractDict && haskey(e, "name"), entries) || return nothing
        return _resolve_asset_urls!(Vector{Any}(entries))
    catch
        return nothing
    end
end

"""
    _resolve_asset_urls!(entries) -> entries

Make every image/video reference absolute, resolved against the catalog's own URL.

The build mirrors card imagery into the published artifact and records it as an artifact-relative
path (`assets/StarRating/ab12cd.png`) so the gallery loads everything from one origin. Left as-is,
the browser would resolve that against the NOTEBOOK's origin and 404. Entries that already carry an
absolute URL (an author hot-linking a CDN, or an asset too big to mirror) pass through untouched.
"""
function _resolve_asset_urls!(entries::AbstractVector)
    base = catalog_url()
    root = rsplit(base, '/'; limit = 2)[1] * "/"
    abs(u) = (u isa AbstractString && !isempty(u) && !occursin("://", u) && !startswith(u, "data:")) ?
             root * lstrip(u, '/') : u
    for e in entries
        e isa AbstractDict || continue
        haskey(e, "screenshots") && e["screenshots"] isa AbstractVector &&
            (e["screenshots"] = [abs(s) for s in e["screenshots"]])
        for k in ("video", "icon")
            v = get(e, k, nothing)
            # An emoji icon is not a path — only rewrite something that looks like one.
            (v isa AbstractString && occursin('/', v)) || continue
            e[k] = abs(v)
        end
    end
    return entries
end

function _write_cache!(body::AbstractString, etag::AbstractString)
    try
        mkpath(catalog_cache_dir())
        write(_catalog_cache_file(), body)
        isempty(etag) ? (isfile(_catalog_etag_file()) && rm(_catalog_etag_file(); force = true)) :
                        write(_catalog_etag_file(), etag)
    catch e
        @debug "catalog: could not write cache" exception = e
    end
end
_read_etag() = try; isfile(_catalog_etag_file()) ? strip(read(_catalog_etag_file(), String)) : ""; catch; ""; end
function _read_cached_catalog()
    try
        isfile(_catalog_cache_file()) || return nothing
        return _parse_catalog(read(_catalog_cache_file(), String))
    catch
        return nothing
    end
end

# ── local registry fallback ───────────────────────────────────────────────────

"""
    local_registry_entries() -> Vector

Catalog entries built from the extension registry's clone in the depot: name, uuid, version, repo.
No prose — that lives in the published artifact — but always accurate about what can be installed,
which is what makes this a usable fallback rather than an empty screen.
"""
function local_registry_entries()
    out = Any[]
    reg = _installed_extension_registry()
    reg === nothing && return out
    for (uuid, e) in reg.pkgs
        info = try; Pkg.Registry.registry_info(e); catch; nothing; end
        versions = info === nothing ? VersionNumber[] : sort!(collect(keys(info.version_info)))
        push!(out, Dict{String,Any}(
            "name"       => e.name,
            "uuid"       => string(uuid),
            "title"      => e.name,
            "version"    => isempty(versions) ? "" : string(last(versions)),
            "repo"       => info === nothing ? "" : something(info.repo, ""),
            "subdir"     => info === nothing ? "" : something(info.subdir, ""),
            "tier"       => "bare",
            "visibility" => "public",
            "sources"    => Dict{String,Any}(),
        ))
    end
    sort!(out; by = e -> lowercase(e["name"]))
    return out
end

"""
    _same_registry(reg, url) -> Bool

Does an installed registry point at `url`? Compared on `repo`, which is the only field carrying it:
a `RegistryInstance` has NO `url` field, and reading one throws a `FieldError` that surfaces to the
user as "could not add the registry". That failure appears only on a machine which does not already
have the registry — precisely the machine the add path exists for.

Trailing `.git`, a trailing slash and case are all ignored, so the spelling a user pastes matches.

`worker.jl` carries a mirror of this: it runs in the worker process and cannot import from here.
"""
function _same_registry(reg, url::AbstractString)
    repo = try; something(reg.repo, ""); catch; ""; end
    norm(s) = lowercase(rstrip(replace(String(s), r"\.git$" => ""), '/'))
    return !isempty(repo) && norm(repo) == norm(url)
end

"The extension registry among the reachable registries, or `nothing` if it isn't installed.
Matched on NAME or on repo url — a registry cloned under a different name is still the same one."
function _installed_extension_registry()
    want = catalog_registry_name()
    wanturl = catalog_registry_url()
    try
        for reg in Pkg.Registry.reachable_registries()
            (reg.name == want || _same_registry(reg, wanturl)) && return reg
        end
    catch e
        @debug "catalog: could not read registries" exception = e
    end
    return nothing
end

"Is the extension registry installed in this depot? The gallery shows a one-time consent prompt
when it isn't, since adding a registry is depot-global rather than notebook-local."
catalog_registry_installed() = _installed_extension_registry() !== nothing

# ── the view the gallery renders ──────────────────────────────────────────────

"""
    catalog_view(nb; force = false) -> Dict

The full gallery payload: every catalog entry annotated with this notebook's state
(`installed`, `installedVersion`, `inParent`), plus the categories present and where the data came
from. The annotation is what lets one list serve both "browse" and "manage" — an installed
extension is the same card with a different action.
"""
function catalog_view(nb; force::Bool = false)
    entries, meta = fetch_catalog(; force)
    env = try; _notebook_adds(nb); catch; (adds = Any[], parent = Any[], detached = false, parentpath = ""); end
    have = Dict{String,String}()
    for p in env.adds;   have[String(p["name"])] = String(get(p, "version", "")); end
    parent = Dict{String,String}()
    for p in env.parent; parent[String(p["name"])] = String(get(p, "version", "")); end

    out = Any[]
    cats = Set{String}()
    for e in entries
        d = Dict{String,Any}(e)
        name = String(d["name"])
        d["installed"] = haskey(have, name)
        d["installedVersion"] = get(have, name, "")
        d["inParent"] = haskey(parent, name)
        haskey(parent, name) && isempty(d["installedVersion"]) && (d["installedVersion"] = parent[name])
        # Version drift: the notebook has it, but the registry has moved on. Reported separately from
        # `installed` so the card can offer Update instead of a dead "Installed" button.
        d["updatable"] = _is_older(d["installedVersion"], String(get(d, "version", "")))
        for c in get(d, "categories", String[]); push!(cats, String(c)); end
        push!(out, d)
    end
    return Dict{String,Any}(
        "entries"           => out,
        "categories"        => sort!(collect(cats)),
        "installedCount"    => count(e -> e["installed"] || e["inParent"], out),
        "updatableCount"    => count(e -> e["updatable"], out),
        "meta"              => meta,
        "registryInstalled" => catalog_registry_installed(),
        "registryName"      => catalog_registry_name(),
        "registryUrl"       => catalog_registry_url(),
        "manageable"        => !(nb.kernel isa InProcessKernel),
    )
end

"""
    _is_older(installed, latest) -> Bool

Is `installed` a strictly earlier release than `latest`? Both are version strings that may be empty
or non-semver (a dev checkout reports no version at all). Anything that doesn't parse as a pair of
version numbers is NOT reported as out of date: offering to "update" a local `dev` checkout to a
registry release would quietly replace the user's working copy.
"""
function _is_older(installed::AbstractString, latest::AbstractString)
    (isempty(installed) || isempty(latest)) && return false
    a = tryparse(VersionNumber, String(installed)); a === nothing && return false
    b = tryparse(VersionNumber, String(latest));    b === nothing && return false
    return a < b
end

# ── installing ────────────────────────────────────────────────────────────────

"""
    catalog_add_registry!(nb) -> Dict

Add the extension registry to the depot the notebook's worker runs in. Separate from installing a
package, and separately consented in the UI: a registry is depot-global, so it affects every
project on that machine, not just this notebook.

It runs on the WORKER, not the hub: a notebook on a remote region resolves packages against the
remote depot, and adding the registry here would silently do nothing for it.
"""
function catalog_add_registry!(nb)
    # A worker round-trip that clones a repo — same hazard as `pkg_op`, so the same discipline:
    # off nb.lock, serialized against eval on the notebook's gate mutex.
    return try
        Dict{String,Any}(lock(_eval_mutex(nb)) do
            ReportEngine.registry_add(nb.kernel, nb.report, catalog_registry_url())
        end)
    catch e
        Dict{String,Any}("ok" => false, "message" => first(sprint(showerror, e), 400))
    end
end

"""
    catalog_install!(nb, name; target = "notebook") -> Dict

Install a catalog extension into the notebook's environment. Adds the registry first if it's
missing — an install that fails with "package not found" because the registry was never added is a
dead end the user can't diagnose from the error.

Returns the `notebook_pkg_op!` result, plus `registryAdded` when this call had to add the registry.
"""
function catalog_install!(nb, name::AbstractString; target::AbstractString = "notebook")
    isempty(strip(name)) && return Dict{String,Any}("ok" => false, "message" => "no package named")
    added = false
    if !catalog_registry_installed()
        reg = catalog_add_registry!(nb)
        get(reg, "ok", false) || return Dict{String,Any}(
            "ok" => false, "message" => "could not add the $(catalog_registry_name()) registry: " *
                                        String(get(reg, "message", "unknown error")))
        added = true
    end
    res = Dict{String,Any}(notebook_pkg_op!(nb, "add", String(name); target))
    added && (res["registryAdded"] = true)
    return res
end

"""
    catalog_update!(nb, name; target = "notebook") -> Dict

Upgrade an already-installed extension to the newest version its environment allows. Distinct from
`catalog_install!` because adding a package that is already a dependency keeps the resolved version —
the version shown as out of date in the gallery would simply stay put.

`target = "project"` updates it in the enclosing project instead, for an extension the notebook
inherits rather than owns.
"""
function catalog_update!(nb, name::AbstractString; target::AbstractString = "notebook")
    isempty(strip(name)) && return Dict{String,Any}("ok" => false, "message" => "no package named")
    return Dict{String,Any}(notebook_pkg_op!(nb, "update", String(name); target))
end
