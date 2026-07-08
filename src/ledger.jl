"""
    PublishLedger

The publish **ledger**: a small structured JSON record of *what / when / where* a document was
published, plus each document's target config and optional site groupings. It is append-only over
events and **carries NO secrets** — only slugs, URLs, DOIs, timestamps, commit SHAs, and statuses.
Secrets live in the config home (`SlateHome.secrets_file()`), referenced here by `secretRef`.

Two design commitments drive the shape:

- **Documents are the base unit**, not sites. A document publishes independently to a set of named
  targets; a *site* is an optional aggregation of documents. Publishing only ever touches OUTPUT
  (a `gh-pages`-style branch), so nothing here pollutes a source repo.
- **Events are append-only with a stable `id`**, so two machines that each publish can union-merge
  their ledgers without losing history (see [`merge!`](@ref)).

`Ledger` ⟷ JSON round-trips losslessly ([`to_json`](@ref) / [`from_json`](@ref)); persistence and
self-location are the [`LedgerStore`](@ref) backends' job (this file ships the `local` backend).
"""
module PublishLedger

import JSON
import Dates
import SHA

using ..SlateHome

export Ledger, Document, Event, Target, SiteGroup, LedgerStore, LocalStore

const LEDGER_VERSION = 1

# ── Core types ──────────────────────────────────────────────────────────────────────────────────
"A single publish event — one target, one push. Immutable; appended newest-last to a `Document`."
struct Event
    id::String        # stable unique id → union-merge key across machines
    ts::String        # ISO-8601 UTC timestamp
    target::String    # target name (key into `Ledger.targets`)
    status::String     # "ok" | "error" | …
    url::String       # live URL (static hosts)
    doi::String       # minted DOI (Zenodo); "" otherwise
    commit::String    # output-branch commit SHA
    bundle::String    # content hash of the shipped bundle ("sha256:…")
    note::String
end

Event(; id, ts, target, status = "ok", url = "", doi = "", commit = "", bundle = "", note = "") =
    Event(id, ts, target, status, url, doi, commit, bundle, note)

"A published document identity: where it comes from, where it publishes, and its event history."
mutable struct Document
    docId::String
    slug::String
    title::String
    sourceRepo::String
    sourcePath::String
    targets::Vector{String}     # references into `Ledger.targets`
    events::Vector{Event}       # append-only, newest last
end

Document(docId; slug = "", title = "", sourceRepo = "", sourcePath = "",
         targets = String[], events = Event[]) =
    Document(docId, slug, title, sourceRepo, sourcePath, collect(String, targets), collect(Event, events))

"A named target config — the NON-secret parts only. A secret is referenced by `config[\"secretRef\"]`."
struct Target
    name::String
    kind::String                 # "github-pages" | "netlify" | "s3" | "zenodo" | …
    config::Dict{String,Any}     # repo/branch/subdir/conceptDOI/secretRef/…
end

Target(name, kind; config = Dict{String,Any}()) = Target(name, kind, Dict{String,Any}(config))

"A logical site/portfolio: a canonical build (the local site dir) that deploys to a set of destination
targets. Its document membership + order + sections live in that build's `slate-site.json` manifest."
struct SiteGroup
    name::String
    targets::Vector{String}   # the destination targets this site syncs to (references into Ledger.targets)
    home::String              # slug/docId of the home notebook, or ""
end

SiteGroup(name; targets = String[], target = "", home = "") =
    SiteGroup(String(name), isempty(targets) && !isempty(target) ? [String(target)] : collect(String, targets), String(home))

"The whole ledger: documents ↔ targets ↔ optional site groupings."
mutable struct Ledger
    version::Int
    documents::Dict{String,Document}
    targets::Dict{String,Target}
    sites::Dict{String,SiteGroup}
end

Ledger() = Ledger(LEDGER_VERSION, Dict{String,Document}(), Dict{String,Target}(), Dict{String,SiteGroup}())

# ── Document identity ────────────────────────────────────────────────────────────────────────────
# A stable id per document that survives file moves within a repo and spans machines. For a git-backed
# notebook it's `sha1(canonical repo-relative path + "\0" + canonical origin-remote-url)`; otherwise
# `sha1(canonical abspath)`. Canonicalisation strips a trailing `.git`/slash and normalises separators
# so the same notebook yields the same id on any checkout. (Open question in the spec: whether this
# survives a repo *rename* — the origin url change would shift the id; revisit if it bites.)
_canon_path(p::AbstractString) = replace(strip(String(p)), '\\' => '/')
function _canon_remote(u::AbstractString)
    s = strip(String(u))
    endswith(s, ".git") && (s = s[1:end-4])
    return rstrip(s, '/')
end

"docId for a git-backed notebook, from its repo-relative path and origin remote url."
docid_git(repo_relpath::AbstractString, origin_url::AbstractString) =
    bytes2hex(SHA.sha1(string(_canon_path(repo_relpath), '\0', _canon_remote(origin_url))))

"docId for a non-git notebook, from its absolute path."
docid_local(abs_path::AbstractString) = bytes2hex(SHA.sha1(_canon_path(abspath(String(abs_path)))))

# ── Event helpers ────────────────────────────────────────────────────────────────────────────────
"ISO-8601 UTC timestamp for *now* (seconds precision, `Z` suffix)."
now_ts() = string(Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS"), "Z")

"A fresh, unique event id (`evt_<time><rand>`) — stable merge key, no coordination needed."
new_event_id() = string("evt_", Dates.format(Dates.now(Dates.UTC), "yyyymmddHHMMSS"), "_",
                        string(rand(UInt32); base = 16, pad = 8))

"""
    record_event!(ledger, docId, target; kwargs...) -> Event

Append a publish event to `docId`'s history (creating a bare `Document` if unknown), auto-assigning a
stable `id` and `ts` when omitted, and ensuring `target` is in the document's target list. Returns the
appended `Event`. `kwargs` are the `Event` fields (`status`, `url`, `doi`, `commit`, `bundle`, `note`).
"""
function record_event!(ledger::Ledger, docId::AbstractString, target::AbstractString;
                       id::AbstractString = new_event_id(), ts::AbstractString = now_ts(), kwargs...)
    doc = get!(ledger.documents, String(docId)) do; Document(String(docId)); end
    String(target) in doc.targets || push!(doc.targets, String(target))
    ev = Event(; id = String(id), ts = String(ts), target = String(target), kwargs...)
    push!(doc.events, ev)
    return ev
end

# ── Merge (union-merge; the multi-machine safety net) ───────────────────────────────────────────
"""
    merge!(into::Ledger, other::Ledger) -> into

Union-merge `other` into `into`: events are unioned by `id` (never lost, order preserved with newest
last), document metadata and target/site config are **last-writer = `other`**. This makes concurrent
writes safe (load → merge → save) and lets two machines reconcile their ledgers deterministically.
"""
function Base.merge!(into::Ledger, other::Ledger)
    into.version = max(into.version, other.version)
    for (id, odoc) in other.documents
        if haskey(into.documents, id)
            _merge_doc!(into.documents[id], odoc)
        else
            into.documents[id] = odoc
        end
    end
    for (k, t) in other.targets; into.targets[k] = t; end   # last-writer wins for config
    for (k, s) in other.sites; into.sites[k] = s; end
    return into
end

function _merge_doc!(into::Document, other::Document)
    # last-writer metadata, but only overwrite with a non-empty value so a sparse update can't blank fields
    isempty(other.slug) || (into.slug = other.slug)
    isempty(other.title) || (into.title = other.title)
    isempty(other.sourceRepo) || (into.sourceRepo = other.sourceRepo)
    isempty(other.sourcePath) || (into.sourcePath = other.sourcePath)
    for t in other.targets; t in into.targets || push!(into.targets, t); end
    seen = Set(e.id for e in into.events)
    for e in other.events; e.id in seen || (push!(into.events, e); push!(seen, e.id)); end
    return into
end

"Merge into a fresh copy, leaving both inputs untouched."
merge_ledgers(a::Ledger, b::Ledger) = merge!(_copy(a), b)
_copy(l::Ledger) = from_dict(to_dict(l))

"""
    _reconcile_for_save(remote, mine) -> mine

The reconciliation a store applies before persisting `mine` over `remote`. `mine` is **authoritative
for structure** — which documents/targets/sites exist and their config — so edits *and deletes* stick
(the ledger is effectively single-writer for config; fine for a local-first workflow). But we still
**rescue events** the backend has that `mine` is missing, for documents that survive in `mine`, so a
concurrent machine's publish history is never lost. Callers must therefore load→mutate→save, not save
a partially-built ledger. Mutates and returns `mine`.
"""
function _reconcile_for_save(remote::Ledger, mine::Ledger)
    for (id, mdoc) in mine.documents
        rdoc = get(remote.documents, id, nothing)
        rdoc === nothing && continue
        seen = Set(e.id for e in mdoc.events)
        for e in rdoc.events
            e.id in seen || push!(mdoc.events, e)
        end
        sort!(mdoc.events; by = e -> e.ts)
    end
    mine.version = max(mine.version, remote.version)
    return mine
end

# ── JSON (de)serialisation ───────────────────────────────────────────────────────────────────────
_event_to_dict(e::Event) = Dict{String,Any}("id" => e.id, "ts" => e.ts, "target" => e.target,
    "status" => e.status, "url" => e.url, "doi" => e.doi, "commit" => e.commit,
    "bundle" => e.bundle, "note" => e.note)

_str(d, k, dflt = "") = String(get(d, k, dflt))

_event_from_dict(d) = Event(; id = _str(d, "id"), ts = _str(d, "ts"), target = _str(d, "target"),
    status = _str(d, "status", "ok"), url = _str(d, "url"), doi = _str(d, "doi"),
    commit = _str(d, "commit"), bundle = _str(d, "bundle"), note = _str(d, "note"))

function _doc_to_dict(d::Document)
    return Dict{String,Any}("slug" => d.slug, "title" => d.title, "sourceRepo" => d.sourceRepo,
        "sourcePath" => d.sourcePath, "targets" => copy(d.targets),
        "events" => [_event_to_dict(e) for e in d.events])
end

function _doc_from_dict(docId, d)
    targets = [String(t) for t in get(d, "targets", String[])]
    events = [_event_from_dict(e) for e in get(d, "events", Any[])]
    return Document(String(docId); slug = _str(d, "slug"), title = _str(d, "title"),
        sourceRepo = _str(d, "sourceRepo"), sourcePath = _str(d, "sourcePath"),
        targets = targets, events = events)
end

_target_to_dict(t::Target) = merge(Dict{String,Any}("kind" => t.kind), t.config)
function _target_from_dict(name, d)
    cfg = Dict{String,Any}(k => v for (k, v) in d if k != "kind")
    return Target(String(name), _str(d, "kind"); config = cfg)
end

_site_to_dict(s::SiteGroup) = Dict{String,Any}("targets" => copy(s.targets), "home" => s.home)
_site_from_dict(name, d) = SiteGroup(String(name);
    targets = [String(t) for t in get(d, "targets", String[])], target = _str(d, "target"), home = _str(d, "home"))

"Plain-`Dict` form of the ledger (the JSON shape)."
function to_dict(l::Ledger)
    return Dict{String,Any}("version" => l.version,
        "documents" => Dict(id => _doc_to_dict(d) for (id, d) in l.documents),
        "targets" => Dict(k => _target_to_dict(t) for (k, t) in l.targets),
        "sites" => Dict(k => _site_to_dict(s) for (k, s) in l.sites))
end

"Build a `Ledger` from its plain-`Dict` (parsed-JSON) form; tolerant of missing sections."
function from_dict(d)
    l = Ledger()
    l.version = Int(get(d, "version", LEDGER_VERSION))
    for (id, dd) in get(d, "documents", Dict()); l.documents[String(id)] = _doc_from_dict(id, dd); end
    for (k, td) in get(d, "targets", Dict()); l.targets[String(k)] = _target_from_dict(k, td); end
    for (k, sd) in get(d, "sites", Dict()); l.sites[String(k)] = _site_from_dict(k, sd); end
    return l
end

to_json(l::Ledger) = JSON.json(to_dict(l), 2)
from_json(s::AbstractString) = from_dict(JSON.parse(String(s)))

# ── Pluggable store interface ────────────────────────────────────────────────────────────────────
"""
    LedgerStore

A backend that persists and (self-)locates the ledger. Contract:

- `load(store)::Ledger`   — fetch + parse, or an empty `Ledger` if none exists yet.
- `save(store, ledger)`   — persist; **load-merge-save** so concurrent appends union rather than clobber.
- `locate(store)`         — resolve/repair the pointer (returns a `String` handle, or `nothing`).

Backends (this file ships `local`; `gist`/`repo`/`bucket`/`folder` follow behind the same interface).
"""
abstract type LedgerStore end

function load end
function save end
function locate end

"""
    LocalStore(path = SlateHome.ledger_dir()/kaimonslate-ledger.json)

The XDG-data-dir backend: a single JSON file, no off-disk backup — the fallback when nothing else is
configured. `save` still does a load-merge-save against the on-disk copy so two processes writing the
same file union their events instead of one clobbering the other.
"""
struct LocalStore <: LedgerStore
    path::String
end

LocalStore() = LocalStore(joinpath(SlateHome.ledger_dir(), "kaimonslate-ledger.json"))

function load(s::LocalStore)::Ledger
    isfile(s.path) || return Ledger()
    try
        return _write_cache(from_json(read(s.path, String)))
    catch e
        @warn "PublishLedger: could not parse ledger; starting empty" path = s.path exception = e
        return Ledger()
    end
end

function save(s::LocalStore, ledger::Ledger)
    mkpath(dirname(s.path))
    # load→reconcile→save: our ledger is authoritative for structure (edits/deletes stick) while any
    # events already on disk are rescued into surviving docs (see `_reconcile_for_save`).
    merged = isfile(s.path) ? _reconcile_for_save(load(s), ledger) : ledger
    _atomic_write(s.path, to_json(merged))
    return _write_cache(merged)
end

locate(s::LocalStore) = isfile(s.path) ? s.path : nothing

# Write via a temp file + rename so a crash mid-write can't leave a truncated ledger.
function _atomic_write(path::AbstractString, content::AbstractString)
    tmp = string(path, ".tmp.", getpid())
    write(tmp, content)
    mv(tmp, path; force = true)
    return path
end

# ── gist backend (self-locating, off-disk backup) ───────────────────────────────────────────────
# The DEFAULT backend when `gh` is authed: a free, unlisted **secret** gist, git-versioned for free,
# reusing the user's existing `gh` auth. The KEY property is **self-location** — the ledger's location
# is re-discoverable from the user's GitHub identity + a fixed marker, never only from local disk:
#
#   description = `kaimonslate-publish-ledger`,  filename = `kaimonslate-ledger.json`
#
# Local disk only *caches* the resolved gist id (in the config home); if that cache is gone (a fresh
# machine) we `gist list` and match the marker to re-cache it — **list-first, create only if no
# match**, so two machines never fork the ledger. Caveat baked into the design: an unlisted gist is
# not ACL-private, which is why the ledger carries NO secrets (that invariant is load-bearing here).

const GIST_MARKER = "kaimonslate-publish-ledger"
const GIST_FILENAME = "kaimonslate-ledger.json"

"""
    GistClient

The GitHub-gist operations `GistStore` needs, as an interface so tests can inject an in-memory fake.
Implement `gist_list`, `gist_read`, `gist_create`, `gist_update` for a concrete client. Ships `GhCli`
(shells out to `gh api` for deterministic JSON I/O).
"""
abstract type GistClient end

"Real client — drives GitHub via the authenticated `gh` CLI's `api` subcommand."
struct GhCli <: GistClient
    gh::String
end
GhCli() = GhCli(something(Sys.which("gh"), "gh"))

"Is a `gh` binary on PATH at all?"
gh_available() = Sys.which("gh") !== nothing

"Is `gh` present AND authenticated (so the gist backend can actually reach GitHub)?"
function gh_authed()
    gh = Sys.which("gh")
    gh === nothing && return false
    return success(pipeline(`$gh auth status`; stdout = devnull, stderr = devnull))
end

# Run `gh <args…>`, optionally feeding `stdin_str`; returns (stdout::String, ok::Bool). Never throws.
function _gh(c::GhCli, args::Vector{String}; stdin_str::Union{Nothing,AbstractString} = nothing)
    out = IOBuffer()
    cmd = `$(c.gh) $args`
    try
        if stdin_str === nothing
            run(pipeline(cmd; stdout = out, stderr = devnull))
        else
            run(pipeline(cmd; stdin = IOBuffer(String(stdin_str)), stdout = out, stderr = devnull))
        end
        return (String(take!(out)), true)
    catch
        return (String(take!(out)), false)
    end
end

# Build the PATCH/POST body GitHub's gists API expects: {description?, public?, files: {name: {content}}}.
function _gist_body(filename::AbstractString, content::AbstractString; desc = nothing, public = nothing)
    files = Dict{String,Any}(String(filename) => Dict("content" => String(content)))
    body = Dict{String,Any}("files" => files)
    desc === nothing || (body["description"] = String(desc))
    public === nothing || (body["public"] = public)
    return JSON.json(body)
end

"List the caller's gists as `(id, description)` — up to 100 (enough to find our single marker gist)."
function gist_list(c::GhCli)
    out, ok = _gh(c, ["api", "/gists?per_page=100"])
    ok || error("PublishLedger: `gh api /gists` failed — is `gh` authenticated? (`gh auth login`)")
    arr = JSON.parse(out)
    return Tuple{String,String}[(String(g["id"]), String(something(get(g, "description", ""), ""))) for g in arr]
end

"Read `filename` out of gist `id`; `nothing` if the gist or file is gone."
function gist_read(c::GhCli, id::AbstractString, filename::AbstractString)
    out, ok = _gh(c, ["api", "/gists/$id"])
    ok || return nothing
    files = get(JSON.parse(out), "files", Dict())
    haskey(files, filename) || return nothing
    return String(get(files[filename], "content", ""))
end

"Create a secret gist carrying the marker `desc`; returns the new gist id."
function gist_create(c::GhCli, desc::AbstractString, filename::AbstractString, content::AbstractString)
    body = _gist_body(filename, content; desc = desc, public = false)
    out, ok = _gh(c, ["api", "-X", "POST", "/gists", "--input", "-"]; stdin_str = body)
    ok || error("PublishLedger: gist create failed")
    return String(JSON.parse(out)["id"])
end

"Overwrite `filename` in gist `id`."
function gist_update(c::GhCli, id::AbstractString, filename::AbstractString, content::AbstractString)
    _, ok = _gh(c, ["api", "-X", "PATCH", "/gists/$id", "--input", "-"];
                stdin_str = _gist_body(filename, content))
    ok || error("PublishLedger: gist update failed")
    return nothing
end

"""
    GistStore(; client=GhCli(), marker=GIST_MARKER, filename=GIST_FILENAME,
                pointer_file=<config_home>/ledger-pointer.json)

Self-locating gist backend. `pointer_file` caches the resolved gist id; it is *only* a cache — the
real pointer is the GitHub identity + `marker` convention, so a lost cache self-repairs via
[`locate`](@ref). `save` does create-on-first-write then fetch-before-write union merge thereafter.
"""
mutable struct GistStore <: LedgerStore
    client::GistClient
    marker::String
    filename::String
    pointer_file::String
    id::Union{String,Nothing}    # resolved gist id, cached in-process
end

GistStore(; client::GistClient = GhCli(), marker::AbstractString = GIST_MARKER,
          filename::AbstractString = GIST_FILENAME,
          pointer_file::AbstractString = joinpath(SlateHome.config_home(), "ledger-pointer.json")) =
    GistStore(client, String(marker), String(filename), String(pointer_file), nothing)

function _read_pointer(s::GistStore)
    isfile(s.pointer_file) || return nothing
    try
        id = get(JSON.parse(read(s.pointer_file, String)), "gist", nothing)
        return id === nothing ? nothing : String(id)
    catch
        return nothing
    end
end

function _write_pointer(s::GistStore, id::AbstractString)
    mkpath(dirname(s.pointer_file))
    _atomic_write(s.pointer_file, JSON.json(Dict("gist" => String(id)), 2))
    return nothing
end

"""
    locate(s::GistStore) -> Union{String,Nothing}

Resolve (and cache) the ledger gist id via the self-location flow: in-process cache → pointer file →
`gist list` matched on the marker (re-caching on a hit). Returns `nothing` only when no marker gist
exists yet (the create-on-first-write case). List-first here is what stops two machines forking.
"""
function locate(s::GistStore)
    s.id === nothing || return s.id
    cached = _read_pointer(s)
    if cached !== nothing
        s.id = cached
        return cached
    end
    for (id, desc) in gist_list(s.client)
        if desc == s.marker
            s.id = id
            _write_pointer(s, id)
            return id
        end
    end
    return nothing
end

function load(s::GistStore)::Ledger
    id = locate(s)
    id === nothing && return Ledger()
    content = gist_read(s.client, id, s.filename)
    (content === nothing || isempty(strip(content))) && return Ledger()
    try
        return _write_cache(from_json(content))
    catch e
        @warn "PublishLedger: could not parse gist ledger; starting empty" gist = id exception = e
        return Ledger()
    end
end

function save(s::GistStore, ledger::Ledger)
    id = locate(s)
    if id === nothing
        # First write ever: `locate` already list-matched (no marker gist), so creating one is safe.
        newid = gist_create(s.client, s.marker, s.filename, to_json(ledger))
        s.id = newid
        _write_pointer(s, newid)
        return _write_cache(ledger)
    end
    # fetch-before-write: reconcile against the current remote (our structure wins; rescue remote events).
    merged = _reconcile_for_save(load(s), ledger)
    gist_update(s.client, id, s.filename, to_json(merged))
    _write_cache(merged)
    return merged
end

# ── Local write-through cache ─────────────────────────────────────────────────────────────────────
# The gist store keeps only the gist *id* on disk, so every read hits the network (~1s). We also mirror
# the last-known ledger JSON to a local cache file, so a UI can paint from it INSTANTLY (no round-trip)
# and reconcile against the gist in the background. Best-effort: a cache read/write never breaks a
# load/save, and the cache is a convenience only — the gist (or LocalStore) remains the source of truth.
_ledger_cache_path() = joinpath(SlateHome.cache_home(), "ledger-cache.json")
function _write_cache(ledger::Ledger)
    try
        p = _ledger_cache_path(); mkpath(dirname(p)); write(p, to_json(ledger))
    catch
    end
    return ledger
end
"""
    cached_ledger() -> Union{Ledger,Nothing}

The last ledger written to the local write-through cache — a no-network snapshot for instant UI paint.
`nothing` if nothing has been cached yet (a fresh machine, before the first load/save).
"""
function cached_ledger()
    p = _ledger_cache_path(); isfile(p) || return nothing
    try
        return from_json(read(p, String))
    catch
        return nothing
    end
end

# ── Store selection ──────────────────────────────────────────────────────────────────────────────
"""
    default_store() -> LedgerStore

The backend to use when nothing is explicitly configured. `KAIMONSLATE_LEDGER_BACKEND=local|gist`
forces one; otherwise `GistStore` when `gh` is authenticated (off-disk, self-locating, free version
history), else `LocalStore` (local-only fallback — the UI should nudge the user to configure a backup).
"""
function default_store()
    b = lowercase(strip(get(ENV, "KAIMONSLATE_LEDGER_BACKEND", "")))
    b == "local" && return LocalStore()
    b == "gist" && return GistStore()
    return gh_authed() ? GistStore() : LocalStore()
end

end # module PublishLedger
