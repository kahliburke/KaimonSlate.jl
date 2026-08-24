# Part of the NotebookServer submodule — included by server.jl. Names here resolve in NotebookServer.
#
# ── App mode: a notebook served as a finished application ────────────────────────────────────────
#
# Slate's normal posture is an AUTHORING environment: every cell is editable, the agent is a click
# away, and the whole package tree is reachable from the Files panel. That is exactly wrong when the
# audience is a domain expert who was handed a URL and told to use the tool — they need the
# controls and the results, and nothing that can put the document into a state they can't recover
# from.
#
# App mode is that second posture. It is a property of the PROCESS, not of the document: a hub
# started with `app=true` serves its notebooks as applications and refuses the authoring API
# outright. Deliberately not a per-notebook footer flag — a document attribute is something an
# author edits by accident, and "can this request mutate my notebook?" should not depend on a token
# inside the file being served. `?app=1` on a normal hub gives the author the same VIEW for
# previewing, with none of the enforcement.
#
# This is not authentication. Slate has none: anything that can reach the port can drive the
# controls, run the fits, and read the results. What app mode guarantees is narrower and still
# worth having — a visitor cannot edit a cell, install a package, reach the filesystem, talk to the
# agent, or publish, because those routes are not served at all.

# The allowlist is written as (method, path) patterns rather than by excluding the dangerous routes.
# A denylist over ~130 routes is a standing invitation to a miss: every new authoring endpoint is
# reachable until someone remembers to exclude it, and the failure is silent. An allowlist fails the
# other way — a new route is unreachable in app mode until it's deliberately added — which is the
# direction a lockdown should fail in.

# What a player needs to GET: the page shell and its assets, the notebook state, the live event
# streams, and the blobs that outputs reference.
const _APP_GET = (
    r"^/$",                          # → redirected to the app's notebook (see `_app_root_target`)
    r"^/status$",                    # operator page — vitals, uptime, logs
    r"^/api/status(/|$)",            # its JSON feed + the worker-log tail
    r"^/assets/",                    # page shell CSS/JS, vendored libs, maps
    r"^/ext-assets/",                # package-vendored front-end trees (SEB `provide_assets!`)
    r"^/n/[^/]+$",                   # the notebook page itself
    r"^/n/[^/]+/asset/",             # sibling files the notebook reads (`@asset`)
    r"^/n/[^/]+/served/",            # content-addressed extension assets
    r"^/api/[^/]+/state$",           # full state (initial paint + SSE reconnect)
    r"^/api/[^/]+/events$",          # SSE
    r"^/api/[^/]+/ws$",              # per-page WebSocket (`slateCall`, live frames)
    r"^/api/[^/]+/blob/",            # figures, animation frames, `save_asset` bytes (→ downloads)
    r"^/api/[^/]+/output/",          # the full text behind a truncated result
    r"^/api/[^/]+/health$",          # watchdog badge
    r"^/api/version$",               # which Slate is serving this app — the first line of any report
)

# What a player needs to POST. Every one of these drives the *running* document; none of them can
# change what the document IS.
const _APP_POST = (
    r"^/api/[^/]+/bind/",            # a control moved — the whole point of an app
    r"^/api/[^/]+/upload-file$",     # `FileUpload` → the notebook's datadir
    r"^/api/[^/]+/table-page$",      # paging a rendered table
    r"^/api/[^/]+/cancel$",          # stop a long computation (`@onclick` bodies are cancellable)
    r"^/api/[^/]+/launch$",          # wake an inactive notebook (the launch pill)
    r"^/api/[^/]+/eval-result$",     # browser→server return path for `request_live_eval`
    r"^/api/[^/]+/inspect-result$",  # ditto, for rendered-DOM inspection
    r"^/api/[^/]+/compfig-result$",  # ditto, for a component's print figure (a reader exporting a PDF)
    r"^/api/[^/]+/diag$",            # client diagnostics → what `/status` reports
)

_app_mode(h::Hub) = h.app

# Is this request one an app-mode hub serves? Matched on the PATH only (query strings never widen
# the set), against the method's allowlist. Anything unmatched is refused.
function _app_route_allowed(method::AbstractString, target::AbstractString)::Bool
    path = String(first(split(target, '?')))
    pats = method == "GET" || method == "HEAD" ? _APP_GET :
           method == "POST" ? _APP_POST : return false
    return any(p -> occursin(p, path), pats)
end

# The refusal. Deliberately explicit rather than a 404: an operator tailing the log while wondering
# why the Files panel is missing should be told the posture, not left guessing at a broken route.
_app_denied(target::AbstractString) = HTTP.Response(403,
    ["Content-Type" => "application/json", "Cache-Control" => "no-store"],
    JSON.json(Dict("ok" => false, "app" => true,
                   "error" => "This notebook is served as an application; the authoring API is not available.",
                   "route" => String(first(split(target, '?'))))))

# `/` on an app hub is the notebook, not the switcher. One notebook is the overwhelmingly common
# case (an exported app serves exactly one); with several, the first by insertion wins so the URL is
# at least stable within a run.
function _app_root_target(h::Hub)
    id = lock(h.lock) do
        ks = collect(keys(h.notebooks))
        isempty(ks) ? nothing : first(sort(ks))
    end
    return id === nothing ? nothing : "/n/$id"
end

# ── Presentation defaults ────────────────────────────────────────────────────────────────────────
#
# The settings that shape what a READER sees — theme, how wide the column runs, how big figures are
# allowed to get, whether the wheel zooms a chart. In the authoring UI these live in localStorage
# and each visitor discovers them through the Settings modal. An app has no Settings modal (it's
# authoring chrome) and, more importantly, a deployer has an opinion: an app projected on a lab wall
# wants `daylight` and full width, and asking every visitor to set that themselves is absurd.
#
# So the hub carries defaults and the page applies them for a visitor who has expressed no
# preference of their own. A visitor who HAS chosen keeps their choice — the app's settings popover
# offers the same reader-facing subset, and localStorage still wins.

# name → (localStorage key, coercion). Values are passed through verbatim to the page, which owns
# the actual application (the setters already exist in settings.js and are live).
const _APP_SETTING_KEYS = Dict{String,String}(
    "theme"      => "slateTheme",        # one of settings.js SLATE_UI_THEMES
    "fullwidth"  => "slateFullWidth",    # true → page spans the window
    "pagewidth"  => "slatePageMax",      # px, the constrained reading column
    "figwidth"   => "slateFigMax",       # px cap on rendered figures
    "scrollzoom" => "slateScrollZoom",   # percent; 0 = wheel never zooms a chart
    "wrapoutput" => "slateWrapOutput")   # true → wrap wide text output instead of scrolling it

"""
    app_defaults(; theme, fullwidth, pagewidth, figwidth, scrollzoom, wrapoutput) -> Dict{String,Any}

The presentation an app's visitor gets **before expressing a preference of their own**. Pass the
result as `appdefaults` to [`export_app`](@ref) or [`start_server`](@ref).

These are defaults, not enforcement: a visitor who has chosen keeps their choice, because the app's
settings popover offers the same reader-facing subset and `localStorage` still wins.

- `theme` — a Slate palette name (`"daylight"`, `"midnight"`, `"nord"`, …)
- `fullwidth` — `true` spans the window instead of a constrained reading column
- `pagewidth` / `figwidth` — px: the reading column, and a cap on rendered figures
- `scrollzoom` — percent; `0` means the wheel never zooms a chart
- `wrapoutput` — `true` wraps wide text output instead of scrolling it

An unrecognised name is dropped rather than guessed at, so a typo silently has no effect rather than
being applied to the wrong setting.

```julia
export_app(nb, "dist/myapp"; appdefaults = app_defaults(theme = "midnight", pagewidth = 1400))
```
"""
function app_defaults(; kw...)
    d = Dict{String,Any}()
    for (k, v) in pairs(kw)
        key = get(_APP_SETTING_KEYS, String(k), "")
        isempty(key) && continue
        d[key] = v isa Bool ? (v ? "1" : "0") : string(v)
    end
    return d
end

# ── Scripts an app doesn't load at all ───────────────────────────────────────────────────────────
#
# Neutralising a feature's ENTRY POINTS (appmode.js) stops a reader reaching it. Not shipping the
# script at all is better where it's possible: no dead DOM, no listeners, no timers, no background
# fetches at routes the server refuses, and less JavaScript parsed on a machine that may be modest.
#
# The list is conservative, and deliberately so — dropping a file another one calls into is a
# ReferenceError that kills the page, and the page is the whole product. Every name here was checked
# for callers outside itself; what's absent is as considered as what's present:
#
#   regions.js   `cellAssignedRegion` is called UNGUARDED by view.js while rendering every cell.
#   inspect.js   handles the `js:` events behind `request_live_eval` — `eval-result` is an ALLOWED
#                app route, so this path is live for a reader, not just for an agent.
#   agent.js     `agentEvent`/`setWorking`/`_agentNote` are referenced bare by panels.js/settings.js.
#   dragdrop.js  `_cellById`/`hideControlPicker` are called bare by cellops.js — they'd have to go
#                together, and cellops is closer to the render path than is worth risking here.
#   editor.js    owns `_slateRunCellAction`, which backs `@cell_action` buttons — a READER feature.
#   dialogs.js   owns alertDark/confirmDark/showLoading/hideLoading, used across the app.
#
# Anything still referenced from a kept file goes through `window.x && window.x()` or a `typeof`
# guard, which is why these are safe to remove rather than merely unused.
const _APP_SKIP_SCRIPTS = (
    "publishing.js",   # publish + site deploy flows
    "files.js",        # the project file browser/editor
    "config.js",       # the notebook config panel
    "workers.js",      # worker log/status popup (an app's operator view is /status)
    "runloc.js",       # run-location picker (where the worker runs)
    "trace.js",        # the @trace inspector modal
    "dag.js",          # the dataflow graph pane
    "palette.js",      # ⌘K command palette, control snippets, the docs browser
)
# Vendor code loaded solely FOR one of the above; the graph library is ~100 kB parsed for a pane the
# app has no way to open.
const _APP_SKIP_VENDOR = ("dagre/dagre.min.js",)

# Drop those `<script src=…>` tags from the shell. Substring removal on the exact tag, not a regex
# over the whole document — the shell is hand-written HTML with comments beside some tags, and a
# greedy pattern here would be a silent way to delete the wrong line.
function _strip_app_scripts(html::AbstractString)
    out = String(html)
    for name in _APP_SKIP_SCRIPTS
        out = replace(out, "<script src=\"/assets/js/$name\"></script>" => "")
    end
    for name in _APP_SKIP_VENDOR
        out = replace(out, "<script src=\"/assets/vendor/$name\"></script>" => "")
    end
    return out
end

# The bootstrap object the page shell reads before its first paint — app posture plus the defaults.
# Injected by replacing the `window.__SLATE_APP__=null;` placeholder in notebook.html, the same
# idiom `_index_html` uses for the publish ledger. `</` is escaped: this lands inside a <script>.
function _inject_app(html::AbstractString, h::Hub, nb = nothing)
    payload = Dict{String,Any}("on" => h.app, "defaults" => h.appdefaults)
    js = replace(JSON.json(payload), "</" => "<\\/")
    out = replace(String(html), "window.__SLATE_APP__=null;" => "window.__SLATE_APP__=" * js * ";"; count = 1)
    h.app && (out = _strip_app_scripts(out))
    # The browser tab, window list and bookmark all read `<title>`. "Kaimon Slate" is right for an
    # authoring session — it names the tool you're in — and wrong for a deployed app, where the
    # reader has no idea what Kaimon Slate is and every app would be indistinguishable from every
    # other. Substituted SERVER-SIDE rather than assigned from JS so the tab is never briefly wrong.
    if h.app && nb !== nothing
        # The frontmatter title (the `role=title` cell, or the first H1) — NOT `report.title`,
        # which falls back to the filename, so a tab would read "app" instead of the real name.
        t = try; strip(report_frontmatter(nb.report).title); catch; ""; end
        isempty(t) || (out = replace(out, "<title>Kaimon Slate</title>" =>
                                          "<title>" * _esc(t) * "</title>"; count = 1))
    end
    return out
end

# ── Warm-up gate ─────────────────────────────────────────────────────────────────────────────────
#
# `_await_http_ready` proves the SOCKET answers. For an authoring session that is the right bar — you
# open the page and watch the cells run, each showing its own state. An app's reader sees no cells and
# no worker pill, so a URL announced at that moment leads to a page of headings that sits there doing
# nothing for minutes while the environment precompiles and the first pass runs.
#
# So an app waits for the notebook to be COMPUTED before the banner names a URL, and narrates the wait
# on the terminal, where the person who started it can see it. Bounded: a warm-up that never finishes
# still has to yield a usable address (with `/status` to explain why) rather than hang the launcher
# forever with nothing to open.

# Snapshot the notebooks under the hub lock, then read each report through its OWN lock — never both
# at once (see the nb.lock protocol), which is also what `_status_json` does.
function _app_warm_state(h::Hub)
    nbs = lock(h.lock) do; collect(values(h.notebooks)); end
    starting = 0; running = 0
    for nb in nbs
        get(nb.report.meta, "hydrating", false) === true && (starting += 1)
        running += with_report(nb) do r; count(c -> c.state == RUNNING, r.cells); end
    end
    return (starting, running)
end

function _await_app_warm(h::Hub; timeout::Real = 900, io::IO = stdout)
    t0 = time()
    tty = io isa Base.TTY && get(ENV, "NO_COLOR", "") == ""
    spin = ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
    i = 0
    # Require a few consecutive quiet polls: the reactive graph runs cell by cell, so a single quiet
    # sample lands in the gap BETWEEN two cells and would call a mid-run notebook ready.
    settled = 0
    while time() - t0 < timeout
        starting, running = _app_warm_state(h)
        if starting == 0 && running == 0
            settled += 1
            settled >= 3 && (tty && print(io, "\r\e[K"); return true)
        else
            settled = 0
        end
        if tty
            i += 1
            phase = starting > 0 ? "preparing the environment" :
                    running > 0  ? "computing" * (running > 1 ? " ($running cells)" : "") :
                                   "finishing up"
            print(io, "\r  \e[38;5;117m$(spin[mod1(i, length(spin))])\e[0m $phase \e[2m· $(_uptime_str(time() - t0))\e[0m\e[K")
        end
        sleep(0.25)
    end
    tty && print(io, "\r\e[K")
    return false
end

# ── FileUpload: a reader's file into the notebook's datadir ──────────────────────────────────────
#
# Every other control sends a JSON scalar; this one sends bytes, which is the only reason it needs a
# route of its own. What happens AFTER the bytes land is deliberately not new: the file is written
# under `datadir()` and then bound through `set_bind!`, exactly as the slider route does — so the
# reactive graph, the restaling of reader cells, the footer persistence and the `@onchange` hooks
# are the ones that already exist, and there is no second notion of "a control changed".
#
# The file goes to the HUB's `<project>/data`, which is what `datadir()` resolves to for a local
# worker (the deployment case: hub and worker share a filesystem). A REMOTE worker picks it up
# through the datadir transport that already syncs this directory before a remote run
# (`_sync_datadir_to!`) — so remote works without a second upload path to keep correct.

const _UPLOAD_MAX_DEFAULT = 128 * 1024 * 1024   # 128 MB unless the widget says otherwise

# A reader-supplied filename is untrusted input that becomes a real path. Keep the readable stem
# (people recognise their own file in the UI) but strip everything that could traverse or surprise:
# directory separators, `..`, leading dots, control characters.
function _safe_upload_name(name::AbstractString)
    base = basename(replace(String(name), '\\' => '/'))
    clean = replace(base, r"[^A-Za-z0-9._ -]" => "_")
    clean = strip(clean, ['.', ' '])
    isempty(clean) && (clean = "upload")
    return first(clean, 120)
end

# Store one uploaded file for `nb` and return its record (the value a `fileupload` bind carries).
# Collisions keep BOTH files rather than overwriting: a reader who uploads the same filename twice
# usually means two runs of something, not "replace the first one" — and the first may still be
# referenced by a result already on the page.
function _store_upload!(nb::LiveNotebook, name::AbstractString, bytes::Vector{UInt8}, mime::AbstractString)
    root = _proj_root(nb)
    isempty(root) && error("this notebook has no project directory, so it has nowhere to put an upload")
    dir = joinpath(root, "data")
    mkpath(dir)
    # `datadir()` self-ignores in git (see widgets.jl); mirror that when we create it first.
    gi = joinpath(dir, ".gitignore")
    isfile(gi) || (try; write(gi, "*\n"); catch; end)
    safe = _safe_upload_name(name)
    stem, ext = splitext(safe)
    path = joinpath(dir, safe)
    n = 1
    while isfile(path)
        n += 1
        path = joinpath(dir, string(stem, "-", n, ext))
    end
    write(path, bytes)
    return Dict{String,Any}("name" => String(name), "path" => path, "size" => length(bytes),
                            "mime" => String(mime), "uploaded" => time())
end

# ── /status: the operator's view of a deployed app ───────────────────────────────────────────────
#
# An app has two processes: the HUB (this one — HTTP, notebook state) and the WORKER (a separate
# Julia process where cells actually evaluate). When the person who deployed it gets told "the page
# is stuck", the question is which of the two is unwell, and the notebook UI deliberately hides the
# panels that would answer it. `/status` is the answer: one page, reachable in app mode, that reads
# only in-memory state and a log file — no worker round-trip, so it stays truthful precisely when
# the worker is the thing that's wedged.

const _HUB_STARTED = Ref(0.0)   # stamped by `start_hub`; 0 until then

_uptime_str(secs::Real) = secs <= 0 ? "—" : begin
    s = round(Int, secs); d, s = divrem(s, 86400); h, s = divrem(s, 3600); m, s = divrem(s, 60)
    d > 0 ? "$(d)d $(h)h $(m)m" : h > 0 ? "$(h)h $(m)m" : m > 0 ? "$(m)m $(s)s" : "$(s)s"
end

_mb(bytes::Real) = bytes <= 0 ? 0.0 : round(bytes / 1024^2; digits = 1)

# One worker's vitals, from the telemetry ring the hub already keeps (the worker PUBs a sample every
# 2s). Everything is guarded: `/status` exists to be readable when things are broken, so a missing
# or malformed sample degrades to "unknown" rather than taking the page down with it.
# Every kernel this notebook evaluates on. `_nb_kernels` answers a narrower question (which GATE
# kernels can be asked what they're running), so an in-process main kernel is absent from it — and a
# status page that silently reported "no workers" for a perfectly healthy notebook would be worse
# than no status page. Take its region half and put the main kernel back when it isn't a gate.
function _status_kernels(nb::LiveNotebook)
    ks = _nb_kernels(nb)
    any(k -> k === nb.kernel, ks) || pushfirst!(ks, nb.kernel)
    return ks
end

function _status_worker(nb::LiveNotebook, k)
    # No subprocess: cells evaluate in the HUB process, so its vitals ARE this notebook's. Say so
    # rather than showing an empty card — "where does my code run" is the first question /status
    # should answer, and the answer here is "right here".
    k isa ReportEngine.GateKernel || return Dict{String,Any}(
        "kind" => "in-process (runs inside the server)", "connected" => true, "alive" => true,
        "port" => 0, "pid" => getpid())
    cn = try; k.conn === nothing ? "" : String(k.conn.name); catch; ""; end
    st = isempty(cn) ? nothing : (try; ReportEngine.kernel_stats(cn); catch; nothing; end)
    alive = try; Base.process_running(k.proc); catch; false; end
    d = Dict{String,Any}(
        "kind" => "worker process",
        "port" => k.port,
        "connected" => k.conn !== nothing,
        "alive" => alive,
        "pid" => (try; getpid(k.proc); catch; 0; end),
        "project" => (try; k.project; catch; ""; end),
        "logpath" => (try; k.logpath; catch; ""; end),
        "logbytes" => (try; isfile(k.logpath) ? filesize(k.logpath) : 0; catch; 0; end))
    if st !== nothing
        l = st.latest
        d["cpu"] = round(l.cpu; digits = 1)
        d["rssMB"] = _mb(l.rss)
        d["evals"] = l.evals
        d["running"] = l.running
        d["sysCpu"] = round(l.sys_cpu; digits = 1)
        d["sysMemUsedMB"] = _mb(max(0, l.sys_mem_total - l.sys_mem_free))
        d["sysMemTotalMB"] = _mb(l.sys_mem_total)
        d["lastSampleAgo"] = round(time() - l.rcv; digits = 1)
        # A short RSS/CPU trail so a slow leak or a pinned core is visible as a shape, not one number.
        hist = st.history
        tail = @view hist[max(1, length(hist) - 119):end]
        d["rssTrail"] = [_mb(s.rss) for s in tail]
        d["cpuTrail"] = [round(s.cpu; digits = 1) for s in tail]
    end
    return d
end

# The app's health as JSON. Shape is deliberately flat and self-describing — it's read by the status
# page's own JS, but it is also the thing you curl from a lab machine over ssh.
function _status_json(h::Hub)
    nbs = lock(h.lock) do; collect(values(h.notebooks)); end
    docs = Any[]
    for nb in nbs
        cells, errs, title = with_report(nb) do report
            (report.cells, [c for c in report.cells if c.state == ERRORED], report.title)
        end
        push!(docs, Dict{String,Any}(
            "id" => nb.id,
            "title" => title,
            "path" => abspath(nb.path),
            "url" => "/n/$(nb.id)",
            # The lifecycle a visitor actually experiences: dormant → bringing its env up → live.
            "state" => get(nb.report.meta, "inactive", false) === true ? "inactive" :
                       get(nb.report.meta, "hydrating", false) === true ? "starting" : "live",
            "cells" => length(cells),
            "running" => count(c -> c.state == RUNNING, cells),
            "stale" => count(c -> c.state == STALE, cells),
            "errors" => length(errs),
            # The error TEXT, not just a count — this is the whole reason someone opens /status.
            "failures" => [Dict{String,Any}(
                "cell" => c.id,
                "message" => c.output === nothing || c.output.exception === nothing ? "" :
                             first(String(c.output.exception), 400)) for c in errs],
            "workers" => [_status_worker(nb, k) for k in _status_kernels(nb)]))
    end
    return Dict{String,Any}(
        "ok" => true,
        "app" => h.app,
        "hub" => Dict{String,Any}(
            "pid" => getpid(),
            "url" => _hub_url(h),
            "host" => h.host, "port" => h.port,
            "julia" => string(VERSION),
            # Which Slate built and is serving this. An app is usually operated by someone who did
            # not author it, from a machine where nothing else says what version is installed.
            "version" => (try; string(pkgversion(@__MODULE__)); catch; ""; end),
            "uptimeSec" => _HUB_STARTED[] == 0 ? 0.0 : round(time() - _HUB_STARTED[]; digits = 1),
            "uptime" => _uptime_str(_HUB_STARTED[] == 0 ? 0 : time() - _HUB_STARTED[]),
            # `maxrss` is the process PEAK, not the current footprint — labelled as such on the page
            # rather than quietly passed off as "memory now".
            "peakRssMB" => _mb(Sys.maxrss()),
            "heapMB" => _mb(Base.gc_live_bytes()),
            "threads" => Threads.nthreads(),
            "home" => get(ENV, "KAIMONSLATE_HOME", "")),
        "docs" => docs,
        "now" => time())
end

# The worker log tail, for the page's log pane. `?doc=` selects the notebook when more than one is
# served; `?lines=` bounds it.
function _status_log(h::Hub, docid::AbstractString, lines::Int)
    nbs = lock(h.lock) do; collect(values(h.notebooks)); end
    nb = isempty(docid) ? (isempty(nbs) ? nothing : first(nbs)) :
         findfirst(x -> x.id == docid, nbs) |> i -> i === nothing ? nothing : nbs[i]
    nb === nothing && return Dict{String,Any}("ok" => false, "error" => "no such notebook", "log" => "")
    k = nb.kernel
    txt = try; ReportEngine.worker_log_tail(k; lines = lines); catch e; "…could not read the worker log: $e"; end
    return Dict{String,Any}("ok" => true, "doc" => nb.id, "log" => txt)
end

# The status page. Deliberately self-contained — its own markup, styles and script, no shared
# bundle, no vendored library. The page exists to be readable when the notebook UI isn't, and
# depending on the same assets the broken thing depends on would defeat that.
function _status_html()
    return """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>Slate app — status</title>
<style>
  :root { --bg:#0d1120; --bg2:#141828; --bg3:#1b2033; --border:#2a2e40; --text:#d4d8e8;
          --dim:#8a90ad; --accent:#7cc0ff; --ok:#56d364; --warn:#e3b341; --bad:#f85149; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:14px/1.55 ui-sans-serif,system-ui,-apple-system,Segoe UI,sans-serif; }
  .wrap { max-width:1040px; margin:0 auto; padding:26px 20px 60px; }
  h1 { font-size:1.25rem; margin:0 0 2px; font-weight:600; }
  h2 { font-size:.95rem; margin:26px 0 10px; font-weight:600; color:var(--text); }
  .sub { color:var(--dim); font-size:.82rem; margin-bottom:20px; }
  .card { background:var(--bg2); border:1px solid var(--border); border-radius:10px; padding:14px 16px; margin-bottom:12px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px 18px; }
  .stat .k { color:var(--dim); font-size:.72rem; text-transform:uppercase; letter-spacing:.04em; }
  .stat .v { font-size:1.05rem; font-variant-numeric:tabular-nums; margin-top:1px; }
  .pill { display:inline-block; padding:1px 9px; border-radius:999px; font-size:.74rem;
          border:1px solid var(--border); background:var(--bg3); color:var(--dim); }
  .pill.ok { color:var(--ok); border-color:rgba(86,211,100,.4); }
  .pill.warn { color:var(--warn); border-color:rgba(227,179,65,.4); }
  .pill.bad { color:var(--bad); border-color:rgba(248,81,73,.4); }
  .row { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .muted { color:var(--dim); }
  .mono { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.78rem; }
  pre.log { background:#080b14; border:1px solid var(--border); border-radius:8px; padding:12px 14px;
            max-height:460px; overflow:auto; margin:0; white-space:pre-wrap; word-break:break-word;
            font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.76rem; color:#b9c0d8; }
  .fail { border-left:3px solid var(--bad); background:rgba(248,81,73,.07); padding:8px 12px;
          border-radius:0 6px 6px 0; margin:8px 0; }
  .fail .cid { color:var(--dim); font-size:.74rem; }
  .fail pre { margin:4px 0 0; white-space:pre-wrap; font-size:.76rem; color:#f0a9a4;
              font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
  a { color:var(--accent); }
  .spark { display:block; width:100%; height:34px; margin-top:6px; }
  .foot { color:var(--dim); font-size:.75rem; margin-top:28px; }
  label.auto { color:var(--dim); font-size:.78rem; margin-left:auto; cursor:pointer; }
</style>
</head>
<body>
<div class="wrap">
  <div class="row"><h1>Slate app · status</h1><span id="mode" class="pill"></span>
    <label class="auto"><input type="checkbox" id="auto" checked/> auto-refresh</label></div>
  <div class="sub" id="hubline">loading…</div>
  <div id="body"></div>
  <h2>Worker log</h2>
  <pre class="log" id="log">loading…</pre>
  <div class="foot" id="foot"></div>
</div>
<script>
const \$ = s => document.querySelector(s);
const esc = s => String(s == null ? '' : s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
const stat = (k, v) => `<div class="stat"><div class="k">\${esc(k)}</div><div class="v">\${v}</div></div>`;

// A one-line sparkline over a numeric trail — enough to see a leak climbing or a core pinned,
// which is the whole question a number alone can't answer.
function spark(values, colour) {
  if (!values || values.length < 2) return '';
  const w = 420, h = 34, max = Math.max(...values, 1e-9), min = Math.min(...values, 0);
  const span = (max - min) || 1;
  const pts = values.map((v, i) =>
    `\${(i / (values.length - 1) * w).toFixed(1)},\${(h - (v - min) / span * (h - 4) - 2).toFixed(1)}`).join(' ');
  return `<svg class="spark" viewBox="0 0 \${w} \${h}" preserveAspectRatio="none">
    <polyline fill="none" stroke="\${colour}" stroke-width="1.5" points="\${pts}"/></svg>`;
}

function workerCard(w) {
  const live = w.connected && w.alive !== false;
  const cls = live ? 'ok' : (w.alive ? 'warn' : 'bad');
  const label = live ? 'connected' : w.alive ? 'starting / reconnecting' : 'not running';
  // A stale telemetry sample is its own signal: the worker PUBs every 2s, so a gap means it is
  // wedged or gone even while the socket still reports "connected".
  const stale = w.lastSampleAgo != null && w.lastSampleAgo > 15;
  let s = `<div class="card"><div class="row" style="margin-bottom:10px">
      <strong>\${esc(w.kind)}</strong><span class="pill \${cls}">\${label}</span>
      \${w.port ? `<span class="muted mono">port \${w.port}\${w.pid ? ' · pid ' + w.pid : ''}</span>` : ''}
      \${stale ? `<span class="pill warn">no telemetry for \${w.lastSampleAgo}s</span>` : ''}
    </div><div class="grid">`;
  if (w.cpu != null) {
    s += stat('worker cpu', w.cpu + '%');
    s += stat('worker memory', w.rssMB + ' MB');
    s += stat('evals run', w.evals);
    s += stat('running now', (w.running || []).length);
    if (w.sysMemTotalMB) s += stat('host memory', w.sysMemUsedMB + ' / ' + w.sysMemTotalMB + ' MB');
    if (w.sysCpu >= 0) s += stat('host cpu', w.sysCpu + '%');
  } else {
    s += `<div class="muted">No telemetry yet — the worker has not started, or has not reported.</div>`;
  }
  s += '</div>';
  if (w.rssTrail) s += `<div class="k muted" style="margin-top:12px;font-size:.72rem">MEMORY (last few minutes)</div>` + spark(w.rssTrail, '#7cc0ff');
  if (w.cpuTrail) s += `<div class="k muted" style="margin-top:4px;font-size:.72rem">CPU</div>` + spark(w.cpuTrail, '#c586c0');
  if (w.logbytes) s += `<div class="muted mono" style="margin-top:10px">log \${(w.logbytes/1024).toFixed(0)} KB · \${esc(w.logpath)}</div>`;
  return s + '</div>';
}

function render(d) {
  \$('#mode').textContent = d.app ? 'app mode' : 'authoring';
  \$('#mode').className = 'pill ' + (d.app ? 'ok' : '');
  const h = d.hub;
  // The version links to its release notes: the operator reading this page is the person who has to
  // say which build is running, and often can't get at a Julia REPL to ask.
  const ver = h.version
    ? ` · <a href="https://github.com/kahliburke/KaimonSlate.jl/releases/tag/v\${encodeURIComponent(h.version)}"
             target="_blank" rel="noopener">Slate v\${esc(h.version)}</a>`
    : '';
  \$('#hubline').innerHTML =
    `Server up <strong>\${esc(h.uptime)}</strong> · pid \${h.pid} · Julia \${esc(h.julia)} · \${esc(h.host)}:\${h.port}\${ver}`;
  let out = `<div class="card"><div class="grid">
      \${stat('slate', h.version ? 'v' + esc(h.version) : '—')}
      \${stat('uptime', esc(h.uptime))}
      \${stat('julia heap', h.heapMB + ' MB')}
      \${stat('peak memory', h.peakRssMB + ' MB')}
      \${stat('threads', h.threads)}
    </div></div>`;
  for (const doc of d.docs) {
    const cls = doc.errors ? 'bad' : doc.state === 'live' ? 'ok' : 'warn';
    out += `<h2>\${esc(doc.title || doc.id)}</h2>
      <div class="card"><div class="row" style="margin-bottom:10px">
        <span class="pill \${cls}">\${esc(doc.state)}</span>
        <a href="\${esc(doc.url)}">open</a>
        <span class="muted mono">\${esc(doc.path)}</span>
      </div><div class="grid">
        \${stat('cells', doc.cells)}\${stat('running', doc.running)}
        \${stat('stale', doc.stale)}\${stat('errors', doc.errors)}
      </div></div>`;
    for (const f of doc.failures)
      out += `<div class="fail"><div class="cid">cell \${esc(f.cell)}</div><pre>\${esc(f.message)}</pre></div>`;
    for (const w of doc.workers) out += workerCard(w);
  }
  \$('#body').innerHTML = out;
  \$('#foot').textContent = 'Updated ' + new Date().toLocaleTimeString();
}

async function tick() {
  try { render(await (await fetch('/api/status')).json()); }
  catch (e) { \$('#body').innerHTML = '<div class="card">Could not reach the server: ' + esc(e) + '</div>'; }
  try { const r = await (await fetch('/api/status/log?lines=300')).json();
        const el = \$('#log'); const bottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 24;
        el.textContent = r.log || '(no worker log yet)';
        if (bottom) el.scrollTop = el.scrollHeight;
  } catch (e) {}
}
tick();
setInterval(() => { if (\$('#auto').checked) tick(); }, 3000);
</script>
</body>
</html>
"""
end

