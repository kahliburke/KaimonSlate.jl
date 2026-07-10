# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Cell-local completion ─────────────────────────────────────────────────────
# `REPLCompletions` only sees the live module, so identifiers a cell BINDS before
# it has run (assignments, `for`/`let`/`function`/generator vars, params) don't
# complete. We parse the cell's complete leading statements and union their bound
# names in — an over-approximation (ignores nested-scope visibility), which is fine
# for completion. Only for bare identifiers; field access (after `.`) is left to
# REPLCompletions.
_isidcu(b::UInt8) = (UInt8('a') <= b <= UInt8('z')) || (UInt8('A') <= b <= UInt8('Z')) ||
                    (UInt8('0') <= b <= UInt8('9')) || b == UInt8('_') || b == UInt8('!')

# (token-start-0based, typed-prefix, is-field-access) for the identifier at `pos`.
function _id_prefix(code::String, pos::Int)
    cu = codeunits(code)
    i = pos
    while i > 0 && _isidcu(cu[i]); i -= 1; end
    dotted = i >= 1 && cu[i] == UInt8('.')
    return (i, String(cu[(i + 1):pos]), dotted)
end

# Stable re-rank for the popup. Three tiers of the reader's own names float to the top, above
# general library symbols, and keywords sink; names of the same kind keep REPLCompletions'
# (alphabetical) order. `prefix` is the typed token — an exact match (you've already typed the whole
# name) drops to the bottom. Tiers: `local` = a binding in the CURRENT cell; `notebook` = a variable
# defined in ANOTHER cell (owned by the namespace, not imported); then general Base/package names.
const _KIND_RANK = Dict("local" => 0, "notebook" => 1, "field" => 2, "kwarg" => 2,
                        "var" => 3, "function" => 3, "type" => 3, "const" => 3, "module" => 3,
                        "method" => 3, "key" => 3, "path" => 3, "text" => 4, "latex" => 4,
                        "keyword" => 5)
function _rank_completions(items::Vector{Tuple{String,String}}, prefix::AbstractString)
    length(items) <= 1 && return items
    order = collect(enumerate(items))
    sort!(order; by = p -> (p[2][1] == prefix ? 1 : 0, get(_KIND_RANK, p[2][2], 3), p[1]))
    return [it for (_, it) in order]
end

# Names introduced at a binding site (LHS of `=`, params, `f(a,b)` def, `x::T`, …).
function _bind_names!(out::Set{Symbol}, x)
    if x isa Symbol
        x === :_ || push!(out, x)
    elseif x isa Expr
        h = x.head
        if h === :(::) || h === :(<:) || h === :kw || h === :(=) || h === :(...) || h === :curly
            isempty(x.args) || _bind_names!(out, x.args[1])
        elseif h === :tuple || h === :parameters || h === :call   # destructuring / def LHS+params
            for a in x.args
                _bind_names!(out, a)
            end
        end
    end
end

function _collect_binds!(out::Set{Symbol}, ex)
    ex isa Expr || return
    h = ex.head
    if h === :(=)
        _bind_names!(out, ex.args[1]); _collect_binds!(out, ex.args[2])
    elseif h === :function || h === :(->)
        _bind_names!(out, ex.args[1])
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :for
        spec = ex.args[1]
        for b in (spec isa Expr && spec.head === :block ? spec.args : (spec,))
            b isa Expr && b.head === :(=) && _bind_names!(out, b.args[1])
        end
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :generator || h === :comprehension || h === :flatten
        for a in ex.args
            (a isa Expr && a.head === :(=)) ? _bind_names!(out, a.args[1]) : _collect_binds!(out, a)
        end
    elseif h === :let
        binds = ex.args[1]
        for b in (binds isa Expr && binds.head === :block ? binds.args : (binds,))
            b isa Symbol ? push!(out, b) : (b isa Expr && b.head === :(=) && _bind_names!(out, b.args[1]))
        end
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :local || h === :global
        for a in ex.args; _bind_names!(out, a); end
    else
        for a in ex.args; _collect_binds!(out, a); end
    end
end

# All names bound by the cell's complete leading statements (stops at the first
# incomplete/erroring statement — typically the line being typed).
function _cell_locals(code::AbstractString)
    out = Set{Symbol}()
    s = String(code); n = ncodeunits(s); idx = 1
    while idx <= n
        ex, nxt = try
            Meta.parse(s, idx; raise = false)
        catch
            break
        end
        ex === nothing && break
        (ex isa Expr && (ex.head === :incomplete || ex.head === :error)) && break
        _collect_binds!(out, ex)
        nxt <= idx && break
        idx = nxt
    end
    return out
end

# Restart a notebook's kernel: kill its worker (a gate worker is a real subprocess;
# no-op in-process), then re-evaluate from a fresh namespace. The gate kernel
# respawns a worker on the next `prepare!`.
# Graceful stop: interrupt the worker's running cells WITHOUT killing the namespace. Only meaningful
# for a gate worker with cells in flight; the interrupted cells stream back as errors (via celldone)
# and the namespace + every already-finished result survives. Falls back to a full worker restart when
# there's nothing to gracefully interrupt (in-process kernel, no live worker, or no running cells) —
# matching the old stop-button behaviour. Returns the notebook.
function cancel_run!(nb::LiveNotebook)
    k = nb.kernel
    _PARALLEL_CANCEL[nb.id] = true            # stop the parallel scheduler from starting not-yet-run cells
    hasrunning = lock(nb.lock) do; any(c -> c.state == RUNNING, nb.report.cells); end
    if k isa ReportEngine.GateKernel && hasrunning
        n = ReportEngine.cancel_eval(k)
        if n >= 0
            @info "slate: run cancelled (namespace preserved)" notebook = nb.id interrupted = n
            try; _broadcast(nb, "cancelled:$n"); catch; end
            return nb
        end
    end
    return restart_kernel!(nb)
end

# Interrupt whatever is evaluating RIGHT NOW, without restarting or clearing the namespace — used just
# before we tear the kernel down for a run-location / worker switch. `shutdown!` grabs the kernel lock
# and an in-flight `eval_batch` blocks in its gate round-trip, so WITHOUT this the switch waits for the
# current cell to finish; `cancel_eval` lands while the batch is in flight and makes it return promptly.
# No restart fallback (unlike `cancel_run!`) — the caller re-picks the kernel next. Must be called
# OUTSIDE nb.lock (it does a gate round-trip). Returns the number of cells interrupted.
function _interrupt_inflight!(nb::LiveNotebook)
    _PARALLEL_CANCEL[nb.id] = true            # stop the scheduler starting not-yet-run cells
    k = nb.kernel
    hasrunning = lock(nb.lock) do; any(c -> c.state == RUNNING, nb.report.cells); end
    (k isa ReportEngine.GateKernel && hasrunning) || return 0
    n = ReportEngine.cancel_eval(k)
    return n < 0 ? 0 : n
end

function restart_kernel!(nb::LiveNotebook)
    # Tear down + reset synchronously (fast), mark a background re-run underway, and RETURN — the
    # full re-eval (which respawns the worker on prepare! and streams cells back) runs async, so the
    # user gets control back immediately instead of blocking until everything re-renders. Same
    # "open instantly" pattern as load_notebook.
    lock(nb.lock) do
        # An explicit restart must yield a FRESH worker — with a detached (still-warm) remote,
        # prepare!'s reattach-first would re-adopt the same process and the restart would no-op.
        try; ReportEngine.shutdown!(nb.kernel; kill_remote = true); catch; end
        ReportEngine.reset!(nb.kernel, nb.report)
        build_dependencies!(nb.report)
        nb.report.meta["hydrating"] = true
        nb.version += 1
    end
    _broadcast(nb, "restart")
    @async begin
        try
            _drain!(nb)            # respawns the worker + streams cells; WAIT for full completion so the
            lock(nb.lock) do       # hydrating banner stays up for the whole re-run
                delete!(nb.report.meta, "hydrating")
                nb.version += 1
            end
        catch e
            lock(nb.lock) do
                nb.report.meta["hydrate_error"] = sprint(showerror, e)
                delete!(nb.report.meta, "hydrating")
                nb.version += 1
            end
            @warn "KaimonSlate: worker-restart re-run failed" exception = (e, catch_backtrace())
        end
        try; _broadcast(nb, string(nb.version)); catch; end   # nudge the browser to pull the now-live cells
    end
    return nb
end

# Switch this notebook onto (or off) a remote worker. `spec` = "port,stream_port" reachable at
# 127.0.0.1 (e.g. forwarded over an SSH tunnel; see attach_gate_kernel); "" ⇒ back to a local worker.
# Tears down the current kernel, RE-PICKS the kernel type (remote attach vs local) via _select_kernel,
# and re-runs — async, same "instant" pattern as restart_kernel!. Runtime-only (not written to the .jl).
function set_remote_worker!(nb::LiveNotebook, spec::AbstractString)
    _interrupt_inflight!(nb)   # switching workers stops the current evaluation immediately (don't drain)
    lock(nb.lock) do
        s = strip(String(spec))
        isempty(s) ? delete!(nb.report.meta, "remoteworker") : (nb.report.meta["remoteworker"] = String(s))
        try; ReportEngine.shutdown!(nb.kernel); catch; end     # local → killed; remote → detached (idles warm)
        nb.kernel = _select_kernel(nb.path, nb.report)         # remote attach vs local, per the meta
        build_dependencies!(nb.report)
        # New worker → empty namespace → re-run every cell (this is what drives prepare!→attach). Cells
        # left FRESH would give the runner nothing to do and the worker would never be reached. See reset!.
        for c in nb.report.cells; c.state = STALE; c.output = nothing; end
        nb.report.meta["hydrating"] = true
        nb.version += 1
    end
    _broadcast(nb, "restart")
    @async begin
        try
            _drain!(nb)                                        # first eval → prepare! attaches to the worker
        catch e
            @warn "KaimonSlate: remote-worker switch re-run failed" exception = (e, catch_backtrace())
        finally
            lock(nb.lock) do; delete!(nb.report.meta, "hydrating"); nb.version += 1; end
            try; _broadcast(nb, string(nb.version)); catch; end
        end
    end
    return nb
end

# Move this notebook's worker onto (or off) an SSH host, PROVISIONING + spawning there and connecting
# over CURVE/tunnel. `spec` = "ssh_host[,transport]" (transport = tunnel|direct); "" ⇒ local.
# `scope` picks which run-location LAYER this sets (see `_effective_runon`):
#   :session  (default) — runtime-only override, wins for this session, never written to the `.jl`.
#   :notebook           — DURABLE override, persisted in the Slate.config footer (and clears any session temp).
#   :clear              — drop BOTH the session and notebook overrides → fall back to the global default / local.
# Either way: tear down the old kernel → re-pick via `_select_kernel` → stale all cells → async re-run
# (which drives prepare!→provision+spawn on the new host).
function set_run_on!(nb::LiveNotebook, spec::AbstractString; scope::Symbol = :session)
    remotehost = ""
    # Phase 1 (locked): apply the layer change and decide switch vs no-op. We do NOT tear the kernel down
    # here — a switch first interrupts the in-flight run OUTSIDE the lock (a gate round-trip mustn't hold
    # nb.lock), so changing where the notebook runs stops the current evaluation immediately.
    unchanged = lock(nb.lock) do
        before = strip(String(_effective_runon(nb.report)))   # where it runs NOW
        s = strip(String(spec))
        if scope === :clear
            delete!(nb.report.meta, "runon_session"); delete!(nb.report.meta, "runon")
        elseif scope === :notebook
            isempty(s) ? delete!(nb.report.meta, "runon") : (nb.report.meta["runon"] = String(s))
            delete!(nb.report.meta, "runon_session")       # a durable choice supersedes a session temp
        else  # :session
            isempty(s) ? delete!(nb.report.meta, "runon_session") : (nb.report.meta["runon_session"] = String(s))
        end
        # If the EFFECTIVE destination is identical (e.g. "save the current remote to the notebook" — only
        # the layer that owns the choice changed), the worker stays exactly as-is: no teardown, no re-run.
        # Just bump the version so the source badge refreshes; the footer persist happens below.
        if strip(String(_effective_runon(nb.report))) == before
            nb.version += 1
            return true
        end
        return false
    end
    scope === :session || _persist!(nb)     # notebook/clear change the durable footer → write the .jl
    if unchanged
        try; _broadcast(nb, string(nb.version)); catch; end    # refresh state (source badge) — worker untouched
        return nb
    end
    # Actually switching → stop the current evaluation NOW (don't drain it), then tear down + re-pick.
    _interrupt_inflight!(nb)
    lock(nb.lock) do
        try; ReportEngine.shutdown!(nb.kernel); catch; end     # local → killed; remote → detached (idles warm, switch-back reattaches)
        nb.kernel = _select_kernel(nb.path, nb.report)
        remotehost = (nb.kernel isa ReportEngine.GateKernel && nb.kernel.target isa ReportEngine.RemoteTarget) ?
                     nb.kernel.target.ssh_host : ""
        build_dependencies!(nb.report)
        # The new worker has an EMPTY namespace → every cell must re-run on it. Invalidate all cells so
        # `_drain!` re-evaluates them; mirrors ReportEngine.reset!.
        for c in nb.report.cells; c.state = STALE; c.output = nothing; end
        delete!(nb.report.meta, "hydrate_error")
        nb.report.meta["hydrating"] = true
        # Tell the banner this is a remote bring-up (provision + connect can take minutes) rather than a
        # plain re-run — so the UI stops implying it's "running cells" while the worker isn't even up yet.
        isempty(remotehost) ? delete!(nb.report.meta, "hydratingKind") :
            (nb.report.meta["hydratingKind"] = "remote"; nb.report.meta["hydratingHost"] = remotehost)
        nb.version += 1
    end
    _broadcast(nb, "restart")
    @async begin
        try
            # For a remote target, bring the worker up ONCE up front (provision → spawn → connect). This is
            # the interception point: a spawn/provision failure becomes a SINGLE notebook-level error
            # (the hydrate-error banner) instead of the identical error stamped onto every cell. Only once
            # the worker is really connected do we run the cells.
            isempty(remotehost) || ReportEngine.prepare!(nb.kernel, nb.report)
            # Worker is connected now — the "provisioning & connecting…" bring-up is DONE, so drop that
            # banner before the cells run (it otherwise lingers through the whole run, still implying we're
            # spinning the host up). The normal k/N run pill takes over as cells stream in.
            if !isempty(remotehost)
                lock(nb.lock) do
                    delete!(nb.report.meta, "hydrating")
                    delete!(nb.report.meta, "hydratingKind")
                    delete!(nb.report.meta, "hydratingHost")
                    nb.version += 1
                end
                try; _broadcast(nb, string(nb.version)); catch; end
            end
            _drain!(nb)
        catch e
            msg = sprint(showerror, e)
            lock(nb.lock) do
                nb.report.meta["hydrate_error"] = msg
                for c in nb.report.cells; c.output = nothing; (c.state == RUNNING) && (c.state = STALE); end  # nothing ran → no per-cell errors
            end
            @warn "KaimonSlate: run-on bring-up failed" host = remotehost exception = (e, catch_backtrace())
        finally
            lock(nb.lock) do
                delete!(nb.report.meta, "hydrating"); delete!(nb.report.meta, "hydratingKind"); delete!(nb.report.meta, "hydratingHost")
                nb.version += 1
            end
            try; _broadcast(nb, string(nb.version)); catch; end
        end
    end
    return nb
end

# The version of `name` in the user's GLOBAL default env (~/.julia/environments/v#.#) — where a notebook
# resolves a package it doesn't carry itself. "" if absent. Line-scans the Manifest (no TOML dep).
function _global_pkg_version(name::AbstractString)
    mf = joinpath(first(Base.DEPOT_PATH), "environments", "v$(VERSION.major).$(VERSION.minor)", "Manifest.toml")
    isfile(mf) || return ""
    cur = ""
    for line in eachline(mf)
        m = match(r"^\[\[deps\.(.+?)\]\]\s*$", line)
        if m !== nothing; cur = String(m.captures[1]); continue; end
        startswith(strip(line), "[") && (cur = "")
        cur == String(name) || continue
        vm = match(r"^\s*version\s*=\s*\"(.*)\"\s*$", line)
        vm === nothing || return String(vm.captures[1])
    end
    return ""
end

# The gate worker's stdout/stderr log (eval output, prints, errors, package loads)
# — the debugging surface for "what is the worker doing". In-process kernels have
# no separate log (cells eval in the extension process).
function worker_log(nb::LiveNotebook; maxbytes::Int = 100_000)
    if nb.kernel isa GateKernel && nb.kernel.target isa ReportEngine.RemoteTarget
        # Remote worker: the raw log lives on the SSH host. Show the LOCAL orchestration log
        # (provision/spawn/connect steps + failures) followed by the ssh-fetched remote worker log,
        # so "what happened" is answerable from one place even when the remote never came up.
        io = IOBuffer()
        println(io, "═══ local orchestration log (", ReportEngine._REMOTE_LOG, ") ═══")
        println(io, ReportEngine.remote_log(; maxbytes = maxbytes ÷ 2))
        println(io, "\n═══ remote worker log (", nb.kernel.target.ssh_host, ") ═══")
        println(io, ReportEngine.fetch_remote_worker_log(nb.kernel; maxbytes = maxbytes ÷ 2))
        return String(take!(io))
    elseif nb.kernel isa GateKernel                      # real subprocess → tail its raw log
        path = nb.kernel.logpath
        (isempty(path) || !isfile(path)) && return "(worker not started yet)"
        s = read(path, String)
        return ncodeunits(s) > maxbytes ? "…(truncated; last $(maxbytes ÷ 1000)KB)…\n" * String(last(s, maxbytes)) : s
    end
    # In-process kernel: no separate log file, so synthesize an eval console from the
    # cells' captured output (state · duration · stdout · error).
    io = IOBuffer()
    println(io, "# in-process kernel — this notebook isn't in a Julia project, so cells eval in")
    println(io, "# the extension. Open it inside a project dir for a separate gate worker + raw log.\n")
    ran = false
    for c in nb.report.cells
        c.kind == CODE || continue
        o = c.output; o === nothing && continue
        ran = true
        println(io, "[$(c.id)]  $(lowercase(string(c.state)))  ·  $(round(o.duration_ms; digits = 1))ms")
        st = rstrip(o.stdout)
        isempty(st) || println(io, "  " * replace(st, "\n" => "\n  "))
        o.exception === nothing || println(io, "  ERROR: " * replace(o.exception, "\n" => "\n  "))
        println(io)
    end
    ran || println(io, "(no code cells have run yet)")
    return String(take!(io))
end

# Locally-served models for the Settings dropdown, via an Ollama-compatible `/api/tags`.
# Both Ollama and vmlx (the MLX inference server for Apple Silicon) speak this protocol —
# Kaimon's OllamaBackend drives either, routed by an `ollama:` / `vmlx:` model prefix.
# Proxied through the server so the browser dodges cross-origin issues; best-effort —
# returns [] if that server isn't running.
function _tags_models(host::AbstractString)
    startswith(host, "http") || (host = "http://" * host)
    try
        r = HTTP.get(rstrip(host, '/') * "/api/tags"; connect_timeout = 2, request_timeout = 4, retry = false)
        d = JSON.parse(String(r.body))
        names = String[String(get(m, "name", "")) for m in get(d, "models", Any[])]
        # Drop embedding-only models — they can't run /api/chat, so they're useless as agents.
        return filter(n -> !isempty(n) && !occursin(r"embed"i, n), names)
    catch
        return String[]
    end
end
_ollama_models() = _tags_models(get(ENV, "OLLAMA_HOST", "http://127.0.0.1:11434"))
_vmlx_models()   = _tags_models(get(ENV, "VMLX_HOST", "http://127.0.0.1:8000"))

include("export_typst.jl")   # export_pdf(nb) — publication-quality PDF via Typst (uses types defined above)
include("export_bundle.jl")  # export_standalone(nb) / expand(jl) — self-contained single-source .jl

# Splice a notebook's `@use` entries into the shell's single `<script type="importmap">` (right
# after `"imports": {`), so front-end JS can `import` them. Values are JSON-encoded (safe for URLs /
# quotes). No-op when empty. One import map per document → we MERGE, never add a second (the base
# preact/htm/signals entries follow the injected ones).
function _inject_imports(html::AbstractString, imports)
    (imports === nothing || isempty(imports)) && return String(html)
    entries = join(("  " * JSON.json(String(k)) * ": " * JSON.json(String(v)) * "," for (k, v) in imports), "\n  ")
    return replace(String(html), "\"imports\": {" => "\"imports\": {\n  " * entries; count = 1)
end

# Serve the front page with the last-known ledger (sites+targets, from the LOCAL cache — no gist round-
# trip) inlined, so the Sites section paints in the first frame instead of popping in a second later
# after the async /api/publish/ledger fetch. `null` on a fresh machine → the client falls back to fetch.
function _index_html()
    html = read(_INDEX_ASSET, String)
    v = try; publish_ledger_view_cached(); catch; nothing; end
    js = v === nothing ? "null" : replace(JSON.json(v), "</" => "<\\/")   # </script>-in-string guard
    return replace(html, "window.__SLATE_LEDGER__=null;" => "window.__SLATE_LEDGER__=" * js * ";"; count = 1)
end

function _make_router(h::Hub)
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/", _ -> _html(_index_html()))   # front page + inlined last-known ledger (see _index_html)
    HTTP.register!(router, "GET", "/assets/notebook.css", _ -> _asset(read(_CSS_ASSET, String), "text/css; charset=utf-8"))
    # Vendored third-party assets (offline cache, pinned in vendor.json). Greedy `**` so
    # nested paths work (CodeMirror modes/addons, KaTeX fonts). First hit fetches+caches.
    HTTP.register!(router, "GET", "/assets/vendor/**", req -> begin
        rel = replace(HTTP.URI(req.target).path, r"^/assets/vendor/" => "")
        parts = split(rel, '/'; limit = 2)
        (length(parts) == 2 && !isempty(parts[2])) || return HTTP.Response(404)
        f = _vendor_file(String(parts[1]), String(parts[2]))
        f === nothing && return HTTP.Response(404, "vendor asset unavailable (offline & uncached?)")
        HTTP.Response(200, ["Content-Type" => _vendor_ctype(parts[2]),
                            "Cache-Control" => "public, max-age=31536000, immutable"], read(f))
    end)
    HTTP.register!(router, "GET", "/assets/js/{file}", req -> begin
        f = HTTP.getparam(req, "file")
        # path-safety: a bare `name.js` only — no separators, no traversal.
        (occursin('/', f) || occursin('\\', f) || occursin("..", f) || !endswith(f, ".js")) && return HTTP.Response(404)
        p = joinpath(_JS_DIR, f)
        isfile(p) ? _asset(read(p, String), "application/javascript; charset=utf-8") : HTTP.Response(404)
    end)
    # Vendored map GeoJSON for echarts `registerMap` (e.g. /assets/maps/world.json) — served
    # immutable; the front-end fetches + registers a map once per page.
    HTTP.register!(router, "GET", "/assets/maps/{file}", req -> begin
        f = HTTP.getparam(req, "file")
        (occursin('/', f) || occursin('\\', f) || occursin("..", f) || !endswith(f, ".json")) && return HTTP.Response(404)
        p = joinpath(dirname(_JS_DIR), "maps", f)
        isfile(p) ? HTTP.Response(200, ["Content-Type" => "application/json",
                                        "Cache-Control" => "public, max-age=31536000, immutable"], read(p)) :
                    HTTP.Response(404)
    end)
    # Local site host: serve a persistent named site (export_to_site) over HTTP so its client-side
    # index — which `fetch`es slate-site.json (blocked on file://) — works. Greedy `**` for nested
    # slug dirs; `_site_file` resolves + guards against `..` traversal outside the site dir.
    HTTP.register!(router, "GET", "/sites/**", req -> begin
        rel = replace(HTTP.URI(req.target).path, r"^/sites/" => "")
        parts = split(rel, '/'; limit = 2)
        (isempty(parts) || isempty(parts[1])) && return HTTP.Response(404)
        f = _site_file(String(parts[1]), length(parts) == 2 ? String(parts[2]) : "")
        f === nothing && return HTTP.Response(404, "no such site file")
        HTTP.Response(200, ["Content-Type" => _site_ctype(f)], read(f))
    end)
    # Serve a notebook's sibling assets (the files it reads via `@asset`) by real URL, so the live
    # page can reference `<script src="asset/portfolio.js">` (cacheable, debuggable, source-mapped)
    # instead of inlining. Rooted at the notebook's project dir (`assetbase`), with a `..`-traversal
    # guard that keeps every request inside it. `no-store` so an edit shows on the next fetch.
    HTTP.register!(router, "GET", "/n/{id}/asset/**", req -> begin
        id = HTTP.getparam(req, "id")
        m = match(r"^/n/[^/]+/asset/(.*)$", HTTP.URI(req.target).path)
        sub = m === nothing ? "" : String(m.captures[1])
        nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
        nb === nothing && return HTTP.Response(404, "no such notebook")
        base = String(get(nb.report.meta, "assetbase", ""))
        isempty(base) && return HTTP.Response(404, "notebook has no asset root")
        rootn = normpath(base)
        p = normpath(joinpath(rootn, strip(sub, '/')))
        # stay inside the project dir (accept either separator so the guard holds on Windows too)
        (p == rootn || startswith(p, rootn * "/") || startswith(p, rootn * "\\")) || return HTTP.Response(404)
        isfile(p) || return HTTP.Response(404, "no such asset")
        HTTP.Response(200, ["Content-Type" => _site_ctype(p), "Cache-Control" => "no-store"], read(p))
    end)
    HTTP.register!(router, "GET", "/api/notebooks", _ -> _json(_notebooks_json(h)))
    # Open/close a notebook by path over HTTP — lets the index page (and any
    # caller) bring up a notebook without the `slate.*` MCP tools. Mirrors
    # `KaimonSlate.create_tools`'s open: creates the file if it doesn't exist.
    HTTP.register!(router, "POST", "/api/open", req -> begin
        b = _body(req)
        path = expanduser(strip(String(get(b, "path", ""))))   # resolve ~ (tab-complete emits ~ paths)
        isempty(path) && return HTTP.Response(400, "missing path")
        isfile(path) || write(path, "#%% md id=intro\n# New Notebook\n")
        # Optional run-location chosen in the open/new-notebook picker ("host[,transport]"); "" = follow
        # the file's own choice / the global default. Only applied when the notebook isn't already open.
        id = open_notebook!(h, path; runon = strip(String(get(b, "runon", ""))))
        _json(Dict("id" => id, "url" => "/n/$id", "path" => abspath(path)))
    end)
    # Upload a `.jl` from the browser (the viewing machine) → save it under a persistent uploads dir and
    # return its server path; the front end then opens it via the normal open/import flow. Body: {name, content}.
    HTTP.register!(router, "POST", "/api/upload", req -> begin
        b = _body(req)
        content = String(get(b, "content", ""))
        isempty(strip(content)) && return HTTP.Response(400, "empty upload")
        name = basename(replace(String(get(b, "name", "notebook.jl")), r"[^\w.\-]" => "_"))
        isempty(name) && (name = "notebook.jl")
        endswith(lowercase(name), ".jl") || (name *= ".jl")
        dir = joinpath(homedir(), "KaimonSlate", "uploads"); mkpath(dir)
        stem = replace(name, r"\.jl$"i => "")
        path = joinpath(dir, name); i = 1
        while ispath(path); i += 1; path = joinpath(dir, "$(stem)-$(i).jl"); end   # never overwrite an existing file
        write(path, content)
        _json(Dict("path" => abspath(path)))
    end)
    HTTP.register!(router, "POST", "/api/close", req -> begin
        file = abspath(expanduser(strip(String(get(_body(req), "path", "")))))
        id = lock(h.lock) do
            for nb in values(h.notebooks)
                abspath(nb.path) == file && return nb.id
            end
            return nothing
        end
        id === nothing ? HTTP.Response(404, "not open") : (close_notebook!(h, id); _json(Dict("closed" => file)))
    end)
    HTTP.register!(router, "GET", "/api/path-complete", req -> begin
        q = get(HTTP.queryparams(HTTP.URI(req.target)), "q", "")
        r = _path_completions(q)
        _json(Dict("completions" => r.items, "truncated" => r.truncated))
    end)
    # Stat a path (with ~ expansion) so the open box can decide: open file / show
    # subpaths for a directory / confirm-create for a new path.
    HTTP.register!(router, "GET", "/api/path-info", req -> begin
        p = expanduser(strip(String(get(HTTP.queryparams(HTTP.URI(req.target)), "q", ""))))
        # `standalone`: a self-contained `.jl` (Slate.bundle footer) → the open box offers the
        # import-into-a-project helper instead of opening it bare.
        _json(Dict("path" => p, "exists" => ispath(p), "isdir" => isdir(p), "isfile" => isfile(p),
                   "standalone" => isfile(p) && _has_bundle_footer(p)))
    end)
    # Close a notebook by id (the index's per-session shutdown button).
    HTTP.register!(router, "POST", "/api/{id}/shutdown", req -> begin
        id = HTTP.getparam(req, "id")
        close_notebook!(h, id) ? _json(Dict("closed" => id)) : HTTP.Response(404, "no such notebook")
    end)
    # ── Run-location: host list, global default, preflight, remote-worker registry ──────────────────
    # Candidate ssh hosts (~/.ssh/config Host aliases) + the current machine global default → the picker.
    HTTP.register!(router, "GET", "/api/ssh-hosts", _ ->
        _json(Dict("hosts" => ReportEngine.ssh_config_hosts(), "global" => RUNON_DEFAULT[])))
    # Set the machine GLOBAL run-location default (where new notebooks run). Body {host:"..."}. Persisted
    # to slate.json via the hook KaimonSlate installed. "" ⇒ new notebooks run local by default.
    HTTP.register!(router, "POST", "/api/run-on-default", req ->
        _json(Dict("global" => set_runon_default!(String(get(_body(req), "host", ""))))))
    # Data-transfer knobs for the Settings panel: the memo data-channel chunk size (MB/round-trip)
    # and the boot-carry per-entry ceiling (s). 0 = unset (env / built-in default applies); the
    # effective values are reported alongside so the UI can show what "default" currently means.
    _xfer_json() = _json(Dict(
        "chunk_mb" => ReportEngine.BLOB_CHUNK_MB[], "carry_max_s" => ReportEngine.CARRY_MAX_S[],
        "effective_chunk_mb" => round(ReportEngine._blob_chunk() / 2^20; digits = 2),
        "effective_carry_max_s" => ReportEngine._carry_ceiling_s()))
    HTTP.register!(router, "GET", "/api/transfer-settings", _ -> _xfer_json())
    HTTP.register!(router, "POST", "/api/transfer-settings", req -> begin
        b = _body(req)
        chunk = max(0.0, something(tryparse(Float64, string(get(b, "chunk_mb", ""))), 0.0))
        carry = max(0.0, something(tryparse(Float64, string(get(b, "carry_max_s", ""))), 0.0))
        p = _XFER_PERSIST[]
        if p !== nothing
            try; p(chunk, carry); catch e; @warn "slate: could not persist transfer settings" exception = e; end
        else                                             # standalone hub: live-only, no slate.json
            ReportEngine.BLOB_CHUNK_MB[] = chunk; ReportEngine.CARRY_MAX_S[] = carry
        end
        _xfer_json()
    end)
    # Test + prime a host: the full reported dry-run (ssh, julia, provision, KaimonGate, CURVE, spawn+
    # connect+eval+teardown). Body {host, transport:"tunnel"|"direct"}. Slow on a cold host (provision).
    HTTP.register!(router, "POST", "/api/preflight", req -> begin
        b = _body(req)
        host = strip(String(get(b, "host", "")))
        isempty(host) && return _json(Dict("ok" => false, "error" => "no host"))
        tr = Symbol(strip(String(get(b, "transport", "tunnel"))))
        tr in (:tunnel, :direct) || (tr = :tunnel)
        _json(ReportEngine.preflight_remote(host; transport = tr))
    end)
    # Remote-worker registry for a host: list workers (which notebook, last activity, reconnectable?,
    # possibly-abandoned?) so a human can clean up. Body/query {host}. Reaping is POST /api/reap-worker.
    HTTP.register!(router, "GET", "/api/remote-workers", req -> begin
        host = strip(String(get(HTTP.queryparams(HTTP.URI(req.target)), "host", "")))
        isempty(host) && return _json(Dict("host" => "", "workers" => []))
        _json(Dict("host" => host, "workers" => ReportEngine.list_remote_workers(host)))
    end)
    # Manually reap a specific remote worker (kill process + remove its manifest). Body {host, port}.
    # Never automatic — the user decides, so a worker with useful results is never killed out from under them.
    HTTP.register!(router, "POST", "/api/reap-worker", req -> begin
        b = _body(req)
        host = strip(String(get(b, "host", "")))
        port = tryparse(Int, string(get(b, "port", "")))
        (isempty(host) || port === nothing) && return _json(Dict("ok" => false, "error" => "need host + port"))
        _json(Dict("ok" => ReportEngine.reap_remote_worker(host, port)))
    end)
    HTTP.register!(router, "GET", "/n/{id}", req -> begin
        id = HTTP.getparam(req, "id")
        nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
        nb === nothing && return HTTP.Response(302, ["Location" => "/"])          # not open → home
        # Merge the notebook's `@use` import-map entries into the shell's single importmap (so
        # front-end JS can `import` them); verbatim shell when there are none.
        _html(_inject_imports(read(_ASSET, String), get(nb.report.meta, "imports", nothing)))
    end)
    HTTP.register!(router, "GET", "/api/{id}/state", req -> _withnb(h, req, nb -> (sync_from_file!(nb); _json(state_json(nb)))))
    # Content-addressed output image (see server_history.jl `_externalize_blobs`): immutable, so the
    # browser caches it forever — a reload re-uses the cached image instead of re-downloading it.
    HTTP.register!(router, "GET", "/api/{id}/blob/{hash}", req -> begin
        # memory tier (plot rasters) → durable disk tier (animation stacks); the latter may be gzip'd.
        b = blob_lookup(string(HTTP.getparam(req, "id"), "/", HTTP.getparam(req, "hash")))
        b === nothing && return HTTP.Response(404, "no such blob")
        hdrs = ["Content-Type" => b[1], "Cache-Control" => "public, max-age=31536000, immutable"]
        isempty(b[3]) || push!(hdrs, "Content-Encoding" => b[3])
        HTTP.Response(200, hdrs, b[2])
    end)
    # Full result for a truncated output — only serves temp files WE registered (no path traversal).
    HTTP.register!(router, "GET", "/api/{id}/output/{name}", req -> begin
        path = outfile_get(string(HTTP.getparam(req, "id"), "/", HTTP.getparam(req, "name")))
        (path === nothing || !isfile(path)) && return HTTP.Response(404, "no such output")
        mime = endswith(path, ".html") ? "text/html; charset=utf-8" : "text/plain; charset=utf-8"
        HTTP.Response(200, ["Content-Type" => mime, "Cache-Control" => "public, max-age=31536000, immutable"], read(path))
    end)
    HTTP.register!(router, "POST", "/api/{id}/cell/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        edit_cell!(nb, HTTP.getparam(req, "cid"), get(b, "source", ""); force = get(b, "force", false) === true)
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/complete", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        code = String(get(body, "code", ""))
        # `Int(...)` throws InexactError on a JSON float (`pos: 3.5`); round + tryparse defensively.
        n = ncodeunits(code)
        pos = clamp(round(Int, something(tryparse(Float64, string(get(body, "pos", n))), Float64(n))), 0, n)
        pstart, prefix, dotted = _id_prefix(code, pos)
        # Completion resolves WHERE the cells eval (the worker, for a gate kernel), so
        # `using`'d packages and evaluated bindings complete — not just server-side globals.
        items, from, to = (Tuple{String,String}[], pstart, pos)
        try
            r = ReportEngine.complete(nb.kernel, nb.report, code, pos)
            items = Tuple{String,String}[(String(t), String(k)) for (t, k) in r.items]
            from = Int(r.from); to = Int(r.to)
        catch
        end
        if !dotted                          # union in cell-local bindings (skip field access)
            have = Set(first.(items))
            lset = Set(String(s) for s in (try; _cell_locals(code); catch; Set{Symbol}(); end))
            # A CURRENT-cell binding is the top tier ("local") — even one already evaluated (so the
            # worker returned it as "notebook"): re-tag those, then prepend the not-yet-run ones.
            isempty(lset) || (items = Tuple{String,String}[(t, t in lset ? "local" : k) for (t, k) in items])
            extra = sort!(String[n for n in lset if startswith(n, prefix) && !(n in have)])
            isempty(extra) || (items = vcat(Tuple{String,String}[(n, "local") for n in extra], items))
        end
        items = _rank_completions(items, prefix)
        # `@bind` vars expand to consts, so the completer tags them "const" — relabel them "bind"
        # for a clearer icon (a control, not a constant).
        bindnames = Set(String(b.name) for c in nb.report.cells for b in c.binds)
        isempty(bindnames) || (items = Tuple{String,String}[(t, t in bindnames ? "bind" : k) for (t, k) in items])
        # latex/emoji: a partial query returns the NAME (`\alpha`); attach the resolved symbol as
        # `apply` so the UI shows the name (filterable) but inserts the character in one step.
        comps = map(items) do (t, k)
            d = Dict{String,Any}("text" => t, "kind" => k)
            if k == "latex" && startswith(t, "\\")
                sym = ReportEngine.latex_symbol(t)
                isempty(sym) || (d["apply"] = sym)
            end
            d
        end
        _json(Dict("completions" => comps, "from" => from, "to" => to))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-add", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        add_cell!(nb, get(b, "after", ""), get(b, "kind", "code"); before = get(b, "before", false) === true)
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-rename/{cid}", req -> _withnb(h, req, nb -> begin
        ok, msg = rename_cell!(nb, HTTP.getparam(req, "cid"), get(_body(req), "newid", ""))
        ok ? _json(state_json(nb)) : HTTP.Response(400, msg)
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-split/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req); split_cell!(nb, HTTP.getparam(req, "cid"), get(b, "before", ""), get(b, "after", "")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-merge/{cid}", req -> _withnb(h, req, nb -> begin
        merge_cell!(nb, HTTP.getparam(req, "cid"), get(_body(req), "source", "")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-delete/{cid}", req -> _withnb(h, req, nb ->
        (delete_cell!(nb, HTTP.getparam(req, "cid")); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/cells-delete", req -> _withnb(h, req, nb -> begin
        b = _body(req); delete_cells!(nb, get(b, "ids", String[]); verb = get(b, "verb", "delete")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cells-paste", req -> _withnb(h, req, nb -> begin
        b = _body(req); paste_cells!(nb, get(b, "after", ""), get(b, "cells", Any[])); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-move/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req); cid = HTTP.getparam(req, "cid")
        haskey(b, "target") ? move_cell_rel!(nb, cid, b["target"], get(b, "before", true) === true) :
                              move_cell!(nb, cid, get(b, "dir", "up"))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-type/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        set_kind!(nb, HTTP.getparam(req, "cid"), get(b, "kind", "code"); source = get(b, "source", nothing)); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/controls", req -> _withnb(h, req, nb -> begin
        set_controls_map!(nb, get(_body(req), "map", Dict{String,Any}())); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/collapse/{cid}", req -> _withnb(h, req, nb -> begin
        set_collapsed!(nb, HTTP.getparam(req, "cid"), get(_body(req), "collapsed", true) === true); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/hidecode/{cid}", req -> _withnb(h, req, nb -> begin
        set_code_hidden!(nb, HTTP.getparam(req, "cid"), get(_body(req), "hidden", true) === true); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/trace/{cid}", req -> _withnb(h, req, nb -> begin
        # Toggle the flag (marks the cell STALE) then re-run stale cells, so the trace table
        # appears / disappears in one round-trip — no client-side source resend.
        set_trace!(nb, HTTP.getparam(req, "cid"), get(_body(req), "trace", true) === true)
        _eval!(nb)
        _json(state_json(nb))
    end))
    # Set a cell's full tag set from the tag editor (known behaviour tags + free-form). Re-runs stale
    # cells so a `trace` toggle takes effect in one round-trip.
    HTTP.register!(router, "POST", "/api/{id}/tags/{cid}", req -> _withnb(h, req, nb -> begin
        tags = get(_body(req), "tags", String[])
        set_cell_tags!(nb, HTTP.getparam(req, "cid"), tags isa AbstractVector ? tags : String[])
        _eval!(nb)
        _json(state_json(nb))
    end))
    # Static export: a self-contained HTML document of the notebook. `?dl=1` downloads; `?source=0`
    # hides code; `?theme=light|dark`; `?code=normal|small|smaller|tiny|hidden` sizes/hides listings.
    # No scripts/server needed; KaTeX (CDN) typesets math, figures are embedded.
    HTTP.register!(router, "GET", "/api/{id}/export.html", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        _run = get(qp, "bundle", "0") == "1"   # embed the reproducible bundle + a "Run live" launcher
        html = export_html(nb; include_source = get(qp, "source", "1") != "0",
                           theme = get(qp, "theme", "dark"), code = get(qp, "code", "normal"),
                           outputs = get(qp, "outputs", "all"), runnable = _run, embed_bundle = _run,
                           history = get(qp, "history", "0") == "1")   # source-only by default (public page)
        headers = Pair{String,String}["Content-Type" => "text/html; charset=utf-8"]
        if get(qp, "dl", "0") == "1"
            fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".html"
            push!(headers, "Content-Disposition" => "attachment; filename=\"$fn\"")
        end
        HTTP.Response(200, headers, html)
    end))
    # GitHub-flavored Markdown for copy-paste (Discourse / Slack / GitHub / Obsidian). `?source=0`
    # omits code cells. Figures/charts embed as data-URI images; tables as GFM tables.
    HTTP.register!(router, "GET", "/api/{id}/export.md", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        md = export_markdown(nb; include_source = get(qp, "source", "1") != "0",
                             outputs = get(qp, "outputs", "all"))
        headers = Pair{String,String}["Content-Type" => "text/markdown; charset=utf-8"]
        if get(qp, "dl", "0") == "1"
            fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".md"
            push!(headers, "Content-Disposition" => "attachment; filename=\"$fn\"")
        end
        HTTP.Response(200, headers, md)
    end))
    # Publication-quality PDF via Typst (server-side). `?source=0` hides code listings;
    # `?params=1` shows the @bind parameter strip (hidden by default — a PDF is a snapshot).
    # Serve a notebook's external bibliography file (the "view" link on the references card). Scoped
    # to .bib files resolved against the notebook's directory; no path traversal outside it.
    HTTP.register!(router, "GET", "/api/{id}/bibfile", req -> _withnb(h, req, nb -> begin
        name = get(HTTP.queryparams(HTTP.URI(req.target)), "name", "")
        (isempty(name) || !endswith(lowercase(name), ".bib")) && return HTTP.Response(400, "expected a .bib name")
        nbdir = dirname(abspath(nb.path))
        path = normpath(isabspath(name) ? String(name) : joinpath(nbdir, name))
        # Only serve a .bib the notebook actually DECLARES in a bibliography cell — resolved the
        # same way bibliography_index does. Prevents this route reading an arbitrary file off disk
        # while still honoring a legitimately-declared absolute bib path.
        declared = Set{String}()
        for c in nb.report.cells
            (:bibliography in c.flags) || continue
            occursin(r"@\w+\s*\{", c.source) && continue
            for ln in split(c.source, '\n')
                p = strip(ln); isempty(p) && continue
                push!(declared, normpath(isabspath(p) ? String(p) : joinpath(nbdir, p)))
            end
        end
        (path in declared && isfile(path)) || return HTTP.Response(404, "not found")
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], read(path))
    end))
    HTTP.register!(router, "GET", "/api/{id}/export.pdf", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        pdf = try
            _lay = get(qp, "layout", "article")
            export_pdf(nb; include_source = get(qp, "source", _lay == "slides" ? "0" : "1") != "0",
                       style = get(qp, "style", "article"),
                       columns = something(tryparse(Int, get(qp, "columns", "1")), 1),
                       theme = get(qp, "theme", "light"),
                       code = get(qp, "code", "normal"),
                       body = get(qp, "body", ""),
                       include_params = get(qp, "params", "0") == "1",
                       layout = _lay, notes = get(qp, "notes", "0") == "1",
                       level = get(nb.report.meta, "slidelevel", 2),
                       outputs = get(qp, "outputs", "all"))
        catch e
            return HTTP.Response(500, "PDF export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".pdf"
        HTTP.Response(200, ["Content-Type" => "application/pdf",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], pdf)
    end))
    # The editable Typst PROJECT (doc.typ + assets) as a .tar.gz, so the layout can be tweaked and
    # recompiled (`typst compile doc.typ`). Same options as export.pdf.
    HTTP.register!(router, "GET", "/api/{id}/export.typ", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        data = try
            _lay = get(qp, "layout", "article")
            export_typst_bundle(nb; include_source = get(qp, "source", _lay == "slides" ? "0" : "1") != "0",
                       style = get(qp, "style", "article"),
                       columns = something(tryparse(Int, get(qp, "columns", "1")), 1),
                       theme = get(qp, "theme", "light"),
                       code = get(qp, "code", "normal"),
                       body = get(qp, "body", ""),
                       include_params = get(qp, "params", "0") == "1",
                       layout = _lay, notes = get(qp, "notes", "0") == "1",
                       level = get(nb.report.meta, "slidelevel", 2),
                       outputs = get(qp, "outputs", "all"))
        catch e
            return HTTP.Response(500, "Typst export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".typ.tar.gz"
        HTTP.Response(200, ["Content-Type" => "application/gzip",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], data)
    end))
    # Publishable website (index.html + og-image.png) as a .tar.gz — drop into a gh-pages branch or any
    # static host. Same HTML options as export.html (theme/code/outputs/source).
    HTTP.register!(router, "GET", "/api/{id}/export.site", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        data = try
            export_site(nb; include_source = get(qp, "source", "1") != "0",
                        theme = get(qp, "theme", "dark"), code = get(qp, "code", "normal"),
                        outputs = get(qp, "outputs", "all"), bundle = get(qp, "bundle", "0") == "1",
                        history = get(qp, "history", "0") == "1")   # source-only by default (public page)
        catch e
            return HTTP.Response(500, "Site export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".site.tar.gz"
        HTTP.Response(200, ["Content-Type" => "application/gzip",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], data)
    end))
    # Export a notebook INTO a persistent local site (the local mirror of publish). Body:
    # {name, slug?, bundle?, theme?, outputs?, source?}. Returns the hub-relative URL to open.
    HTTP.register!(router, "POST", "/api/{id}/export-to-site", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        name = strip(String(get(b, "name", "")))
        isempty(name) && return HTTP.Response(400, "missing site \"name\"")
        try
            r = export_to_site(nb, String(name); slug = String(get(b, "slug", "")),
                               bundle = get(b, "bundle", false) === true, theme = get(b, "theme", "dark"),
                               outputs = get(b, "outputs", "all"), include_source = get(b, "source", "1") != "0",
                               history = get(b, "history", false) === true)
            return _json(Dict("url" => r.url, "site" => r.site, "slug" => r.slug,
                              "home" => r.home, "docCount" => r.docCount))
        catch e
            return HTTP.Response(500, "Export to site failed: " * sprint(showerror, e))
        end
    end))
    # Existing local sites (names), for the export dialog's picker.
    HTTP.register!(router, "GET", "/api/sites", _ -> _json(Dict("sites" => list_local_sites())))
    # The docs in one local site (?name=…), for the export dialog's "remove a page" picker.
    HTTP.register!(router, "GET", "/api/site-docs", req -> begin
        name = get(HTTP.queryparams(HTTP.URI(req.target)), "name", "")
        _json(Dict("docs" => site_docs(String(name))))
    end)
    # Unexport (remove) a subpage from a local site. Body: {name, slug}. Deletes its dir + manifest
    # entry and regenerates the index.
    HTTP.register!(router, "POST", "/api/site-unexport", req -> begin
        b = _body(req)
        name = strip(String(get(b, "name", ""))); slug = strip(String(get(b, "slug", "")))
        (isempty(name) || isempty(slug)) && return HTTP.Response(400, "missing site \"name\" or \"slug\"")
        r = unexport_from_site(String(name), String(slug))
        _json(Dict("removed" => r.removed, "docCount" => r.docCount))
    end)
    # Preflight (read-only): what would publishing to this repo do? Body: {repo}. Drives the confirm UI.
    HTTP.register!(router, "POST", "/api/{id}/publish-check", req -> _withnb(h, req, nb -> begin
        repo = strip(get(_body(req), "repo", ""))
        _json(Dict(pairs(publish_preflight(String(repo)))))
    end))
    # Publish the site to GitHub Pages via the user's `gh` CLI. Body: {repo:"owner/name", private, theme}.
    # Creates the repo if missing, pushes the built site to gh-pages, enables Pages, returns the URL.
    HTTP.register!(router, "POST", "/api/{id}/publish", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        repo = strip(get(b, "repo", ""))
        isempty(repo) && return HTTP.Response(400, "missing \"repo\" (owner/name)")
        try
            r = publish_site(nb, String(repo); slug = String(get(b, "slug", "")),
                             site_title = String(get(b, "siteTitle", "")),
                             site_description = String(get(b, "siteDescription", "")),
                             private = get(b, "private", false) === true,
                             create = get(b, "create", true) === true, theme = get(b, "theme", "dark"),
                             outputs = get(b, "outputs", "all"), include_source = get(b, "source", "1") != "0",
                             bundle = get(b, "bundle", false) === true, history = get(b, "history", false) === true)
            # Remember WHERE this notebook publishes so the dialog pre-fills next time (and a CI
            # action can read the target). Authored intent → travels in the Slate.config footer.
            nb.report.meta["publishrepo"] = String(repo)
            nb.report.meta["publishslug"] = r.home ? "" : String(r.slug)
            _persist!(nb)
            record_publish_site!(nb, String(repo), r)   # keep the publish ledger (history + doc↔target) in sync
            return _json(Dict("url" => r.url, "docUrl" => r.docUrl, "slug" => r.slug, "repo" => r.repo,
                              "created" => r.created, "docCount" => r.docCount, "home" => r.home,
                              "pagesEnabled" => r.pagesEnabled, "pagesError" => r.pagesError,
                              "deployStatus" => get(r, :deployStatus, "")))
        catch e
            return HTTP.Response(500, "Publish failed: " * sprint(showerror, e))
        end
    end))
    # Self-contained single-source .jl: cells + full Project/Manifest + local source (+ a
    # shallow git bundle when the project is a repo). Reinflate with `KaimonSlate.expand`.
    HTTP.register!(router, "GET", "/api/{id}/export.standalone.jl", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        jl = try
            export_standalone(nb; history = get(qp, "history", "1") != "0")   # full git history by default (deliberate share)
        catch e
            return HTTP.Response(500, "Standalone export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".standalone.jl"
        HTTP.Response(200, ["Content-Type" => "text/x-julia; charset=utf-8",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], jl)
    end))
    # ── Notebook packages ─────────────────────────────────────────────────────
    # Show the environment with provenance: `notebook` deps (the notebook's own forked env,
    # where adds land — removable) and `parent` deps (inherited from the enclosing project,
    # which the forked env extends — read-only). `detached` is true when there's no parent
    # (the notebook env IS everything). `manageable` is false for an in-process kernel.
    # Package-name completion for the Add box (matches reachable registries).
    HTTP.register!(router, "GET", "/api/{id}/pkg-complete", req -> _withnb(h, req, _ -> begin
        q = get(HTTP.queryparams(HTTP.URI(req.target)), "q", "")
        _json(Dict("names" => _pkg_complete(String(q))))
    end))
    # What version of a package the user's GLOBAL default env has — the version a notebook that resolves
    # the package from the global env is actually using. Lets the missing-package prompt SHOW it and
    # install THAT version (not blindly latest, which could break the notebook).
    HTTP.register!(router, "GET", "/api/{id}/pkg-info", req -> _withnb(h, req, _ -> begin
        name = strip(String(get(HTTP.queryparams(HTTP.URI(req.target)), "name", "")))
        _json(Dict("name" => name, "globalVersion" => isempty(name) ? "" : _global_pkg_version(name)))
    end))
    HTTP.register!(router, "GET", "/api/{id}/packages", req -> _withnb(h, req, nb -> begin
        e = _notebook_adds(nb)
        _json(Dict("notebook" => e.adds,
                   "parent" => e.parent,
                   "parentPath" => e.parentpath,
                   "detached" => e.detached,
                   "manageable" => !(nb.kernel isa InProcessKernel)))
    end))
    HTTP.register!(router, "POST", "/api/{id}/package", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        tgt = String(get(b, "target", "notebook")); tgt in ("notebook", "project") || (tgt = "notebook")
        _json(notebook_pkg_op!(nb, String(get(b, "op", "")), String(get(b, "name", "")); target = tgt))
    end))
    # The worker's stdout/stderr log — what the kernel is doing when evaluating cells.
    HTTP.register!(router, "GET", "/api/{id}/worker-log", req -> _withnb(h, req, nb ->
        _json(Dict("log" => worker_log(nb), "worker" => _kernel_status(nb.kernel)))))
    HTTP.register!(router, "POST", "/api/{id}/bind/{cid}", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        set_bind!(nb, HTTP.getparam(req, "cid"), get(body, "name", ""), get(body, "value", nothing))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/table-page", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        res = lock(nb.lock) do                       # serialize vs eval (shared gate connection)
            ReportEngine.table_page(nb.kernel, nb.report, String(get(b, "table_id", "")), b)
        end
        _json(Dict("rows" => res.rows, "total" => res.total))
    end))
    HTTP.register!(router, "POST", "/api/{id}/undo", req -> _withnb(h, req, nb -> begin
        lbl = undo!(nb); j = state_json(nb); j["undid"] = lbl; _json(j)
    end))
    HTTP.register!(router, "POST", "/api/{id}/redo", req -> _withnb(h, req, nb -> begin
        lbl = redo!(nb); j = state_json(nb); j["redid"] = lbl; _json(j)
    end))
    HTTP.register!(router, "POST", "/api/{id}/run", req -> _withnb(h, req, nb -> (_eval!(nb); _json(state_json(nb)))))
    # Clear the in-memory scratchpad (slate.eval cells) — the panel's Clear button.
    HTTP.register!(router, "POST", "/api/{id}/scratch/clear", req -> _withnb(h, req, nb -> (clear_scratch!(nb); _json(Dict("ok" => true)))))
    # Re-run the WHOLE notebook (every cell in order, keeping the namespace) — the "safe"
    # option after a /src hot-reload when our guess at affected cells may be incomplete.
    HTTP.register!(router, "POST", "/api/{id}/rerun-all", req -> _withnb(h, req, nb -> begin
        lock(nb.lock) do
            for c in nb.report.cells; c.state = STALE; end
            _eval!(nb)
        end
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/restart", req -> _withnb(h, req, nb -> (restart_kernel!(nb); _json(state_json(nb)))))
    # Run this notebook on a remote worker. Body {ports:"port,stream_port"} (127.0.0.1, e.g. an SSH
    # tunnel) attaches; {ports:""} switches back to a local worker. Runtime-only (not saved to the .jl).
    HTTP.register!(router, "POST", "/api/{id}/remote-worker", req -> _withnb(h, req, nb -> begin
        set_remote_worker!(nb, String(get(_body(req), "ports", "")))
        _json(state_json(nb))
    end))
    # Set this notebook's run-location. Body {host:"ssh_host[,transport]", scope:"session"|"notebook"|"clear"}.
    # host="" + scope="session"/"notebook" → local for that layer; scope="clear" drops both overrides.
    HTTP.register!(router, "POST", "/api/{id}/run-on", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        sc = Symbol(strip(String(get(b, "scope", "session"))))
        sc in (:session, :notebook, :clear) || (sc = :session)
        set_run_on!(nb, String(get(b, "host", "")); scope = sc)
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cancel", req -> _withnb(h, req, nb -> (cancel_run!(nb); _json(state_json(nb)))))
    # Agent chat: forward the turn to Kaimon's agent service (spawning a session
    # bound to this notebook on first use); the agent's `{kind,turn,data}` events
    # arrive async on the gate bus and are relayed to this notebook's SSE by
    # `relay_agent_event` (wired via KaimonSlate.on_event). See AGENT_SESSION_*.md.
    HTTP.register!(router, "POST", "/api/{id}/chat", req -> _withnb(h, req, nb -> begin
        text = String(get(_body(req), "text", ""))
        isempty(strip(text)) && return _json(Dict("ok" => false, "error" => "empty message"))
        _agent_available() ||
            return _json(Dict("ok" => false, "error" => "agent service unavailable (run inside Kaimon, with a logged-in `claude` CLI)"))
        tgt = String(get(_body(req), "target", ""))   # per-cell ✨: scope the turn to a cell + its dep cone
        crew = String(get(_body(req), "crew", ""))     # crew label → route to that crew member's agent ("" = solo)
        model = String(get(_body(req), "model", ""))   # agent model ("" = service default = sonnet); binds at spawn
        perm = String(get(_body(req), "permission", "")) # permission preset (lab/auto/default/bypass); binds at spawn
        ment = _mention_context(nb, text)              # @id cell references → inline those cells' context
        isempty(ment) || (text = ment * "\n\n" * text)
        isempty(tgt) || (text = _cell_context(nb, tgt) * "\n\nUSER REQUEST:\n" * text)
        let d = get(_body(req), "dark", nothing)       # browser's UI theme → plot-theme hint in the system prompt
            d === nothing || (nb.report.meta["ui_dark"] = d === true)
        end
        try
            aid = _ensure_agent!(nb; crew = crew, model = model, permission = perm)
            res = _agent_call(:agent_send, Dict{String,Any}("agent_id" => aid, "text" => text))
            _json(Dict("ok" => true, "agent_id" => aid, "crew" => crew, "turn" => get(res, "turn", nothing)))
        catch e
            _json(Dict("ok" => false, "error" => sprint(showerror, e)))
        end
    end))
    # Replay the conversation after a page reload (buffered as relayed, crew-tagged,
    # in arrival order across ALL crew agents on this notebook).
    HTTP.register!(router, "GET", "/api/{id}/agent-log", req -> _withnb(h, req, nb -> begin
        log = lock(_AGENT_LOCK) do; copy(get(_AGENT_LOG, nb.id, String[])); end
        _json(Dict("events" => log, "agents" => copy(nb.agents)))
    end))
    # Interrupt EVERY crew agent's in-flight turn (best effort, graceful).
    HTTP.register!(router, "POST", "/api/{id}/chat-interrupt", req -> _withnb(h, req, nb -> begin
        (_agent_available() && !isempty(nb.agents)) || return _json(Dict("ok" => false))
        any_int = false
        for aid in collect(values(nb.agents))
            r = try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => aid)); catch; Dict("interrupted" => false); end
            get(r, "interrupted", false) === true && (any_int = true)
        end
        _json(Dict("ok" => true, "interrupted" => any_int))
    end))
    # Hard stop: interrupt AND close (terminate) every crew agent — for a wedged agent
    # that `agent_interrupt` alone can't stop (it only cancels an in-flight LLM turn).
    # Reaps the whole crew so the next chat message spawns fresh.
    HTTP.register!(router, "POST", "/api/{id}/chat-kill", req -> _withnb(h, req, nb -> begin
        (_agent_available() && !isempty(nb.agents)) || return _json(Dict("ok" => false))
        for aid in collect(values(nb.agents))
            try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => aid)); catch; end
        end
        _reap_agents!(nb; keep_log = true)   # agents gone, transcript stays visible
        _json(Dict("ok" => true, "killed" => true))
    end))
    # Clear the conversation entirely: interrupt + reap every agent, then wipe the
    # transcript from memory AND disk. The next message starts a clean chat.
    HTTP.register!(router, "POST", "/api/{id}/chat-clear", req -> _withnb(h, req, nb -> begin
        if _agent_available() && !isempty(nb.agents)
            for aid in collect(values(nb.agents))
                try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => aid)); catch; end
            end
        end
        _reap_agents!(nb; keep_log = false)   # agents gone + in-memory log dropped
        _clear_chat_log!(nb)                  # and the on-disk transcript
        _json(Dict("ok" => true, "cleared" => true))
    end))
    # Locally-served models → the Settings model dropdown (ollama:<name> / vmlx:<name>).
    HTTP.register!(router, "GET", "/api/{id}/ollama-models", req -> _withnb(h, req, _ ->
        _json(Dict("models" => _ollama_models()))))
    HTTP.register!(router, "GET", "/api/{id}/vmlx-models", req -> _withnb(h, req, _ ->
        _json(Dict("models" => _vmlx_models()))))
    # Semantic docs search (docs v2) — for the UI palette; the agent uses slate.search_docs.
    HTTP.register!(router, "GET", "/api/{id}/docsearch", req -> _withnb(h, req, nb -> begin
        q = strip(get(HTTP.queryparams(HTTP.URI(req.target)), "q", ""))
        results = isempty(q) ? Dict{String,Any}[] : search_docs(String(q); modules = _inscope_modules(nb))
        for r in results; r["docHtml"] = _doc_html(get(r, "doc", "")); end   # rendered markdown for the detail pane
        _json(Dict("results" => results))
    end))
    # Live help lookup (?Module / cross-reference link) — doc + (for a module) its exports.
    HTTP.register!(router, "GET", "/api/{id}/help", req -> _withnb(h, req, nb -> begin
        name = strip(get(HTTP.queryparams(HTTP.URI(req.target)), "name", ""))
        _json(isempty(name) ? Dict{String,Any}() : help_lookup(nb, String(name)))
    end))
    # Client-rendered figure snapshot (ECharts canvas → PNG) — feeds slate_view + PDF.
    HTTP.register!(router, "POST", "/api/{id}/snapshot", req -> _withnb(h, req, nb -> begin
        b = _body(req); cell = String(get(b, "cell", "")); img = String(get(b, "image", ""))
        getstr(k) = (v = get(b, k, nothing); (v isa AbstractString && !isempty(v)) ? String(v) : nothing)
        svg = getstr("svg"); svg_dark = getstr("svgDark")
        (isempty(cell) || isempty(img)) && return _json(Dict("ok" => false))
        try; set_snapshot!(nb.id, cell, Vector{UInt8}(Base64.base64decode(img)); svg = svg, svg_dark = svg_dark); catch; return _json(Dict("ok" => false)); end
        _json(Dict("ok" => true))
    end))
    # Live cell inspect: the open tab POSTs a cell's captured DOM + console + raster in answer to an
    # `inspect:` SSE request (assets/js/inspect.js), routed back to the waiting slate.inspect call.
    HTTP.register!(router, "POST", "/api/{id}/inspect-result", req -> _withnb(h, req, nb -> begin
        b = _body(req); reqid = String(get(b, "reqid", ""))
        isempty(reqid) && return _json(Dict("ok" => false))
        cell = String(get(b, "cell", "")); png = String(get(b, "png", ""))   # raster → snapshot store (slate.view)
        (isempty(cell) || isempty(png)) || (try; set_snapshot!(nb.id, cell, Vector{UInt8}(Base64.base64decode(png))); catch; end)
        _json(Dict("ok" => deliver_live!(reqid, b)))
    end))
    # slate.eval_js: the open tab POSTs the result of running agent-supplied JS (assets/js/inspect.js
    # `_slateEvalJs`), in answer to a `js:` SSE request, routed back to the waiting eval call.
    HTTP.register!(router, "POST", "/api/{id}/eval-result", req -> _withnb(h, req, nb -> begin
        b = _body(req); reqid = String(get(b, "reqid", ""))
        isempty(reqid) && return _json(Dict("ok" => false))
        _json(Dict("ok" => deliver_live!(reqid, b)))
    end))
    # Browser diagnostics push (console errors / failed requests / unhandled rejections) →
    # read back by the slate.diag MCP tool. See assets/js/diag.js.
    HTTP.register!(router, "POST", "/api/{id}/diag", req -> _withnb(h, req, nb -> begin
        set_diag!(nb.id, _body(req)); _json(Dict("ok" => true))
    end))
    # Unified per-notebook config (the "Notebook config" panel). GET returns every durable setting
    # with its effective value + source (override vs global/default); POST sets or clears one override
    # ({key, value} — or {key, clear:true} / an empty value to follow the global). Registry-driven, so
    # it stays in lockstep with the Slate.config footer whitelist.
    HTTP.register!(router, "GET", "/api/{id}/config", req -> _withnb(h, req, nb ->
        _json(notebook_config_payload(nb))))
    HTTP.register!(router, "POST", "/api/{id}/config", req -> _withnb(h, req, nb -> begin
        b = _body(req); key = String(get(b, "key", ""))
        res = set_notebook_config!(nb, key, get(b, "value", ""); clear = get(b, "clear", false) === true)
        get(res, "ok", false) === true || return _json(res)
        j = state_json(nb); j["config"] = notebook_config_payload(nb); _json(j)
    end))
    # Per-notebook toggle for parent /src hot-reload (Revise). Stored in report meta.
    HTTP.register!(router, "POST", "/api/{id}/hotreload", req -> _withnb(h, req, nb -> begin
        nb.report.meta["hotreload"] = get(_body(req), "enabled", true) === true
        _persist!(nb)                                    # write the Slate.config footer so it sticks
        _json(state_json(nb))                            # return the full state so the client stays in sync
    end))
    # Per-notebook toggle for parallel (inter-cell) execution. Stored in report meta; the runner reads
    # it each iteration, so it takes effect on the next run with no worker restart.
    HTTP.register!(router, "POST", "/api/{id}/parallel", req -> _withnb(h, req, nb -> begin
        nb.report.meta["parallel"] = get(_body(req), "enabled", false) === true
        _persist!(nb)                                    # write the Slate.config footer so it sticks
        _json(state_json(nb))                            # return the full state so the client stays in sync
    end))
    # Per-notebook slide-deck presentation prefs (heading level / transition / theme / PDF ratio).
    # Stored in report meta; persisted to the Slate.config footer. No worker restart — purely
    # presentation. Body keys: level (int), transition, theme, ratio (any subset).
    HTTP.register!(router, "POST", "/api/{id}/slideconfig", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        haskey(b, "level") && (nb.report.meta["slidelevel"] = something(tryparse(Int, string(b["level"])), 2))
        haskey(b, "transition") && (nb.report.meta["slidetransition"] = String(b["transition"]))
        haskey(b, "theme") && (nb.report.meta["slidetheme"] = String(b["theme"]))
        haskey(b, "ratio") && (nb.report.meta["slideratio"] = String(b["ratio"]))
        haskey(b, "bibstyle") && (nb.report.meta["bibstyle"] = String(b["bibstyle"]))
        _persist!(nb)
        _json(state_json(nb))
    end))
    # Per-notebook worker-thread override. "" clears it (back to the global). Applies by respawning this
    # notebook's worker — so changing it kills + restarts the process (lose the warm namespace), unlike
    # the parallel toggle. Stored in meta so it survives reloads; the .jl footer carries it across restarts.
    HTTP.register!(router, "POST", "/api/{id}/threads", req -> _withnb(h, req, nb -> begin
        spec = strip(String(get(_body(req), "threads", "")))
        if isempty(spec)
            delete!(nb.report.meta, "threads")
        else
            nb.report.meta["threads"] = spec
        end
        nb.kernel isa ReportEngine.GateKernel && (nb.kernel.threads = spec)   # update the live kernel's override
        _persist!(nb)                                                          # write the Slate.config footer
        restart_kernel!(nb)                                                    # respawn the worker with it
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/reset", req -> _withnb(h, req, nb -> begin
        ReportEngine.reset!(nb.kernel, nb.report); build_dependencies!(nb.report); _eval!(nb); _json(state_json(nb))
    end))
    # ── Time machine: durable edit history ───────────────────────────────────
    # List checkpoints (newest data is appended last); `current` marks the live state.
    HTTP.register!(router, "GET", "/api/{id}/history", req -> _withnb(h, req, nb ->
        _json(Dict("entries" => SlateHistory.entries(nb.path),
                   "current" => SlateHistory.latest_hash(nb.path)))))
    # Full serialized source of one recorded state (for preview / diff / replay).
    HTTP.register!(router, "GET", "/api/{id}/history/{hash}", req -> _withnb(h, req, nb -> begin
        hash = HTTP.getparam(req, "hash")
        src = SlateHistory.content(nb.path, hash)
        src === nothing ? HTTP.Response(404, "no such snapshot") :
            _json(Dict("hash" => hash, "source" => src))
    end))
    # Restore a recorded state (non-destructive: recorded as a new checkpoint).
    HTTP.register!(router, "POST", "/api/{id}/history/restore", req -> _withnb(h, req, nb -> begin
        hash = String(get(_body(req), "hash", ""))
        restore_history!(nb, hash) ? _json(state_json(nb)) : HTTP.Response(404, "no such snapshot")
    end))
    # Publishing manager: ledger view, target/secret config, per-notebook doc info (see server_publish.jl).
    _register_publish_routes!(router, h)
    return router
end

const _EVENTS_RE = r"^/api/([^/]+)/events$"
const _PUBLISH_RE = r"^/api/([^/]+)/publish-run\b"
const _SITE_PUBLISH_RE = r"^/api/([^/]+)/site-publish\b"
const _SITE_SYNC_RE = r"^/api/publish/site-sync\b"

# ── Cross-origin defense (CSRF / DNS-rebinding) ───────────────────────────────
# The API evaluates arbitrary Julia by design, so a browser page from ANY origin
# must not be able to drive it. Two header checks (mirroring Jupyter's model):
#   • Host allowlist — the `Host` a rebinding attacker's page carries is their own
#     domain, not a loopback name, so pinning Host defeats DNS rebinding.
#   • Origin allowlist — a cross-site fetch carries the attacker's Origin; reject it.
# Loopback names pass by default; add LAN/tunnel names via KAIMONSLATE_ALLOWED_HOSTS
# (comma-separated host or host:port). No Origin (a top-level navigation) is fine.
function _allowed_hosts(h::Hub)
    hosts = Set{String}(["127.0.0.1", "localhost", "::1"])
    push!(hosts, h.host)
    for x in split(get(ENV, "KAIMONSLATE_ALLOWED_HOSTS", ""), ','; keepempty = false)
        s = _hostonly(strip(x))
        isempty(s) || push!(hosts, s)
    end
    return hosts
end

# Strip an optional `:port` (and IPv6 brackets) from a Host/authority, leaving the bare host.
function _hostonly(hp::AbstractString)
    s = strip(String(hp))
    isempty(s) && return ""
    if startswith(s, "[")                       # [::1] or [::1]:8765
        j = findfirst(']', s)
        return j === nothing ? s : s[2:prevind(s, j)]
    end
    i = findlast(':', s)
    (i !== nothing && i < lastindex(s) && all(isdigit, s[nextind(s, i):end])) && return s[1:prevind(s, i)]
    return s
end

# Allow the request iff its Host is loopback/allowlisted AND its Origin (when present)
# resolves to an allowlisted host. Returns false to reject with 403.
function _request_allowed(h::Hub, msg)::Bool
    allowed = _allowed_hosts(h)
    host = _hostonly(HTTP.header(msg, "Host", ""))
    (isempty(host) || host in allowed) || return false
    origin = strip(HTTP.header(msg, "Origin", ""))
    if !isempty(origin) && origin != "null"
        ohost = try; _hostonly(HTTP.URI(origin).host); catch; ""; end
        (ohost in allowed) || return false
    end
    return true
end

"""
    start_hub(; host="127.0.0.1", port=8765) -> Hub

Start the single notebook server with an empty registry. Add notebooks with
[`open_notebook!`](@ref). Non-blocking.
"""
function start_hub(; host = "127.0.0.1", port = 8765)
    h = Hub(Dict{String,LiveNotebook}(), nothing, host, port, ReentrantLock())
    handle = HTTP.streamhandler(_make_router(h))
    server = HTTP.listen!(host, port) do stream::HTTP.Stream
        # Reject cross-origin / rebinding requests before ANY handler (router or SSE) runs.
        if !_request_allowed(h, stream.message)
            HTTP.setstatus(stream, 403); HTTP.startwrite(stream); return
        end
        target = stream.message.target
        m = match(_EVENTS_RE, target)
        if m !== nothing
            nb = lock(h.lock) do; get(h.notebooks, m.captures[1], nothing); end
            nb === nothing && (nb = _reopen_persisted!(h, m.captures[1]))   # re-register after a restart
            nb === nothing ? (HTTP.setstatus(stream, 404); HTTP.startwrite(stream)) : _sse(stream, nb)
        elseif startswith(target, "/api/import-standalone")   # long-lived SSE; raw Stream, not router
            _sse_import(stream, h)
        elseif startswith(target, "/api/preflight-stream")     # streamed remote preflight (step-by-step)
            _sse_preflight(stream, h)
        elseif occursin(_PUBLISH_RE, target)                  # multi-target publish; per-target SSE progress
            _sse_publish(stream, h)
        elseif occursin(_SITE_PUBLISH_RE, target)             # build notebook into a site + sync all destinations
            _sse_site_publish(stream, h)
        elseif occursin(_SITE_SYNC_RE, target)                # re-sync a site's build to all destinations
            _sse_site_sync(stream, h)
        else
            t0 = time()
            handle(stream)
            dt = time() - t0      # includes the body WRITE — surfaces slow transfers, not just slow compute
            dt > 1.0 && @warn "Kaimon Slate: slow request" target round_ms = round(Int, dt * 1000)
        end
    end
    h.server = server
    @info "Kaimon Slate hub" url = _hub_url(h)
    return h
end

"""
    open_notebook!(hub, path) -> id

Load the notebook at `path` into the hub (reusing the existing entry if already
open) and start its file watcher. Returns the hub id (its `/n/<id>` route).
"""
function open_notebook!(h::Hub, path::AbstractString; threads::AbstractString = "", runon::AbstractString = "")
    file = abspath(path)
    id = lock(h.lock) do
        for nb in values(h.notebooks)
            abspath(nb.path) == file && return nb.id
        end
        id = _unique_id(h, file)
        nb = load_notebook(file; id = id, threads = threads, runon = runon)
        h.notebooks[id] = nb
        _start_watcher!(nb)
        return id
    end
    _persist_registry!(h)        # remember id→path so a restart can lazily re-open it
    return id
end

"Remove a notebook from the hub: drain its SSE connections and drop it."
function close_notebook!(h::Hub, id::AbstractString)
    removed = lock(h.lock) do
        nb = get(h.notebooks, id, nothing)
        nb === nothing && return false
        # Tell open tabs the close is DELIBERATE before draining their SSE. Without this the
        # client's disconnect recovery reads the ensuing 404 as a crashed server and re-opens
        # the notebook by path — respawning it seconds after every close. The queued message
        # still reaches each tab: a closed Channel drains its buffered items first.
        _broadcast(nb, "closed:hub")
        _close_listeners(nb)
        _close_agent!(nb)
        _unwire_callbacks!(nb)
        try; shutdown!(nb.kernel); catch; end
        lock(_EVAL_MUTEX_LOCK) do; delete!(_EVAL_MUTEX, id); end
        delete!(h.notebooks, id)
        return true
    end
    removed && _persist_registry!(h)        # forget an explicitly-closed nb so a restart won't re-open it
    return removed
end

"Stop the hub: drain every notebook's SSE connections, then close the server."
function stop_hub(h::Hub)
    lock(h.lock) do
        for nb in values(h.notebooks)
            _close_listeners(nb); _unwire_callbacks!(nb)
            try; shutdown!(nb.kernel); catch; end
        end
        empty!(h.notebooks)
    end
    h.server === nothing || close(h.server)
    return nothing
end

