# ── Zenodo archival target — a citable DOI per version ─────────────────────────────────────────────
# DISTINCT from the static-host adapters: rather than a live site, Zenodo archives the standalone `.jl`
# bundle (via `export_standalone`) plus metadata and mints a **versioned DOI** — the perfect pair for a
# reproducible-research notebook. The four-step Zenodo deposition flow (create/new-version → upload →
# metadata → publish) runs over a `ZenodoClient` interface so the orchestration is unit-testable
# without a live token; `ZenodoHttp` is the real client. The event records the `doi`; the new
# deposition id is persisted back into the ledger target config (via `PublishResult.meta`) so the next
# publish makes a NEW VERSION of the same concept DOI.

"HTTP operations for the Zenodo deposition API, as an interface so tests can inject a fake."
abstract type ZenodoClient end

"Real Zenodo client. `sandbox=true` targets sandbox.zenodo.org for dry runs."
struct ZenodoHttp <: ZenodoClient
    token::String
    base::String
end

ZenodoHttp(token::AbstractString; sandbox::Bool = false) =
    ZenodoHttp(String(token), sandbox ? "https://sandbox.zenodo.org/api" : "https://zenodo.org/api")

zenodo_token(c::ZenodoHttp) = c.token

"""
    zenodo_request(client, method, url; json=nothing, file=nothing) -> (status::Int, body)

The single HTTP primitive the deposition flow is built on. `url` is either a path under the client's
`base` or an absolute URL (bucket uploads use the deposition's absolute bucket link). `json` sends a
JSON body; `file` streams a file's bytes (for bucket uploads). Returns the status and parsed-JSON body
(or `{}` on a non-JSON/empty body); never raises on an HTTP error status.
"""
function zenodo_request(c::ZenodoHttp, method::AbstractString, url::AbstractString;
                        json = nothing, file = nothing)
    full = startswith(url, "http") ? String(url) : string(c.base, url)
    headers = Pair{String,String}["Authorization" => "Bearer $(c.token)"]
    body = UInt8[]
    if json !== nothing
        push!(headers, "Content-Type" => "application/json")
        body = Vector{UInt8}(codeunits(JSON.json(json)))
    elseif file !== nothing
        body = read(file)
    end
    resp = HTTP.request(method, full, headers, body; status_exception = false)
    parsed = try
        isempty(resp.body) ? Dict{String,Any}() : JSON.parse(String(resp.body))
    catch
        Dict{String,Any}()
    end
    return (resp.status, parsed)
end

"Archive a document to Zenodo as a versioned, citable DOI."
struct ZenodoTarget <: PublishTarget
    name::String
    client::ZenodoClient
    depositionId::String              # "" ⇒ create a fresh record; else new-version from this deposition
    metadata::Dict{String,Any}        # user overrides (title / creators / description / version / …)
end

ZenodoTarget(; name = "zenodo", client::ZenodoClient, depositionId = "",
             metadata = Dict{String,Any}()) =
    ZenodoTarget(String(name), client, String(depositionId), Dict{String,Any}(metadata))

_zok(status::Integer) = 200 <= status < 300
_zerr(status, body) = string("Zenodo HTTP ", status,
    (body isa AbstractDict && haskey(body, "message")) ? string(": ", body["message"]) : "")

# Start a new version of an existing deposition and return (status, draft-deposition-with-bucket).
function _znewversion(client::ZenodoClient, depositionId::AbstractString)
    st, r = zenodo_request(client, "POST", "/deposit/depositions/$depositionId/actions/newversion")
    _zok(st) || return (st, r)
    draft = String(get(get(r, "links", Dict()), "latest_draft", ""))
    isempty(draft) && return (500, Dict("message" => "no latest_draft link on new-version response"))
    return zenodo_request(client, "GET", draft)
end

"""
    _zenodo_deposit(client, depositionId, file, metadata) -> PublishResult

The four-step deposition flow over an already-written bundle `file` and a ready `metadata` block:
create (or new-version from `depositionId`) → upload to the bucket → set metadata → publish. Returns a
`PublishResult` carrying the minted `doi` and the new `depositionId` in `meta`. Notebook-free, so the
orchestration is unit-testable with a fake `ZenodoClient`.
"""
function _zenodo_deposit(client::ZenodoClient, depositionId::AbstractString, file::AbstractString,
                         metadata::AbstractDict)
    st, dep = isempty(depositionId) ?
              zenodo_request(client, "POST", "/deposit/depositions"; json = Dict{String,Any}()) :
              _znewversion(client, depositionId)
    _zok(st) || return PublishResult(; ok = false, status = "error", log = _zerr(st, dep))
    depId = string(get(dep, "id", ""))
    bucket = String(get(get(dep, "links", Dict()), "bucket", ""))
    isempty(bucket) && return PublishResult(; ok = false, status = "error",
                                            log = "Zenodo: deposition has no bucket link")
    stu, ub = zenodo_request(client, "PUT", string(bucket, "/", basename(file)); file = file)
    _zok(stu) || return PublishResult(; ok = false, status = "error", log = _zerr(stu, ub))
    stm, mb = zenodo_request(client, "PUT", "/deposit/depositions/$depId";
                             json = Dict("metadata" => metadata))
    _zok(stm) || return PublishResult(; ok = false, status = "error", log = _zerr(stm, mb))
    stp, pb = zenodo_request(client, "POST", "/deposit/depositions/$depId/actions/publish")
    _zok(stp) || return PublishResult(; ok = false, status = "error", log = _zerr(stp, pb))
    doi = String(get(pb, "doi", ""))
    url = String(get(get(pb, "links", Dict()), "record_html", ""))
    return PublishResult(; ok = true, status = "ok", doi = doi, url = url,
                         meta = Dict{String,Any}("depositionId" => depId))
end

# The Zenodo metadata block — sensible defaults from the notebook, overridable via `t.metadata`.
function _zenodo_metadata(t::ZenodoTarget, nb, slug::AbstractString)
    title = String(get(t.metadata, "title", get(nb.report.meta, "title", slug)))
    author = String(get(nb.report.meta, "author", ""))
    creators = get(t.metadata, "creators",
                   Any[Dict("name" => isempty(author) ? "Unknown" : author)])
    desc = String(get(t.metadata, "description",
                      "Reproducible KaimonSlate notebook bundle: $title"))
    meta = Dict{String,Any}("upload_type" => "software", "title" => title,
                            "creators" => creators, "description" => desc)
    for (k, v) in t.metadata
        k in ("title", "creators", "description") || (meta[k] = v)
    end
    return meta
end

function publish(t::ZenodoTarget, nb::LiveNotebook; slug = "", kwargs...)
    slg = isempty(strip(String(slug))) ? doc_slug(nb) : String(slug)
    isempty(slg) && (slg = "notebook")
    text = export_standalone(nb)
    dir = mktempdir()
    try
        file = joinpath(dir, "$slg.jl")
        write(file, text)
        return _zenodo_deposit(t.client, t.depositionId, file, _zenodo_metadata(t, nb, slg))
    finally
        rm(dir; recursive = true, force = true)
    end
end

function preflight(t::ZenodoTarget)
    tok = t.client isa ZenodoHttp ? t.client.token : "present"
    isempty(strip(tok)) && return (; ok = false, warnings = ["no Zenodo API token configured (set the target's secretRef)"])
    return (; ok = true, warnings = String[])
end
