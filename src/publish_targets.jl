# ── Publish targets — pluggable deploy adapters ────────────────────────────────────────────────────
# A `PublishTarget` knows how to deploy a document to ONE destination. It is constructed from a ledger
# `PublishLedger.Target` config plus injected secrets (which are NEVER stored on the adapter or in the
# ledger). A document's multi-target push fans out over its targets concurrently — one `PublishResult`,
# and therefore one ledger `Event`, per target. `publish_site` (the battle-tested GitHub Pages flow)
# becomes the engine behind the `github-pages` adapter; generic object-storage/rsync hosts share one
# upload adapter.

"A deploy adapter. Implement `publish(::T, nb; …)::PublishResult` and `preflight(::T)::NamedTuple`."
abstract type PublishTarget end

"The outcome of deploying one document to one target — the raw material for a ledger `Event`."
struct PublishResult
    ok::Bool
    url::String
    doi::String
    commit::String
    status::String     # "ok" | "error" | "unchanged" | a deploy conclusion
    log::String
    meta::Dict{String,Any}   # non-secret target state to persist back to the ledger config (e.g. Zenodo depositionId)
end

PublishResult(; ok::Bool, url = "", doi = "", commit = "", status = ok ? "ok" : "error", log = "",
              meta = Dict{String,Any}()) =
    PublishResult(ok, url, doi, commit, status, log, Dict{String,Any}(meta))

"The target's name (its ledger key, e.g. `gh:portfolio`) — used to attribute the event."
target_name(t::PublishTarget) = t.name

# ── github-pages ───────────────────────────────────────────────────────────────────────────────────
"Deploy to a repo's `gh-pages`-style branch via [`publish_site`] (gh + Actions Pages deploy)."
struct GithubPagesTarget <: PublishTarget
    name::String
    repo::String
    branch::String
    subdir::String
    private::Bool
    create::Bool
end

GithubPagesTarget(; name = "github-pages", repo::AbstractString, branch = "gh-pages", subdir = "",
                  private::Bool = false, create::Bool = true) =
    GithubPagesTarget(String(name), String(repo), String(branch), String(subdir), private, create)

function publish(t::GithubPagesTarget, nb::LiveNotebook; slug = "", site_title = "",
                 site_description = "", bundle = false, kwargs...)
    r = publish_site(nb, t.repo; slug = slug, site_title = site_title, site_description = site_description,
                     private = t.private, create = t.create, bundle = bundle, kwargs...)
    ok = r.pagesEnabled || r.deployStatus == "unchanged"
    return PublishResult(; ok = ok, url = r.url, commit = r.commit, status = r.deployStatus,
                         log = ok ? "" : String(r.pagesError))
end

function preflight(t::GithubPagesTarget)
    gh = Sys.which("gh")
    gh === nothing && return (; ok = false, warnings = ["`gh` CLI not found on PATH — install it and `gh auth login`"])
    success(pipeline(`$gh auth status`; stdout = devnull, stderr = devnull)) ||
        return (; ok = false, warnings = ["`gh` is not authenticated — run `gh auth login`"])
    exists = _gh_ok(`$gh repo view $(t.repo)`)
    warnings = String[]
    (exists || t.create) || push!(warnings, "repo $(t.repo) doesn't exist and “create if missing” is off")
    return (; ok = isempty(warnings), repoExists = exists, warnings = warnings)
end

# ── generic upload (object storage / rsync) ────────────────────────────────────────────────────────
# One adapter covering "build a site dir → push it somewhere with a CLI + a token": S3 + CloudFront,
# Cloudflare R2 (S3 API with a custom endpoint), or rsync/scp to a self-hosted box. Creds come from the
# environment (`aws` profile / ssh agent), referenced by the ledger's `secretRef`, never stored here.
struct GenericUploadTarget <: PublishTarget
    name::String
    kind::Symbol        # :s3 (also R2 via `endpoint`) | :rsync
    dest::String        # "s3://bucket/prefix" | "user@host:/var/www/site"
    url::String         # public URL base to report as the live location
    endpoint::String    # S3 endpoint override for R2 (""=AWS default)
    delete::Bool        # mirror deletes so removed docs disappear (sync/rsync --delete)
end

GenericUploadTarget(; name, kind::Symbol, dest::AbstractString, url = "", endpoint = "", delete::Bool = true) =
    GenericUploadTarget(String(name), kind, String(dest), String(url), String(endpoint), delete)

function publish(t::GenericUploadTarget, nb::LiveNotebook; slug = "", bundle = false, base_url = "", kwargs...)
    dir = mktempdir()
    try
        build_site!(dir, nb; site_url = isempty(base_url) ? t.url : base_url, slug = slug,
                    bundle = bundle, kwargs...)
        ok, log = _upload_dir(t, dir)
        return PublishResult(; ok = ok, url = t.url, log = ok ? log : log)
    finally
        rm(dir; recursive = true, force = true)
    end
end

# Run the upload CLI for the target's kind over a built dir; returns (ok, combined-output).
function _upload_dir(t::GenericUploadTarget, dir::AbstractString)
    if t.kind === :s3
        args = String["s3", "sync", dir, t.dest]
        t.delete && push!(args, "--delete")
        isempty(t.endpoint) || append!(args, ["--endpoint-url", t.endpoint])
        return _run_capture(`aws $args`)
    elseif t.kind === :rsync
        args = String["-az"]
        t.delete && push!(args, "--delete")
        # trailing slash on the source → copy its CONTENTS into dest (not a nested dir)
        append!(args, [string(dir, "/"), t.dest])
        return _run_capture(`rsync $args`)
    else
        return (false, "unknown upload kind :$(t.kind)")
    end
end

function preflight(t::GenericUploadTarget)
    warnings = String[]
    tool = t.kind === :s3 ? "aws" : t.kind === :rsync ? "rsync" : ""
    isempty(tool) && return (; ok = false, warnings = ["unknown upload kind :$(t.kind)"])
    Sys.which(tool) === nothing && push!(warnings, "`$tool` CLI not found on PATH")
    isempty(strip(t.dest)) && push!(warnings, "no destination configured")
    return (; ok = isempty(warnings), warnings = warnings)
end

# ── shared process runner ────────────────────────────────────────────────────────────────────────
# Run `cmd`, merging stdout+stderr; returns (ok, output). `env` adds vars to the child environment
# (for CLI tokens). Never throws.
function _run_capture(cmd::Cmd; env = nothing)
    buf = IOBuffer()
    c = env === nothing ? cmd : addenv(cmd, env)
    ok = try
        run(pipeline(c; stdout = buf, stderr = buf))
        true
    catch
        false
    end
    return (ok, String(take!(buf)))
end

# ── Cloudflare Pages / Netlify — one-token static-host deploys via their CLIs ────────────────────────
# Both build the site dir, then run the platform's CLI with a token pulled from the (injected) child
# environment. Cloudflare Pages: unlimited-bandwidth free tier. Netlify: 100GB/mo hard cap. Falls back
# to `npx <cli>` when the CLI isn't installed globally.

"Deploy to a Cloudflare Pages project via `wrangler pages deploy` (token = CLOUDFLARE_API_TOKEN)."
struct CloudflarePagesTarget <: PublishTarget
    name::String
    project::String        # Cloudflare Pages project name
    account_id::String     # CLOUDFLARE_ACCOUNT_ID
    token::String          # CLOUDFLARE_API_TOKEN (secret, injected — never stored on the ledger)
    url::String
    branch::String         # "" = wrangler's default (production)
end

CloudflarePagesTarget(; name = "cloudflare-pages", project, account_id = "", token = "", url = "", branch = "") =
    CloudflarePagesTarget(String(name), String(project), String(account_id), String(token),
                          isempty(url) ? "https://$(project).pages.dev/" : String(url), String(branch))

function publish(t::CloudflarePagesTarget, nb::LiveNotebook; slug = "", bundle = false, base_url = "", kwargs...)
    dir = mktempdir()
    try
        build_site!(dir, nb; site_url = isempty(base_url) ? t.url : base_url, slug = slug, bundle = bundle, kwargs...)
        wr = Sys.which("wrangler")
        cmd = wr === nothing ? `npx --yes wrangler pages deploy $dir --project-name $(t.project)` :
                               `$wr pages deploy $dir --project-name $(t.project)`
        isempty(t.branch) || (cmd = `$cmd --branch $(t.branch)`)
        env = Dict{String,String}()
        isempty(t.token) || (env["CLOUDFLARE_API_TOKEN"] = t.token)
        isempty(t.account_id) || (env["CLOUDFLARE_ACCOUNT_ID"] = t.account_id)
        ok, log = _run_capture(cmd; env = env)
        return PublishResult(; ok = ok, url = t.url, log = log)
    finally
        rm(dir; recursive = true, force = true)
    end
end

function preflight(t::CloudflarePagesTarget)
    warnings = String[]
    (Sys.which("wrangler") === nothing && Sys.which("npx") === nothing) &&
        push!(warnings, "neither `wrangler` nor `npx` found on PATH (install Wrangler)")
    isempty(strip(t.project)) && push!(warnings, "no Cloudflare Pages project name")
    isempty(strip(t.token)) && push!(warnings, "no CLOUDFLARE_API_TOKEN (set the target's secretRef)")
    return (; ok = isempty(warnings), warnings = warnings)
end

"Deploy to a Netlify site via `netlify deploy --prod` (token = NETLIFY_AUTH_TOKEN)."
struct NetlifyTarget <: PublishTarget
    name::String
    site_id::String        # NETLIFY_SITE_ID
    token::String          # NETLIFY_AUTH_TOKEN (secret, injected)
    url::String
end

NetlifyTarget(; name = "netlify", site_id, token = "", url = "") =
    NetlifyTarget(String(name), String(site_id), String(token), String(url))

function publish(t::NetlifyTarget, nb::LiveNotebook; slug = "", bundle = false, base_url = "", kwargs...)
    dir = mktempdir()
    try
        build_site!(dir, nb; site_url = isempty(base_url) ? t.url : base_url, slug = slug, bundle = bundle, kwargs...)
        nl = Sys.which("netlify")
        cmd = nl === nothing ? `npx --yes netlify-cli deploy --prod --dir $dir` : `$nl deploy --prod --dir $dir`
        env = Dict{String,String}()
        isempty(t.token) || (env["NETLIFY_AUTH_TOKEN"] = t.token)
        isempty(t.site_id) || (env["NETLIFY_SITE_ID"] = t.site_id)
        ok, log = _run_capture(cmd; env = env)
        return PublishResult(; ok = ok, url = t.url, log = log)
    finally
        rm(dir; recursive = true, force = true)
    end
end

function preflight(t::NetlifyTarget)
    warnings = String[]
    (Sys.which("netlify") === nothing && Sys.which("npx") === nothing) &&
        push!(warnings, "neither `netlify` nor `npx` found on PATH (install the Netlify CLI)")
    isempty(strip(t.site_id)) && push!(warnings, "no Netlify site id")
    isempty(strip(t.token)) && push!(warnings, "no NETLIFY_AUTH_TOKEN (set the target's secretRef)")
    return (; ok = isempty(warnings), warnings = warnings)
end

# ── multi-target fan-out ───────────────────────────────────────────────────────────────────────────
"""
    publish_to_targets(nb, targets; on_event=nothing, kwargs...) -> Vector{PublishResult}

Deploy `nb` to every `PublishTarget` **concurrently**, preserving input order in the result vector.
`on_event`, if given, is called `on_event(i, :start, target)` then `on_event(i, :done, result)` for
each target — the seam the manager UI streams over SSE. Targets are isolated: a throwing/​failing
target yields an `ok=false` result and never aborts its siblings.
"""
function publish_to_targets(nb, targets::AbstractVector{<:PublishTarget}; on_event = nothing, kwargs...)
    results = Vector{PublishResult}(undef, length(targets))
    @sync for (i, t) in enumerate(targets)
        @async begin
            on_event === nothing || on_event(i, :start, t)
            r = try
                publish(t, nb; kwargs...)
            catch e
                PublishResult(; ok = false, log = sprint(showerror, e))
            end
            results[i] = r
            on_event === nothing || on_event(i, :done, r)
        end
    end
    return results
end

# ── ledger bridge ────────────────────────────────────────────────────────────────────────────────
# Resolve a `secretRef` against a secrets provider — either a `Dict` (ref → value) or a callable
# `ref -> value`. An empty ref, or a provider with no match, yields "".
_secret(secrets::AbstractDict, ref) = String(get(secrets, String(ref), ""))
_secret(secrets, ref) = isempty(String(ref)) ? "" : String(secrets(String(ref)))

"""
    target_from_ledger(t::PublishLedger.Target; secrets=Dict()) -> PublishTarget

Construct a runtime adapter from a ledger target config. `secrets` (a `Dict` or a `ref -> value`
callable) resolves the target's `secretRef` for backends that need a token (e.g. Zenodo). CLI-based
backends (github-pages via `gh`, s3/rsync) read their creds from the environment and don't carry a
secret on the adapter.
"""
function target_from_ledger(t; secrets = Dict{String,String}())
    cfg = t.config
    _s(k, d = "") = String(get(cfg, k, d))
    if t.kind == "github-pages"
        return GithubPagesTarget(; name = t.name, repo = _s("repo"), branch = _s("branch", "gh-pages"),
                                 subdir = _s("subdir"), private = get(cfg, "private", false) === true,
                                 create = get(cfg, "create", true) !== false)
    elseif t.kind in ("s3", "r2", "bucket", "rsync", "generic-upload")
        kind = t.kind == "rsync" ? :rsync : :s3
        return GenericUploadTarget(; name = t.name, kind = kind, dest = _s("dest"), url = _s("url"),
                                   endpoint = _s("endpoint"), delete = get(cfg, "delete", true) !== false)
    elseif t.kind == "cloudflare-pages"
        return CloudflarePagesTarget(; name = t.name, project = _s("project"), account_id = _s("accountId"),
                                     token = _secret(secrets, _s("secretRef")), url = _s("url"), branch = _s("branch"))
    elseif t.kind == "netlify"
        return NetlifyTarget(; name = t.name, site_id = _s("siteId"),
                             token = _secret(secrets, _s("secretRef")), url = _s("url"))
    elseif t.kind == "zenodo"
        token = _secret(secrets, _s("secretRef"))
        return ZenodoTarget(; name = t.name,
                            client = ZenodoHttp(token; sandbox = get(cfg, "sandbox", false) === true),
                            depositionId = _s("depositionId"),
                            metadata = Dict{String,Any}(get(cfg, "metadata", Dict{String,Any}())))
    else
        error("target_from_ledger: unknown target kind \"$(t.kind)\"")
    end
end

# Append one ledger Event per (target, result), attributing status/url/doi/commit and a short note,
# and fold any adapter-returned non-secret state (`r.meta`) back into that target's ledger config.
function _record_results!(ledger, docId::AbstractString, names, results)
    for (n, r) in zip(names, results)
        note = r.ok ? "" : first(split(strip(r.log) * "\n", '\n'))
        PublishLedger.record_event!(ledger, docId, String(n); status = r.status, url = r.url,
                                    doi = r.doi, commit = r.commit, note = String(note))
        (isempty(r.meta) || !haskey(ledger.targets, String(n))) ||
            merge!(ledger.targets[String(n)].config, r.meta)
    end
    return ledger
end

"""
    publish_document!(nb, ledger, docId, store; target_names=nothing, on_event=nothing, kwargs...)
        -> Vector{PublishResult}

The top-level publish action: deploy `docId` to each of its ledger targets (or the given
`target_names`) concurrently, append one `Event` per target to `ledger`, persist through `store`
(load-merge-save), and return the per-target results. `on_event` streams per-target progress.
"""
function publish_document!(nb, ledger, docId::AbstractString, store;
                           target_names = nothing, secrets = Dict{String,String}(),
                           on_event = nothing, kwargs...)
    doc = get(ledger.documents, String(docId), nothing)
    names = target_names === nothing ? (doc === nothing ? String[] : copy(doc.targets)) :
            collect(String, target_names)
    isempty(names) && error("publish_document!: document $docId has no targets")
    adapters = PublishTarget[target_from_ledger(ledger.targets[n]; secrets = secrets) for n in names]
    results = publish_to_targets(nb, adapters; on_event = on_event, kwargs...)
    _record_results!(ledger, docId, names, results)
    PublishLedger.save(store, ledger)
    return results
end
