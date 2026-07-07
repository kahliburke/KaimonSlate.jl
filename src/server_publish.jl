# ── Publishing manager service layer ───────────────────────────────────────────────────────────────
# The HTTP + tool-facing surface over the publish ledger and target adapters: read the ledger (docs ↔
# targets ↔ history), configure targets, hold secrets in the config home (NEVER in the ledger/gist),
# resolve a notebook's stable docId, and run a multi-target publish with per-target SSE progress.
# Everything here composes the already-tested core (PublishLedger + the PublishTarget adapters).

# ── secret store (config home; gitignored, chmod 600 — referenced by `secretRef`, never in the ledger) ─
function _secrets_load()
    f = SlateHome.secrets_file()
    isfile(f) || return Dict{String,Any}()
    return try
        JSON.parse(read(f, String))
    catch
        Dict{String,Any}()
    end
end

function _secrets_save!(d::AbstractDict)
    mkpath(SlateHome.config_home())
    f = SlateHome.secrets_file()
    open(f, "w") do io
        write(io, JSON.json(d, 2))
    end
    try; chmod(f, 0o600); catch; end     # best-effort: keep tokens off other users
    return f
end

"Set (empty value ⇒ delete) a secret by `ref`; returns the sorted list of ref NAMES (never values)."
function publish_secret_set!(ref::AbstractString, value::AbstractString)
    r = String(ref)
    isempty(strip(r)) && return secret_refs()
    d = _secrets_load()
    isempty(strip(String(value))) ? delete!(d, r) : (d[r] = String(value))
    _secrets_save!(d)
    return secret_refs()
end

"The configured secret ref NAMES (values never leave the process)."
secret_refs() = sort!(collect(keys(_secrets_load())))

# ── notebook identity ────────────────────────────────────────────────────────────────────────────
# Parse "owner/name" out of an origin remote URL (https or scp-form), stripping a trailing ".git".
function _repo_slug(url::AbstractString)
    m = match(r"[:/]([^/:]+/[^/]+?)(?:\.git)?/?$", strip(String(url)))
    return m === nothing ? "" : String(m.captures[1])
end

"""
    notebook_docid(nb) -> (; docId, sourceRepo, sourcePath)

The document's stable identity for the ledger. Git-backed notebooks get a repo-relative-path + origin
id (survives file moves within the repo, matches across checkouts); otherwise the abspath id.
"""
function notebook_docid(nb::LiveNotebook)
    path = abspath(nb.path)
    dir = dirname(path)
    okroot, root = _git_run(dir, `git rev-parse --show-toplevel`)
    if okroot
        rootp = strip(root)
        rel = replace(relpath(path, rootp), '\\' => '/')
        okorg, origin = _git_run(dir, `git config --get remote.origin.url`)
        if okorg && !isempty(strip(origin))
            return (; docId = PublishLedger.docid_git(rel, strip(origin)),
                    sourceRepo = _repo_slug(origin), sourcePath = rel)
        end
    end
    return (; docId = PublishLedger.docid_local(path), sourceRepo = "", sourcePath = path)
end

# Ensure a Document exists for `nb` in `ledger`, refreshing its slug/title/source metadata; returns
# (; docId, slug). Assigns the given target names to the doc so the manager shows the intended set.
function _ensure_doc!(ledger, nb::LiveNotebook; target_names = String[])
    info = notebook_docid(nb)
    slug = doc_slug(nb)
    title = String(get(nb.report.meta, "title", slug))
    doc = get!(ledger.documents, info.docId) do
        PublishLedger.Document(info.docId)
    end
    doc.slug = slug
    doc.title = title
    doc.sourceRepo = info.sourceRepo
    doc.sourcePath = info.sourcePath
    for n in target_names
        String(n) in doc.targets || push!(doc.targets, String(n))
    end
    return (; docId = info.docId, slug = slug)
end

# ── ledger → view JSON ─────────────────────────────────────────────────────────────────────────────
# The manager's read model. Targets carry only NON-secret config; we surface `secretRef` names, never
# secret values. `available` lists the target kinds the UI can offer.
const _TARGET_KINDS = ["github-pages", "s3", "r2", "rsync", "zenodo"]

_event_view(e) = Dict{String,Any}("id" => e.id, "ts" => e.ts, "target" => e.target,
    "status" => e.status, "url" => e.url, "doi" => e.doi, "commit" => e.commit, "note" => e.note)

function _doc_view(d)
    return Dict{String,Any}("docId" => d.docId, "slug" => d.slug, "title" => d.title,
        "sourceRepo" => d.sourceRepo, "sourcePath" => d.sourcePath, "targets" => copy(d.targets),
        "events" => [_event_view(e) for e in reverse(d.events)])   # newest first for display
end

_target_view(t) = Dict{String,Any}("name" => t.name, "kind" => t.kind, "config" => t.config)
_site_view(s) = Dict{String,Any}("name" => s.name, "target" => s.target, "home" => s.home)

function _ledger_view(ledger)
    return Dict{String,Any}(
        "documents" => [_doc_view(d) for d in values(ledger.documents)],
        "targets" => [_target_view(t) for t in values(ledger.targets)],
        "sites" => [_site_view(s) for s in values(ledger.sites)],
        "secretRefs" => secret_refs(),
        "availableKinds" => _TARGET_KINDS)
end

"The whole ledger as the manager's view model (loads via the default store — may hit the network for gist)."
function publish_ledger_view()
    store = PublishLedger.default_store()
    view = _ledger_view(PublishLedger.load(store))
    view["backend"] = store isa PublishLedger.GistStore ? "gist" : "local"
    return view
end

# ── target / secret / doc mutations (load → mutate → save; structure is authoritative) ─────────────
function publish_target_set!(name::AbstractString, kind::AbstractString, config::AbstractDict)
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    led.targets[String(name)] = PublishLedger.Target(String(name), String(kind);
                                                      config = Dict{String,Any}(config))
    PublishLedger.save(store, led)
    return publish_ledger_view()
end

function publish_target_delete!(name::AbstractString)
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    delete!(led.targets, String(name))
    for d in values(led.documents)
        filter!(!=(String(name)), d.targets)
    end
    PublishLedger.save(store, led)
    return publish_ledger_view()
end

function publish_doc_delete!(docId::AbstractString)
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    delete!(led.documents, String(docId))
    PublishLedger.save(store, led)
    return publish_ledger_view()
end

# This notebook's docId + entry + the targets it's assigned (for the manager's "current document" view).
function publish_doc_info(nb::LiveNotebook)
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    info = notebook_docid(nb)
    doc = get(led.documents, info.docId, nothing)
    return Dict{String,Any}("docId" => info.docId, "slug" => doc_slug(nb),
        "title" => String(get(nb.report.meta, "title", doc_slug(nb))),
        "sourceRepo" => info.sourceRepo, "sourcePath" => info.sourcePath,
        "assignedTargets" => doc === nothing ? String[] : copy(doc.targets),
        "events" => doc === nothing ? Any[] : [_event_view(e) for e in reverse(doc.events)])
end

"Assign/replace the set of target names on this notebook's document (persisted)."
function publish_doc_set_targets!(nb::LiveNotebook, names)
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    di = _ensure_doc!(led, nb)
    led.documents[di.docId].targets = collect(String, names)
    PublishLedger.save(store, led)
    return publish_doc_info(nb)
end

# ── multi-target publish with SSE progress ─────────────────────────────────────────────────────────
# Summarise per-target results for the SSE `done` event / a tool return.
function _publish_summary(names, results)
    return Dict{String,Any}("ok" => all(r -> r.ok, results),
        "results" => [Dict{String,Any}("target" => String(n), "ok" => r.ok, "status" => r.status,
                                       "url" => r.url, "doi" => r.doi, "commit" => r.commit,
                                       "log" => r.log) for (n, r) in zip(names, results)])
end

"""
    run_publish(nb, target_names; on_event=nothing) -> summary::Dict

Load the ledger, ensure this notebook's document + its targets, resolve secrets from the config home,
fan out the publish concurrently, record one event per target, and persist. `on_event(i, phase,
payload)` streams progress. Throws (caught by the SSE handler) if a named target isn't configured.
"""
function run_publish(nb::LiveNotebook, target_names; on_event = nothing)
    names = collect(String, target_names)
    isempty(names) && error("no targets selected")
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    di = _ensure_doc!(led, nb; target_names = names)
    missing = [n for n in names if !haskey(led.targets, n)]
    isempty(missing) || error("unconfigured target(s): $(join(missing, ", ")) — add them in the manager first")
    secrets = _secrets_load()
    results = publish_document!(nb, led, di.docId, store; target_names = names, secrets = secrets,
                               slug = di.slug, on_event = on_event)
    return _publish_summary(names, results)
end

# The SSE handler (wired into the top-level `HTTP.listen!` dispatcher, not the router). Streams
# `status`/`log`/`done`/`failed` events; the actual publish runs in a task feeding a channel so the
# stream has a single writer even though targets deploy concurrently.
function _sse_publish(stream::HTTP.Stream, h::Hub)
    uri = HTTP.URI(stream.message.target)
    q = HTTP.queryparams(uri)
    m = match(r"^/api/([^/]+)/publish-run", uri.path)
    id = m === nothing ? "" : String(m.captures[1])
    nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    emit = function (ev::AbstractString, data::AbstractString)
        io = IOBuffer()
        println(io, "event: ", ev)
        for ln in split(data, '\n'); println(io, "data: ", ln); end
        println(io)
        try; write(stream, String(take!(io))); return true; catch; return false; end
    end
    if nb === nothing
        emit("failed", "no such notebook: $id")
        return
    end
    names = filter(!isempty, strip.(split(get(q, "targets", ""), ',')))
    ch = Channel{Tuple{String,String}}(128)
    task = @async begin
        try
            on_event = function (_i, phase, payload)
                if phase === :start
                    put!(ch, ("status", "Publishing to $(target_name(payload))…"))
                else
                    r = payload
                    tag = r.ok ? "✓" : "✗"
                    detail = !isempty(r.doi) ? r.doi : !isempty(r.url) ? r.url : r.status
                    put!(ch, ("log", "$tag $detail"))
                    r.ok || isempty(strip(r.log)) || put!(ch, ("log", first(split(strip(r.log), '\n'))))
                end
            end
            summary = run_publish(nb, names; on_event = on_event)
            put!(ch, ("done", JSON.json(summary)))
        catch e
            put!(ch, ("failed", sprint(showerror, e)))
        finally
            close(ch)
        end
    end
    for (ev, data) in ch
        emit(ev, data) || break
    end
    try; wait(task); catch; end
    return
end

# ── HTTP routes (called from `_make_router`) ─────────────────────────────────────────────────────────
function _register_publish_routes!(router, h::Hub)
    # Read the whole ledger (global — the manager's main view model).
    HTTP.register!(router, "GET", "/api/publish/ledger", _req -> _json(publish_ledger_view()))
    # This notebook's document info (scoped).
    HTTP.register!(router, "GET", "/api/{id}/publish/doc",
                   req -> _withnb(h, req, nb -> _json(publish_doc_info(nb))))
    # Assign the set of targets to this notebook's document (scoped).
    HTTP.register!(router, "POST", "/api/{id}/publish/doc-targets", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        _json(publish_doc_set_targets!(nb, [String(t) for t in get(b, "targets", String[])]))
    end))
    # Add/update a target config (global).
    HTTP.register!(router, "POST", "/api/publish/target", req -> begin
        b = _body(req)
        name = strip(String(get(b, "name", "")))
        kind = strip(String(get(b, "kind", "")))
        (isempty(name) || isempty(kind)) && return HTTP.Response(400, "target needs name + kind")
        _json(publish_target_set!(name, kind, get(b, "config", Dict{String,Any}())))
    end)
    # Delete a target (global).
    HTTP.register!(router, "POST", "/api/publish/target-delete", req -> begin
        name = strip(String(get(_body(req), "name", "")))
        isempty(name) && return HTTP.Response(400, "missing target name")
        _json(publish_target_delete!(name))
    end)
    # Forget a document + its history (global).
    HTTP.register!(router, "POST", "/api/publish/doc-delete", req -> begin
        docId = strip(String(get(_body(req), "docId", "")))
        isempty(docId) && return HTTP.Response(400, "missing docId")
        _json(publish_doc_delete!(docId))
    end)
    # List secret ref names (global; values never returned).
    HTTP.register!(router, "GET", "/api/publish/secrets", _req -> _json(Dict("refs" => secret_refs())))
    # Set/delete a secret by ref (global).
    HTTP.register!(router, "POST", "/api/publish/secret", req -> begin
        b = _body(req)
        ref = strip(String(get(b, "ref", "")))
        isempty(ref) && return HTTP.Response(400, "missing secret ref")
        _json(Dict("refs" => publish_secret_set!(ref, String(get(b, "value", "")))))
    end)
    return router
end
