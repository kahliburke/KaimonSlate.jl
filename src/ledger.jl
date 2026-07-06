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

"An OPTIONAL grouping of documents into a site/portfolio (membership itself lives in the deployed manifest)."
struct SiteGroup
    name::String
    target::String     # the site's default/output target
    home::String       # docId of the home notebook, or ""
end

SiteGroup(name; target = "", home = "") = SiteGroup(name, target, home)

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

_site_to_dict(s::SiteGroup) = Dict{String,Any}("target" => s.target, "home" => s.home)
_site_from_dict(name, d) = SiteGroup(String(name); target = _str(d, "target"), home = _str(d, "home"))

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
        return from_json(read(s.path, String))
    catch e
        @warn "PublishLedger: could not parse ledger; starting empty" path = s.path exception = e
        return Ledger()
    end
end

function save(s::LocalStore, ledger::Ledger)
    mkpath(dirname(s.path))
    # load-merge-save: fold OUR ledger into whatever's on disk so a concurrent writer's events survive
    # (last-writer wins for config, union for events — see `merge!`).
    merged = isfile(s.path) ? merge!(load(s), ledger) : ledger
    _atomic_write(s.path, to_json(merged))
    return merged
end

locate(s::LocalStore) = isfile(s.path) ? s.path : nothing

# Write via a temp file + rename so a crash mid-write can't leave a truncated ledger.
function _atomic_write(path::AbstractString, content::AbstractString)
    tmp = string(path, ".tmp.", getpid())
    write(tmp, content)
    mv(tmp, path; force = true)
    return path
end

end # module PublishLedger
