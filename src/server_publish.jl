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

The document's stable ledger identity. It is a one-time id **embedded in the notebook** (`meta["docid"]`,
persisted to the `.jl` footer), so it never changes when the file moves or the repo gains/loses an
`origin` — the failure that used to split one notebook into two ledger entries. Generated + persisted on
first use. `sourceRepo`/`sourcePath` are derived from git purely for DISPLAY.
"""
function notebook_docid(nb::LiveNotebook)
    path = abspath(nb.path)
    dir = dirname(path)
    # `sourcePath` stays ABSOLUTE so the manager can open the notebook on this machine; `sourceRepo`
    # (owner/name, when there's an origin) is display-only provenance.
    sourceRepo, sourcePath = "", path
    okroot, _ = _git_run(dir, `git rev-parse --show-toplevel`)
    if okroot
        okorg, origin = _git_run(dir, `git config --get remote.origin.url`)
        (okorg && !isempty(strip(origin))) && (sourceRepo = _repo_slug(origin))
    end
    id = String(get(nb.report.meta, "docid", ""))
    if isempty(id)
        id = string("nb_", bytes2hex(rand(UInt8, 12)))     # stable, file-carried identity
        nb.report.meta["docid"] = id
        try; _persist!(nb); catch e; @warn "slate: could not persist docid" exception = e; end
    end
    return (; docId = id, sourceRepo = sourceRepo, sourcePath = sourcePath)
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
const _TARGET_KINDS = ["github-pages", "cloudflare-pages", "netlify", "s3", "r2", "rsync", "rsync-serve", "zenodo"]

_event_view(e) = Dict{String,Any}("id" => e.id, "ts" => e.ts, "target" => e.target,
    "status" => e.status, "url" => e.url, "doi" => e.doi, "commit" => e.commit, "note" => e.note)

function _doc_view(d)
    return Dict{String,Any}("docId" => d.docId, "slug" => d.slug, "title" => d.title,
        "sourceRepo" => d.sourceRepo, "sourcePath" => d.sourcePath, "targets" => copy(d.targets),
        "events" => [_event_view(e) for e in reverse(d.events)])   # newest first for display
end

_target_view(t) = Dict{String,Any}("name" => t.name, "kind" => t.kind, "config" => t.config)
function _site_view(s)
    fp = site_frontpage(s.name)
    return Dict{String,Any}("name" => s.name, "title" => s.title, "targets" => copy(s.targets),
        "paths" => copy(s.paths),               # target → subpath within it ("" = root)
        "docs" => site_docs(s.name),            # docs/order/sections from the local build
        # Front page (a `home`-tagged notebook): presence + WHICH notebook it is — title and
        # source path recorded at build time, so the manager can name it and link back to it.
        "hasHome" => fp.home, "homeTitle" => fp.homeTitle, "homePath" => fp.homePath)
end

# The authenticated GitHub login (for owner auto-fill so a new github-pages target only needs a repo
# NAME). Best-effort + cached; "" when `gh` is absent/unauthed.
const _GH_USER = Ref{Union{String,Nothing}}(nothing)
function gh_user()
    _GH_USER[] === nothing || return _GH_USER[]
    gh = Sys.which("gh"); u = ""
    if gh !== nothing
        try; u = strip(read(pipeline(`$gh api user --jq .login`; stderr = devnull), String)); catch; end
    end
    _GH_USER[] = String(u)
    return _GH_USER[]
end

function _ledger_view(ledger)
    return Dict{String,Any}(
        "documents" => [_doc_view(d) for d in values(ledger.documents)],
        "targets" => [_target_view(t) for t in values(ledger.targets)],
        "sites" => [_site_view(s) for s in values(ledger.sites)],
        "secretRefs" => secret_refs(),
        "ghUser" => gh_user(),
        "availableKinds" => _TARGET_KINDS)
end

"The whole ledger as the manager's view model (loads via the default store — may hit the network for gist)."
function publish_ledger_view()
    store = PublishLedger.default_store()
    view = _ledger_view(PublishLedger.load(store))
    view["backend"] = store isa PublishLedger.GistStore ? "gist" : "local"
    # The gist is the cross-machine ledger — link it so "— gist" is inspectable, not a mystery.
    store isa PublishLedger.GistStore && store.id !== nothing &&
        (view["backendUrl"] = "https://gist.github.com/" * store.id)
    return view
end

# Sites + targets ONLY, from the local write-through cache — NO network (no gist read, no `gh` call), so
# the front page can paint the Sites section in its first frame. `nothing` before anything's been cached.
# `_renderSites` reads only `sites`/`targets`, so this lean view is all the initial paint needs.
function publish_ledger_view_cached()
    led = PublishLedger.cached_ledger()
    led === nothing && return nothing
    return Dict{String,Any}(
        "sites" => [_site_view(s) for s in values(led.sites)],
        "targets" => [_target_view(t) for t in values(led.targets)],
        "localSites" => list_local_sites())   # which sites have a local build → accurate "built?" on first paint
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

"""Delete a target definition. Removal is LOCAL by default: the ledger entry goes away and every
reference (documents AND sites) is detached — deployed content stays live. `purge=true` also tears
down the deployed side where feasible (see `purge_deployed!`; rsync-serve stops its remote server
and removes the served dir). The view gains a `purgeLog` entry when a purge ran."""
function publish_target_delete!(name::AbstractString; purge::Bool = false)
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    plog = nothing
    if purge
        t = get(led.targets, String(name), nothing)
        if t !== nothing
            r = try
                purge_deployed!(target_from_ledger(t; secrets = _secrets_load()))
            catch e
                (; ok = false, log = sprint(showerror, e))
            end
            plog = "$(String(name)): $(strip(r.log))"
            r.ok || @warn "slate: purge of deployed content failed (target removed anyway)" target = name log = r.log
        end
    end
    delete!(led.targets, String(name))
    for d in values(led.documents)
        filter!(!=(String(name)), d.targets)
    end
    for s in values(led.sites)                       # sites too — a deleted target must not linger
        filter!(!=(String(name)), s.targets)         # as a dangling site destination
    end
    PublishLedger.save(store, led)
    view = publish_ledger_view()
    plog === nothing || (view["purgeLog"] = [plog])
    return view
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

# A site deploys to a LOCATION = (target, normalized subpath). Two sites writing the same location
# would overwrite each other, so `publish_site_set!` refuses that. Returns the clashing site name,
# or "" if the (target, subpath) is free.
_norm_subpath(p) = strip(strip(String(p)), '/')
function _location_clash(led, thisSite, target, subpath)
    sp = _norm_subpath(subpath)
    for (nm, s) in led.sites
        nm == String(thisSite) && continue
        (target in s.targets && _norm_subpath(get(s.paths, target, "")) == sp) && return nm
    end
    return ""
end

# ── Sites (logical portfolios: a canonical local build that syncs to a set of destination targets) ──
"""Create/update a site: its destination targets, home doc, display title ("" ⇒ the site name), and
optional per-target subpaths (target → path within that target; "" ⇒ its root). Refuses a
(target, subpath) location already claimed by another site — they'd overwrite each other.
Membership/order/sections live in its local build."""
function publish_site_set!(name::AbstractString, targets, home::AbstractString = "",
                           title::AbstractString = ""; paths = Dict{String,String}())
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    tlist = collect(String, targets)
    pmap = Dict{String,String}(String(k) => _norm_subpath(v) for (k, v) in pairs(paths) if String(k) in tlist)
    for t in tlist
        clash = _location_clash(led, name, t, get(pmap, t, ""))
        isempty(clash) || error("target '$t'" * (isempty(get(pmap, t, "")) ? " (root)" : " path '$(pmap[t])'") *
            " is already used by site '$clash' — give this site a different subpath on '$t' so they don't overwrite each other")
    end
    led.sites[String(name)] = PublishLedger.SiteGroup(String(name); targets = tlist,
                                                      home = String(home), title = String(title), paths = pmap)
    PublishLedger.save(store, led)
    return publish_ledger_view()
end

"""Delete a site. Local removal always: the ledger definition AND the local canonical build dir go
away. `purge=true` additionally tears down deployed content on each of the site's targets where
feasible (see `purge_deployed!`). The view gains a `purgeLog` entry when a purge ran."""
function publish_site_delete!(name::AbstractString; purge::Bool = false)
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    site = get(led.sites, String(name), nothing)
    logs = String[]
    if purge && site !== nothing
        secrets = _secrets_load()
        for tn in site.targets
            t = get(led.targets, tn, nothing)
            t === nothing && continue
            r = try
                # Purge THIS site's subpath within the target — not the whole target (a sibling
                # site may share it at a different path).
                purge_deployed!(with_subpath(target_from_ledger(t; secrets = secrets), get(site.paths, tn, "")))
            catch e
                (; ok = false, log = sprint(showerror, e))
            end
            push!(logs, "$tn: $(strip(r.log))")
            r.ok || @warn "slate: purge of deployed content failed (site removed anyway)" site = name target = tn log = r.log
        end
    end
    delete!(led.sites, String(name))
    PublishLedger.save(store, led)
    dir = _site_dir(String(name))                    # the canonical local build is part of the site
    dir === nothing || rm(dir; recursive = true, force = true)
    view = publish_ledger_view()
    isempty(logs) || (view["purgeLog"] = logs)
    return view
end

# Rebuild every LIVE member of the site (matched to an open notebook by source path) from its current
# source, using the build options recorded in the manifest at its last publish. Non-live members are
# reported and left untouched. Emits per-member `:status` lines so the publish stream names exactly which
# notebooks were re-exported. Best-effort per member — one failed rebuild is logged, the rest proceed.
function _resync_live_members!(dir::AbstractString, name::AbstractString, hub; on_event = nothing)
    man = _read_site_manifest(dir)
    # Match members to open notebooks by source path; fall back to slug so a manifest written before
    # `source` was recorded (pre-migration) still resolves without a one-off re-publish.
    live_by_path, live_by_slug = lock(hub.lock) do
        nbs = collect(values(hub.notebooks))
        (Dict(abspath(nb.path) => nb for nb in nbs), Dict(doc_slug(nb) => nb for nb in nbs))
    end
    say(msg) = on_event === nothing || on_event(0, :status, msg)
    note(msg) = on_event === nothing || on_event(0, :log, msg)
    members = Any[]
    hd = get(man, "homeDoc", nothing)
    hd isa AbstractDict && !isempty(String(get(hd, "path", ""))) && push!(members, (; slug = "", entry = hd))
    for d in get(man, "docs", Any[])
        d isa AbstractDict || continue
        push!(members, (; slug = String(get(d, "slug", "")), entry = d))
    end
    for m in members
        src = String(get(m.entry, "path", get(m.entry, "source", "")))
        title = String(get(m.entry, "title", isempty(m.slug) ? "front page" : m.slug))
        nb = isempty(src) ? nothing : get(live_by_path, abspath(src), nothing)
        nb === nothing && !isempty(m.slug) && (nb = get(live_by_slug, m.slug, nothing))
        if nb === nothing
            note("• $title — no open notebook to rebuild from, keeping last build")
            continue
        end
        b = get(m.entry, "build", Dict{String,Any}()); b isa AbstractDict || (b = Dict{String,Any}())
        say("Exporting $title …")
        try
            export_to_site(nb, name; slug = m.slug,
                           bundle = get(b, "bundle", false) === true,
                           history = get(b, "history", false) === true,
                           theme = String(get(b, "theme", "dark")),
                           outputs = String(get(b, "outputs", "all")),
                           include_source = get(b, "source", true) === true)
        catch e
            @warn "slate: sync rebuild of member failed" site = name member = title exception = (e, catch_backtrace())
            note("✗ $title — rebuild failed: $(sprint(showerror, e))")
        end
    end
    return nothing
end

"""
    sync_site!(name; on_event=nothing, hub=nothing) -> summary

Deploy a site's ONE canonical local build (`_site_dir(name)`) to every one of its destination targets,
concurrently and identically. `on_event(i, phase, payload)` streams per-target progress. Throws if the
site has no local build yet or no configured destinations. Zenodo/non-host targets report an error row.
"""
function sync_site!(name::AbstractString; on_event = nothing, hub = nothing)
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    site = get(led.sites, String(name), nothing)
    site === nothing && error("no site '$name'")
    dir = _site_dir(String(name))
    (dir === nothing || !isdir(dir)) && error("site '$name' has no local build yet — publish a notebook to it first")
    # Sync = SYNCHRONIZE: rebuild every member whose notebook is open from its CURRENT source before
    # deploying, so the bytes shipped reflect the notebooks as they are now — not the frozen artifact
    # from the last Publish. Members whose notebook isn't open are left as-is (a rebuild needs its live
    # kernel for figures). Streams an "Exporting <title>…" line per member so the UI shows what moved.
    hub === nothing || _resync_live_members!(dir, String(name), hub; on_event = on_event)
    tnames = [n for n in site.targets if haskey(led.targets, n)]
    isempty(tnames) && error("site '$name' has no configured destinations — add some in the manager")
    secrets = _secrets_load()
    results = Vector{PublishResult}(undef, length(tnames))
    @sync for (i, n) in enumerate(tnames)
        @async begin
            # Each attachment may deploy into a SUBPATH within its target (site.paths) so sibling
            # sites can share one bucket/host; a root-only kind under a subpath is that row's error.
            r = try
                a = with_subpath(target_from_ledger(led.targets[n]; secrets = secrets), get(site.paths, n, ""))
                on_event === nothing || on_event(i, :start, a)
                deploy_dir(a, dir)
            catch e
                PublishResult(; ok = false, log = sprint(showerror, e))
            end
            results[i] = r
            on_event === nothing || on_event(i, :done, r)
        end
    end
    return _publish_summary(tnames, results)
end

"""
    publish_to_site!(nb, siteName; on_event=nothing, kwargs...) -> summary

The site publish action: build `nb` into the site's canonical local dir (accumulating it as a member),
then sync the whole build to every destination. `kwargs` are the site-build options (bundle/history/…).
"""
function publish_to_site!(nb::LiveNotebook, siteName::AbstractString; on_event = nothing, hub = nothing, kwargs...)
    led = PublishLedger.load(PublishLedger.default_store())
    site = get(led.sites, String(siteName), nothing)
    # The SITE owns its display title — persisted on the SiteGroup, falling back to the site
    # name. It overrides any transient per-request `site_title` (that transient value is how a
    # stale "portfolio" title leaked into other sites' manifests).
    stitle = site === nothing ? String(siteName) :
             (isempty(strip(site.title)) ? site.name : site.title)
    built = export_to_site(nb, String(siteName); kwargs..., site_title = stitle)   # accumulate this doc into the canonical build
    # A site with no live destinations is a local staging area — build it, but there's nothing to sync.
    tnames = site === nothing ? String[] : [n for n in site.targets if haskey(led.targets, n)]
    isempty(tnames) && return Dict{String,Any}("ok" => true, "localOnly" => true,
        "url" => built.url, "docCount" => built.docCount, "results" => Any[])
    return sync_site!(String(siteName); on_event = on_event, hub = hub)  # push the whole build to all destinations
end

# The ledger name to use for a github-pages `repo` — an existing target for that repo, else a fresh
# name auto-derived from the repo (its last path segment, e.g. "you/portfolio" → "portfolio").
function _target_name_for_repo(led, repo::AbstractString)
    for (name, t) in led.targets
        (t.kind == "github-pages" && String(get(t.config, "repo", "")) == String(repo)) && return name
    end
    segs = filter(!isempty, split(String(repo), '/'))
    return isempty(segs) ? "github" : String(last(segs))
end

"""
    record_publish_site!(nb, repo, result) -> String

Reflect a successful `publish_site` to `repo` in the ledger: ensure a github-pages target for the repo
(auto-named, reusing an existing one), ensure this notebook's document (assigned to that target), and
append a publish event (live URL, commit SHA, deploy status). Returns the target name. Best-effort —
a ledger failure is logged and never fails the publish itself.
"""
function record_publish_site!(nb::LiveNotebook, repo::AbstractString, result)
    tname = ""
    try
        store = PublishLedger.default_store()
        led = PublishLedger.load(store)
        tname = _target_name_for_repo(led, repo)
        get!(led.targets, tname,
             PublishLedger.Target(tname, "github-pages"; config = Dict{String,Any}("repo" => String(repo))))
        di = _ensure_doc!(led, nb; target_names = [tname])
        ok = get(result, :pagesEnabled, true) !== false
        PublishLedger.record_event!(led, di.docId, tname;
            status = ok ? "ok" : "error",
            url = String(get(result, :docUrl, get(result, :url, ""))),
            commit = String(get(result, :commit, "")),
            note = String(get(result, :deployStatus, "")))
        PublishLedger.save(store, led)
    catch e
        @warn "slate: ledger recording after publish failed" exception = e
    end
    return tname
end

# ── multi-target publish with SSE progress ─────────────────────────────────────────────────────────
# Summarise per-target results for the SSE `done` event / a tool return.
function _publish_summary(names, results)
    return Dict{String,Any}("ok" => all(r -> r.ok, results),
        "results" => [Dict{String,Any}("target" => String(n), "ok" => r.ok, "status" => r.status,
                                       "url" => r.url, "doi" => r.doi, "commit" => r.commit,
                                       "log" => r.log) for (n, r) in zip(names, results)])
end

# ── Publish targets vs. archives ──────────────────────────────────────────────
# Two different verbs share the target store. PUBLISH targets are re-pushable live
# destinations (GitHub Pages, S3/R2, rsync, …) — pushing again replaces the site.
# ARCHIVE kinds (Zenodo today) mint a PERMANENT, immutable, citable version per
# deposit — incompatible with incremental pushes, so they are never part of a site
# publish: minting is its own deliberate act (the 📄 Archive button / slate.archive).
const _ARCHIVE_KINDS = ("zenodo",)
_is_archive_kind(kind) = String(kind) in _ARCHIVE_KINDS

"Names of the configured targets that are ARCHIVES (see `_ARCHIVE_KINDS`), from the live ledger."
function archive_target_names()
    led = PublishLedger.load(PublishLedger.default_store())
    return String[String(n) for (n, t) in led.targets if _is_archive_kind(t.kind)]
end

# Verb/kind agreement for a publish run (pure — unit-tested): the error message when the named
# targets don't fit the verb, else `nothing`. All names must already exist in `led.targets`.
function _verb_mismatch(led, names, archive::Bool)
    arch = [n for n in names if _is_archive_kind(led.targets[n].kind)]
    if !archive && !isempty(arch)
        return "$(join(arch, ", ")) mint(s) a permanent, immutable DOI version — archives are a " *
               "deliberate act, not part of site publishing. Use the 📄 Archive button (or slate.archive)."
    end
    if archive && length(arch) != length(names)
        return "not archive target(s): $(join(setdiff(names, arch), ", ")) — an archive run deposits " *
               "to archive kinds ($(join(_ARCHIVE_KINDS, ", "))) only; live sites go through a normal publish."
    end
    return nothing
end

"""
    run_publish(nb, target_names; archive=false, on_event=nothing, build opts…) -> summary::Dict

Load the ledger, ensure this notebook's document + its targets, resolve secrets from the config home,
fan out the publish concurrently (forwarding the site-build options to each adapter), record one
event per target, and persist. `on_event(i, phase, payload)` streams progress. Throws if a named
target isn't configured.

Publishing and archiving are DIFFERENT VERBS on the same store: with `archive=false` (default) every
named target must be a re-pushable live destination — an archive kind (Zenodo) is refused, because a
deposit mints a permanent immutable version and must never ride along with a site push. With
`archive=true` the run is a deliberate archival: every named target must be an archive kind.
"""
function run_publish(nb::LiveNotebook, target_names; archive::Bool = false, on_event = nothing,
                     slug = "", site_title = "",
                     theme = "dark", outputs = "all", source = true, bundle = false, history = false)
    names = collect(String, target_names)
    isempty(names) && error("no targets selected")
    store = PublishLedger.default_store()
    led = PublishLedger.load(store)
    missing = [n for n in names if !haskey(led.targets, n)]
    isempty(missing) || error("unconfigured target(s): $(join(missing, ", ")) — add them in the manager first")
    mismatch = _verb_mismatch(led, names, archive)
    mismatch === nothing || error(mismatch)
    di = _ensure_doc!(led, nb; target_names = names)
    secrets = _secrets_load()
    slg = isempty(strip(String(slug))) ? di.slug : String(slug)
    results = publish_document!(nb, led, di.docId, store; target_names = names, secrets = secrets,
                               slug = slg, site_title = String(site_title), theme = String(theme),
                               outputs = String(outputs), include_source = source, bundle = bundle,
                               history = history, on_event = on_event)
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
    # `archive=1` marks a deliberate deposit (the 📄 Archive button) — see run_publish.
    is_archive = get(q, "archive", "0") == "1"
    # site-build options (forwarded to the adapters; ignored by archive kinds)
    bopts = (slug = get(q, "slug", ""), site_title = get(q, "siteTitle", ""),
             theme = get(q, "theme", "dark"), outputs = get(q, "outputs", "all"),
             source = get(q, "source", "1") != "0", bundle = get(q, "bundle", "0") == "1",
             history = get(q, "history", "0") == "1")
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
            summary = run_publish(nb, names; archive = is_archive, on_event = on_event, slug = bopts.slug,
                                  site_title = bopts.site_title, theme = bopts.theme, outputs = bopts.outputs,
                                  source = bopts.source, bundle = bopts.bundle, history = bopts.history)
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

# Shared SSE streamer: run `run_fn(on_event)` in a task feeding a channel, emit status/log/done/failed.
function _sse_stream(stream::HTTP.Stream, run_fn)
    HTTP.setheader(stream, "Content-Type" => "text/event-stream")
    HTTP.setheader(stream, "Cache-Control" => "no-cache")
    HTTP.startwrite(stream)
    emit = function (ev::AbstractString, data::AbstractString)
        io = IOBuffer(); println(io, "event: ", ev)
        for ln in split(data, '\n'); println(io, "data: ", ln); end
        println(io)
        try; write(stream, String(take!(io))); return true; catch; return false; end
    end
    ch = Channel{Tuple{String,String}}(128)
    task = @async begin
        try
            on_event = function (_i, phase, payload)
                if phase === :status
                    put!(ch, ("status", String(payload)))
                elseif phase === :log
                    put!(ch, ("log", String(payload)))
                elseif phase === :start
                    put!(ch, ("status", "Deploying to $(target_name(payload))…"))
                else
                    r = payload; tag = r.ok ? "✓" : "✗"
                    detail = !isempty(r.doi) ? r.doi : !isempty(r.url) ? r.url : r.status
                    put!(ch, ("log", "$tag $detail"))
                    r.ok || isempty(strip(r.log)) || put!(ch, ("log", first(split(strip(r.log), '\n'))))
                end
            end
            put!(ch, ("done", JSON.json(run_fn(on_event))))
        catch e
            put!(ch, ("failed", sprint(showerror, e)))
        finally
            close(ch)
        end
    end
    for (ev, data) in ch; emit(ev, data) || break; end
    try; wait(task); catch; end
    return
end

# Build a notebook into a site's canonical local dir, then sync the whole build to its destinations.
# The notebook is named by the route id (an OPEN notebook) OR — so the manager can publish a recent
# notebook without the user opening it first — by a `path` query param, which is opened on demand
# (spawns its worker + runs it, exactly like opening it in the browser would).
function _sse_site_publish(stream::HTTP.Stream, h::Hub)
    uri = HTTP.URI(stream.message.target); q = HTTP.queryparams(uri)
    m = match(r"^/api/([^/]+)/site-publish", uri.path); id = m === nothing ? "" : String(m.captures[1])
    nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
    site = get(q, "site", "")
    if nb === nothing
        path = expanduser(String(get(q, "path", "")))
        if !isempty(path) && isfile(path)
            nb = try
                nid = open_notebook!(h, path)          # open on demand → its worker runs it
                find_live(h, nid)
            catch e
                return _sse_stream(stream, _oe -> error("could not open $(basename(path)): " * sprint(showerror, e)))
            end
        end
    end
    nb === nothing && return _sse_stream(stream, _oe -> error("no such notebook: $id"))
    isempty(site) && return _sse_stream(stream, _oe -> error("no site given"))
    bopts = (slug = get(q, "slug", ""), site_title = get(q, "siteTitle", ""),
             theme = get(q, "theme", "dark"), outputs = get(q, "outputs", "all"),
             include_source = get(q, "source", "1") == "1", bundle = get(q, "bundle", "0") == "1",
             history = get(q, "history", "0") == "1")
    _sse_stream(stream, on_event -> publish_to_site!(nb, String(site); on_event = on_event, bopts...))
end

# Re-sync a site (deploy its current canonical build to all destinations) — no notebook needed.
function _sse_site_sync(stream::HTTP.Stream, h::Hub)
    site = get(HTTP.queryparams(HTTP.URI(stream.message.target)), "site", "")
    isempty(site) && return _sse_stream(stream, _oe -> error("no site given"))
    _sse_stream(stream, on_event -> sync_site!(String(site); on_event = on_event, hub = h))
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
    # Delete a target (global). Local removal by default; `purge:true` also tears down its
    # deployed content where feasible.
    HTTP.register!(router, "POST", "/api/publish/target-delete", req -> begin
        b = _body(req)
        name = strip(String(get(b, "name", "")))
        isempty(name) && return HTTP.Response(400, "missing target name")
        _json(publish_target_delete!(name; purge = get(b, "purge", false) === true))
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
    # A published github-pages site's docs (with section/order) — for the manager's reorder view (global).
    HTTP.register!(router, "GET", "/api/publish/site-docs", req -> begin
        repo = strip(String(get(HTTP.queryparams(HTTP.URI(req.target)), "repo", "")))
        isempty(repo) && return HTTP.Response(400, "missing repo")
        _json(Dict("repo" => repo, "docs" => published_site_docs(String(repo))))
    end)
    # Apply a new section/order to a site's docs and re-push just the manifest + index (global).
    HTTP.register!(router, "POST", "/api/publish/site-reorder", req -> begin
        b = _body(req)
        repo = strip(String(get(b, "repo", "")))
        ordering = get(b, "ordering", Any[])
        isempty(repo) && return HTTP.Response(400, "missing repo")
        try
            r = reorder_published_site(String(repo), ordering)
            _json(Dict("ok" => r.ok, "changed" => r.changed, "url" => r.url, "commit" => r.commit))
        catch e
            HTTP.Response(500, "Reorder failed: " * sprint(showerror, e))
        end
    end)
    # ── Sites: the logical publishing unit (a canonical build synced to many destinations) ──
    # Create/update a site: its name, the destination targets it syncs to, and an optional home doc (global).
    HTTP.register!(router, "POST", "/api/publish/site", req -> begin
        b = _body(req)
        name = strip(String(get(b, "name", "")))
        isempty(name) && return HTTP.Response(400, "missing name")
        targets = [String(t) for t in get(b, "targets", Any[])]
        # A body that OMITS home/title/paths keeps the site's existing values (a targets-only save
        # must not wipe them); sending an explicit "" clears.
        old = get(PublishLedger.load(PublishLedger.default_store()).sites, String(name), nothing)
        home = haskey(b, "home") ? String(get(b, "home", "")) : (old === nothing ? "" : old.home)
        title = haskey(b, "title") ? String(get(b, "title", "")) : (old === nothing ? "" : old.title)
        paths = if haskey(b, "paths")
            pv = get(b, "paths", Dict{String,Any}())
            pv isa AbstractDict ? Dict{String,String}(String(k) => String(v) for (k, v) in pairs(pv)) : Dict{String,String}()
        else
            old === nothing ? Dict{String,String}() : copy(old.paths)
        end
        try
            _json(publish_site_set!(name, targets, home, title; paths = paths))
        catch e
            HTTP.Response(400, "Save site failed: " * sprint(showerror, e))   # 400: usually a location clash
        end
    end)
    # Delete a site: the definition + the local build always; `purge:true` also tears down
    # deployed content on the site's targets where feasible.
    HTTP.register!(router, "POST", "/api/publish/site-delete", req -> begin
        b = _body(req)
        name = strip(String(get(b, "name", "")))
        isempty(name) && return HTTP.Response(400, "missing name")
        try
            _json(publish_site_delete!(name; purge = get(b, "purge", false) === true))
        catch e
            HTTP.Response(500, "Delete site failed: " * sprint(showerror, e))
        end
    end)
    # Site content management — the docs in a site's LOCAL canonical build (with section/order); reorder
    # + section them; remove one. All edit _site_dir(name) only — Sync afterward pushes to destinations.
    HTTP.register!(router, "GET", "/api/publish/site-content", req -> begin
        site = strip(String(get(HTTP.queryparams(HTTP.URI(req.target)), "site", "")))
        isempty(site) && return HTTP.Response(400, "missing site")
        _json(Dict("site" => site, "docs" => site_docs(String(site))))
    end)
    HTTP.register!(router, "POST", "/api/publish/site-arrange", req -> begin
        b = _body(req); site = strip(String(get(b, "site", ""))); ordering = get(b, "ordering", Any[])
        isempty(site) && return HTTP.Response(400, "missing site")
        try
            r = reorder_site!(String(site), ordering)
            _json(Dict("ok" => r.ok, "docCount" => r.docCount))
        catch e
            HTTP.Response(500, "Arrange failed: " * sprint(showerror, e))
        end
    end)
    HTTP.register!(router, "POST", "/api/publish/site-remove", req -> begin
        b = _body(req); site = strip(String(get(b, "site", ""))); slug = strip(String(get(b, "slug", "")))
        (isempty(site) || isempty(slug)) && return HTTP.Response(400, "missing site/slug")
        try
            r = unexport_from_site(String(site), String(slug))
            _json(Dict("ok" => true, "removed" => r.removed, "docCount" => r.docCount))
        catch e
            HTTP.Response(500, "Remove failed: " * sprint(showerror, e))
        end
    end)
    return router
end
