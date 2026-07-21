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
    # An explicit restart must yield a FRESH worker — with a detached (still-warm) remote, prepare!'s
    # reattach-first would re-adopt the same process and the restart would no-op. The worker teardown is
    # a BLOCKING round-trip, so it runs OFF `nb.lock` (protocol: never hold nb.lock across a kernel call).
    # Interrupt any in-flight eval first so `shutdown!` doesn't block behind it (the deadlock this fixes:
    # holding nb.lock across `shutdown!` while the runner needs nb.lock to finish → hub wedges).
    _interrupt_inflight!(nb)
    try; ReportEngine.shutdown!(nb.kernel; kill_remote = true); catch; end
    _teardown_region!(nb; kill = true)       # region kernels restart fresh too (+ sync state reset)
    with_report(nb) do report                # lock only for the report reset/mutate (no round-trip)
        ReportEngine.reset!(nb.kernel, report)
        build_dependencies!(report)
        report.meta["hydrating"] = true
        nb.version += 1
    end
    _broadcast(nb, "restart")
    @async begin
        try
            # Locked cells restore first, AHEAD of the sequential full run below — a `reset!` restart
            # wipes every cell to STALE (including locked ones), and without this a locked cell would
            # sit STALE behind however many slow unlocked cells precede it in document order, despite
            # its own restore costing nothing. `_drain!`'s document-order sweep below just skips them
            # once they're FRESH again.
            _self_heal_locked!(nb)
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
    try; ReportEngine.shutdown!(nb.kernel); catch; end         # blocking teardown — OFF nb.lock (local killed; remote detached, idles warm)
    with_report(nb) do report
        s = strip(String(spec))
        isempty(s) ? delete!(report.meta, "remoteworker") : (report.meta["remoteworker"] = String(s))
        nb.kernel = _select_kernel(nb.path, report)            # remote attach vs local, per the meta
        build_dependencies!(report)
        # New worker → empty namespace → re-run every cell (this is what drives prepare!→attach). Cells
        # left FRESH would give the runner nothing to do and the worker would never be reached. See reset!.
        ReportEngine.reset_all!(report)
        report.meta["hydrating"] = true
        nb.version += 1
    end
    _broadcast(nb, "restart")
    @async begin
        try
            _self_heal_locked!(nb)                              # see restart_kernel!'s comment: same wipe pattern
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
    scope === :session ||     # notebook/clear change the durable footer → write the .jl
        _persist!(nb; label = (scope === :clear || isempty(strip(String(spec)))) ? "run local" : "run on · $(strip(String(spec)))")
    if unchanged
        try; _broadcast(nb, string(nb.version)); catch; end    # refresh state (source badge) — worker untouched
        return nb
    end
    # Actually switching → stop the current evaluation NOW (don't drain it), then tear down + re-pick.
    _interrupt_inflight!(nb)
    try; ReportEngine.shutdown!(nb.kernel); catch; end         # blocking teardown — OFF nb.lock (local killed; remote detached)
    with_report(nb) do report
        nb.kernel = _select_kernel(nb.path, report)
        remotehost = (nb.kernel isa ReportEngine.GateKernel && nb.kernel.target isa ReportEngine.RemoteTarget) ?
                     nb.kernel.target.ssh_host : ""
        build_dependencies!(report)
        # The new worker has an EMPTY namespace → every cell must re-run on it. Invalidate all cells so
        # `_drain!` re-evaluates them; mirrors ReportEngine.reset!.
        ReportEngine.reset_all!(report)
        delete!(report.meta, "hydrate_error")
        report.meta["hydrating"] = true
        # Tell the banner this is a remote bring-up (provision + connect can take minutes) rather than a
        # plain re-run — so the UI stops implying it's "running cells" while the worker isn't even up yet.
        isempty(remotehost) ? delete!(report.meta, "hydratingKind") :
            (report.meta["hydratingKind"] = "remote"; report.meta["hydratingHost"] = remotehost)
        nb.version += 1
    end
    _broadcast(nb, "restart")
    @async begin
        try
            # For a remote target, bring the worker up ONCE up front (provision → spawn → connect). This is
            # the interception point: a spawn/provision failure becomes a SINGLE notebook-level error
            # (the hydrate-error banner) instead of the identical error stamped onto every cell. Only once
            # the worker is really connected do we run the cells.
            _self_heal_locked!(nb)                              # see restart_kernel!'s comment: same wipe pattern
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
                for c in nb.report.cells; c.output = nothing; ReportEngine.revert_running!(c); end  # nothing ran → no per-cell errors
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
include("memostore.jl")      # MemoStore (server-side copy — stateless, root passed explicitly): pack/unpack
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

# ── Project source browser (the Files tab) ────────────────────────────────────────────────────────
# The notebook develops its OWN package: `project/src` + `project/notebooks`. These helpers back the
# Files tab — browse + edit text source under the notebook's project root, path-guarded. A save just
# writes to disk; the worker's Revise hot-reload watcher picks it up exactly like an external edit.
const _TREE_SKIP_DIRS = Set{String}([".git", ".julia", "node_modules", "compiled", "build",
                                     ".cache", "__pycache__", ".vscode", ".claude", ".ipynb_checkpoints"])
const _TREE_EXTS = Set{String}([".jl", ".toml", ".md", ".txt", ".r", ".py", ".qmd", ".csv"])   # editable text

# The notebook's project root (its parent project dir — the `@asset` base). "" ⇒ in-process / no project.
_proj_root(nb::LiveNotebook) = String(get(nb.report.meta, "assetbase", ""))

# Confine a client-supplied RELATIVE path to `root`: reject absolute paths and any `..` escape.
# Returns the normalized absolute path, or "" if the root is unset or the path escapes.
function _safe_proj_path(root::AbstractString, rel::AbstractString)
    (isempty(root) || isempty(rel) || isabspath(rel)) && return ""
    rp = normpath(String(root))
    ap = normpath(joinpath(rp, String(rel)))
    sep = Base.Filesystem.path_separator
    (ap == rp || startswith(ap, endswith(rp, sep) ? rp : rp * sep)) || return ""
    return ap
end

# Editable source tree under `root`: dirs (that contain something) before text files, alphabetical,
# skipping VCS/build/hidden noise. Each node: {name, path (root-relative), dir}, dirs carry `children`.
function _proj_tree(root::AbstractString, dir::AbstractString; depth::Int = 0)
    nodes = Any[]
    depth > 10 && return nodes
    entries = try; sort!(readdir(dir)); catch; return nodes; end
    for name in entries                                    # directories first
        (isempty(name) || startswith(name, ".") || name in _TREE_SKIP_DIRS) && continue
        p = joinpath(dir, name); isdir(p) || continue
        kids = _proj_tree(root, p; depth = depth + 1)
        isempty(kids) && continue                          # prune dirs with no editable content
        push!(nodes, Dict{String,Any}("name" => name, "path" => relpath(p, root), "dir" => true, "children" => kids))
    end
    for name in entries                                    # then text files
        startswith(name, ".") && continue
        p = joinpath(dir, name)
        (isfile(p) && lowercase(splitext(name)[2]) in _TREE_EXTS) || continue
        push!(nodes, Dict{String,Any}("name" => name, "path" => relpath(p, root), "dir" => false,
                                      "bytes" => (try; filesize(p); catch; 0; end)))
    end
    return nodes
end

# ── Portable data-dir transport: sync `datadir()` to a remote worker ────────────────────────────────
# When a cell runs on a REMOTE worker, its `@sfile`/`datadir()` files must be present there. We
# content-address each datadir file into the local CAS (`MemoStore.put_blob`) and ship it over the SAME
# dedup-aware blob data channel the memo/boundary transport uses (`push_blob!`); the worker copies each
# into its own `datadir()` (`__slate_materialize_datadir`). Once per (nb, remote kernel), skipped when
# unchanged (a manifest signature) and when the dst shares our filesystem (local / localhost region);
# mtime-cached so an unchanged multi-GB file is never re-hashed. Reuses the transport, adds no socket.
const _DATADIR_LOCK = ReentrantLock()
const _DATADIR_SYNCED = Dict{Tuple{String,UInt},UInt}()             # (nb id, dst objectid) → last manifest sig
const _DATADIR_SHACACHE = Dict{Tuple{String,Float64,Int},String}()  # (path, mtime, size) → sha (skip re-hash)
function _sync_datadir_to!(nb::LiveNotebook, dst_k; cell_id::AbstractString = "")
    (dst_k isa ReportEngine.GateKernel && dst_k.target isa ReportEngine.RemoteTarget) || return nothing
    # A localhost region shares our filesystem — its `datadir()` resolves to the SAME path, so the
    # files are already there. Skip the pointless (and slow) content-address + push.
    host = String(dst_k.target.ssh_host)
    (isempty(host) || host in ("localhost", "127.0.0.1", "::1") || host == gethostname()) && return nothing
    # Only a LIVE, connected region kernel — never hash the datadir or dial a dead host for a region
    # that was merely DECLARED (regionon footer) but isn't actually up.
    (try; dst_k.conn !== nothing; catch; false; end) || return nothing
    root = _proj_root(nb); (isempty(root) || !isdir(joinpath(root, "data"))) && return nothing
    ddir = joinpath(root, "data")
    cas = joinpath(ReportEngine._slate_cache_dir(), "memo")
    # Drive the running cell's progress bar (SSE) — a multi-GB DuckDB push is otherwise a silent
    # multi-minute stall with no indication of what's happening. Off (cell_id empty) ⇒ no reporting.
    pid = "datadir-" * String(cell_id)
    prog(frac, msg, done) = isempty(cell_id) ? nothing :
        (try; ReportEngine._do_userprog(nb.report.id, Float64(frac), msg, pid, done); catch; end; nothing)
    files = Any[]; fbytes = Int[]
    for (dir, _, names) in walkdir(ddir), name in names
        p = joinpath(dir, name)
        st = try; stat(p); catch; continue; end
        (st.size == 0 || islink(p)) && continue
        ckey = (p, st.mtime, Int(st.size))
        h = lock(_DATADIR_LOCK) do; get(_DATADIR_SHACACHE, ckey, ""); end
        if isempty(h)
            # First sight of a (possibly large) file — content-addressing reads the whole thing, so a
            # 166 MB DuckDB is minutes right here. Say so; the sha is mtime-cached, so re-runs are instant.
            prog(0.0, "⇄ data: hashing $(relpath(p, ddir)) ($(round(Int, st.size / 2^20)) MB)…", false)
            h = try; String(MemoStore.put_blob(io -> open(f -> write(io, f), p), cas)[1]); catch; ""; end
            isempty(h) && continue
            lock(_DATADIR_LOCK) do; _DATADIR_SHACACHE[ckey] = h; end
        end
        push!(files, Dict{String,Any}("rel" => relpath(p, ddir), "hash" => h)); push!(fbytes, Int(st.size))
    end
    isempty(files) && return nothing
    sig = hash(sort!([String(f["hash"]) for f in files]))
    skey = (nb.id, _worker_key(dst_k))   # ns_gen-folded: a swapped worker's empty datadir re-materialises
    lock(_DATADIR_LOCK) do; get(_DATADIR_SYNCED, skey, UInt(0)); end == sig && return nothing
    ep = try; ReportEngine._data_endpoint!(dst_k.target, dst_k); catch; return nothing; end
    total = max(sum(fbytes), 1); moved = 0
    for (i, f) in enumerate(files)
        prog(moved / total, "⇄ data → $host: $(f["rel"]) [$i/$(length(files))] " *
             "($(round(Int, moved / 2^20))/$(round(Int, total / 2^20)) MB)", false)
        try; ReportEngine.push_blob!(ep.ip, ep.port, String(f["hash"]); server_key = ep.server_key); catch; end
        moved += fbytes[i]
    end
    prog(1.0, "⇄ data → $host: placing $(length(files)) file(s)…", false)
    try
        ReportEngine._tool(dst_k, "__slate_materialize_datadir", Dict{String,Any}("files" => files); timeout = 600.0)
    catch e
        prog(1.0, "⇄ data sync to $host failed", true)
        ReportEngine._rlog("datadir sync: materialize failed on $host — $(first(sprint(showerror, e), 160))")
        return nothing
    end
    prog(1.0, "", true)   # clear the bar
    lock(_DATADIR_LOCK) do; _DATADIR_SYNCED[skey] = sig; end
    ReportEngine._rlog("datadir sync → $host: $(length(files)) file(s)")
    return nothing
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
        # `autorun=false` opens WITHOUT the initial run (cells land STALE) — e.g. to tag a cell `locked`
        # or otherwise edit before anything runs. Also only applied on a fresh open.
        # `inactive=true` opens DORMANT: show the embedded frozen render, spawn no worker, and wait for a
        # click on the "Inactive — click to launch" pill (`/api/launch`). The default for downloaded/
        # uploaded standalones (see run.jl); the author's own files open live.
        id = open_notebook!(h, path; runon = strip(String(get(b, "runon", ""))),
                            autorun = get(b, "autorun", true) !== false,
                            inactive = get(b, "inactive", false) === true)
        _json(Dict("id" => id, "url" => "/n/$id", "path" => abspath(path)))
    end)
    # Launch an INACTIVE (dormant) notebook: flip it to hydrating and kick off the standard standalone
    # bring-up (`_hydrate_standalone!` — reconstruct env, spawn worker, restore locked/memo results, run).
    # This is what the grey "Inactive — click to launch" pill hits. Idempotent + no-op once active.
    HTTP.register!(router, "POST", "/api/{id}/launch", req -> _withnb(h, req, nb -> begin
        launch_notebook!(nb) || return _json(Dict("ok" => false, "note" => "already active"))
        _json(Dict("ok" => true))
    end))
    # Upload a file from the browser (the viewing machine) → save it under a persistent uploads dir and
    # return its server path; the front end then classifies + opens it via the normal open/import flow.
    # Accepts a `.jl` (notebook or self-contained bundle) OR a runnable `.html` export (whose embedded
    # bundle we extract on open) — the extension is preserved so classification can tell them apart.
    # Body: {name, content}.
    HTTP.register!(router, "POST", "/api/upload", req -> begin
        b = _body(req)
        content = String(get(b, "content", ""))
        isempty(strip(content)) && return HTTP.Response(400, "empty upload")
        name = basename(replace(String(get(b, "name", "notebook.jl")), r"[^\w.\-]" => "_"))
        isempty(name) && (name = "notebook.jl")
        stem, ext = splitext(name); ext = lowercase(ext)
        ext in (".jl", ".html", ".htm") || return HTTP.Response(400,
            "Unsupported file type “$(isempty(ext) ? "?" : ext)”. Upload a .jl notebook or bundle, or a runnable .html export.")
        dir = joinpath(homedir(), "KaimonSlate", "uploads"); mkpath(dir)
        path = joinpath(dir, name); i = 1
        while ispath(path); i += 1; path = joinpath(dir, "$(stem)-$(i)$(ext)"); end   # never overwrite an existing file
        write(path, content)
        _json(Dict("path" => abspath(path)))
    end)
    # Extract the embedded standalone bundle from a RUNNABLE HTML export into a real `.jl` under the
    # uploads dir, returning its path — the front end then routes it through the standalone import flow,
    # exactly like a downloaded `.jl` bundle. Body: {path}.
    HTTP.register!(router, "POST", "/api/extract-html-bundle", req -> begin
        p = expanduser(strip(String(get(_body(req), "path", ""))))
        src = _html_bundle_source(p)
        src === nothing && return HTTP.Response(422,
            "This HTML has no embedded runnable bundle (it's a static export). Re-export with the “Runnable” option to get a launchable notebook.")
        dir = joinpath(homedir(), "KaimonSlate", "uploads"); mkpath(dir)
        stem = replace(splitext(basename(p))[1], r"[^\w.\-]" => "_"); isempty(stem) && (stem = "notebook")
        out = joinpath(dir, "$(stem).jl"); i = 1
        while ispath(out); i += 1; out = joinpath(dir, "$(stem)-$(i).jl"); end
        write(out, src)
        _json(Dict("path" => abspath(out)))
    end)
    # Create a NEW notebook from a plain Julia script (no Slate structure), leaving the original
    # untouched: copy it beside the source as `<stem>-notebook.jl` (falling back to the uploads dir if
    # that directory isn't writable). The copy opens as an ordinary notebook — `parse_report` turns a
    # plain script into cells, and the first save rewrites it in canonical `#%%` form. Body: {path}.
    HTTP.register!(router, "POST", "/api/notebook-from-script", req -> begin
        p = expanduser(strip(String(get(_body(req), "path", ""))))
        isfile(p) || return HTTP.Response(404, "no such file: $p")
        content = read(p, String)
        stem = splitext(basename(p))[1]; isempty(stem) && (stem = "notebook")
        _dest(base) = begin
            o = joinpath(base, "$(stem)-notebook.jl"); i = 1
            while ispath(o); i += 1; o = joinpath(base, "$(stem)-notebook-$(i).jl"); end
            o
        end
        out = _dest(dirname(abspath(p)))
        try
            write(out, content)
        catch
            dir = joinpath(homedir(), "KaimonSlate", "uploads"); mkpath(dir)
            out = _dest(dir); write(out, content)
        end
        _json(Dict("path" => abspath(out)))
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
        # import-into-a-project helper instead of opening it bare. `kind` is the fuller classification
        # (bundle / notebook / plain / html-bundle / html-static / foreign) that the open box routes on.
        _json(Dict("path" => p, "exists" => ispath(p), "isdir" => isdir(p), "isfile" => isfile(p),
                   "standalone" => isfile(p) && _has_bundle_footer(p),
                   "kind" => _source_kind(p)))
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
        "confirm_s" => ReportEngine.XFER_CONFIRM_S[],
        "effective_chunk_mb" => round(ReportEngine._blob_chunk() / 2^20; digits = 2),
        "effective_carry_max_s" => ReportEngine._carry_ceiling_s(),
        "effective_confirm_s" => ReportEngine._xfer_confirm_s()))
    HTTP.register!(router, "GET", "/api/transfer-settings", _ -> _xfer_json())
    HTTP.register!(router, "POST", "/api/transfer-settings", req -> begin
        b = _body(req)
        chunk = max(0.0, something(tryparse(Float64, string(get(b, "chunk_mb", ""))), 0.0))
        carry = max(0.0, something(tryparse(Float64, string(get(b, "carry_max_s", ""))), 0.0))
        # confirm: -1 = unset (default applies); 0 = explicitly disabled — the sentinel matters
        confirm = something(tryparse(Float64, string(get(b, "confirm_s", "-1"))), -1.0)
        p = _XFER_PERSIST[]
        if p !== nothing
            try; p(chunk, carry, confirm); catch e; @warn "slate: could not persist transfer settings" exception = e; end
        else                                             # standalone hub: live-only, no slate.json
            ReportEngine.BLOB_CHUNK_MB[] = chunk; ReportEngine.CARRY_MAX_S[] = carry
            ReportEngine.XFER_CONFIRM_S[] = confirm
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
    # Global region registry (named compute defs) + parked wires — the hub's own view, NO ssh. Per-host
    # live rosters come from /api/remote-workers. Feeds the home-page Regions manager + Destinations picker.
    HTTP.register!(router, "GET", "/api/regions", _ -> _json(Dict(
        "regions" => [begin
            st = ReportEngine.region_status(r.name)
            Dict("name" => r.name, "host" => r.host, "transport" => String(r.transport),
                 "base_port" => r.base_port, "preload" => r.preload, "data_root" => r.data_root,
                 "warm" => r.warm, "threads" => r.threads, "sysimage" => r.sysimage,
                 # Last reconcile outcome — so a silent background spawn failure is visible.
                 "status" => st === nothing ? nothing :
                             Dict("ok" => st.ok, "msg" => st.msg, "age" => round(Int, time() - st.ts)))
        end for r in ReportEngine.regions()],
        "parked" => [Dict("host" => p.host, "label" => p.label, "port" => p.port,
                          "idle_s" => p.idle_s) for p in ReportEngine.parked_wires()])))
    # Create/update a named region (full-record upsert) and reconcile toward its warm count. The def is
    # persisted synchronously (fast, durable); the reconcile — which may provision a cold host for minutes —
    # runs in the background so the request returns at once. Re-runnable: it reconciles toward `warm`.
    HTTP.register!(router, "POST", "/api/regions", req -> begin
        b = _body(req)
        name = strip(String(get(b, "name", "")))
        isempty(name) && return _json(Dict("ok" => false, "error" => "need a region name"))
        host = strip(String(get(b, "host", "")))
        tr = Symbol(strip(String(get(b, "transport", "tunnel")))); tr in (:tunnel, :direct) || (tr = :tunnel)
        base_port = something(tryparse(Int, string(get(b, "base_port", "0"))), 0)
        (base_port == 0 || 1024 <= base_port <= 65533) ||
            return _json(Dict("ok" => false, "error" => "base_port must be 0 (auto) or 1024–65533"))
        warm = something(tryparse(Int, string(get(b, "warm", "0"))), 0); warm < 0 && (warm = 0)
        preload = strip(String(get(b, "preload", "")))
        (isempty(preload) || isdir(expanduser(preload))) ||
            return _json(Dict("ok" => false, "error" => "preload project dir not found: $preload"))
        data_root = strip(String(get(b, "data_root", "")))   # workers' data dir ON THE HOST (remote path) — verbatim
        threads = strip(String(get(b, "threads", "")))
        sysimage = string(get(b, "sysimage", "false")) in ("true", "1", "on", "yes")
        do_reconcile = string(get(b, "reconcile", "true")) != "false"
        r = ReportEngine.region_set!(name; host = host, transport = tr, base_port = base_port,
                                     preload = isempty(preload) ? "" : abspath(expanduser(preload)),
                                     data_root = data_root, warm = warm, threads = threads, sysimage = sysimage)
        do_reconcile && Threads.@spawn try
            ReportEngine.region_reconcile!(r.name)   # no-op when warm==0 except draining excess
        catch e
            @warn "slate: region reconcile failed" region = r.name exception = (e, catch_backtrace())
        end
        _json(Dict("ok" => true, "name" => r.name))
    end)
    # Delete a region: drain its warm workers first (best-effort), then drop the definition.
    HTTP.register!(router, "POST", "/api/regions/delete", req -> begin
        b = _body(req)
        name = strip(String(get(b, "name", "")))
        isempty(name) && return _json(Dict("ok" => false, "error" => "need a region name"))
        Threads.@spawn try; ReportEngine.region_remove!(name); catch e
            @warn "slate: region remove failed" region = name exception = (e, catch_backtrace())
        end
        _json(Dict("ok" => true, "name" => name))
    end)
    # Manually reap a specific remote worker (kill process + remove its manifest). Body {host, port}.
    # Never automatic — the user decides, so a worker with useful results is never killed out from under them.
    HTTP.register!(router, "POST", "/api/reap-worker", req -> begin
        b = _body(req)
        host = strip(String(get(b, "host", "")))
        port = tryparse(Int, string(get(b, "port", "")))
        (isempty(host) || port === nothing) && return _json(Dict("ok" => false, "error" => "need host + port"))
        try; _drop_kernels_for_worker!(h, host, port); catch; end   # wake any eval bound to this worker before it dies
        _json(Dict("ok" => ReportEngine.reap_remote_worker(host, port)))
    end)
    # Recorded telemetry history for a worker on a host — the hub's ring for its live kernel connection,
    # for the worker-detail popup's CPU/memory history chart. Query {host, port}. Empty `samples` when the
    # hub isn't connected to that worker (only its point-in-time `.stats` is then available via the roster).
    HTTP.register!(router, "GET", "/api/worker-stats", req -> begin
        q = HTTP.queryparams(HTTP.URI(req.target))
        host = strip(String(get(q, "host", ""))); port = tryparse(Int, String(get(q, "port", "")))
        (isempty(host) || port === nothing) && return _json(Dict("ok" => false, "error" => "need host + port"))
        hist = ReportEngine.worker_stats_history(host, port)
        _json(Dict("ok" => true, "host" => host, "port" => port,
                   "samples" => [Dict("t" => round(s.rcv), "cpu" => s.cpu, "rss" => s.rss, "memo" => s.memo,
                                      "sys_cpu" => s.sys_cpu, "load1" => s.load1) for s in hist]))
    end)
    # Sysimage build state for a region's env — one ssh to the host: is it built (key/size/age), building
    # now, is there a compiler. Feeds the Regions UI sysimage panel. Query {region}.
    HTTP.register!(router, "GET", "/api/sysimage", req -> begin
        name = strip(String(get(HTTP.queryparams(HTTP.URI(req.target)), "region", "")))
        isempty(name) && return _json(Dict("ok" => false, "error" => "need a region"))
        st = ReportEngine.sysimage_status_for_region(name)
        st === nothing && return _json(Dict("ok" => false, "error" => "no region '$name'"))
        _json(merge(Dict("ok" => true), st))
    end)
    # Explicitly (re)build a region's worker sysimage — forced past the per-region opt-in. Provisions (idempotent)
    # then launches the detached build; returns at once, the UI polls GET /api/sysimage. Body {region}.
    HTTP.register!(router, "POST", "/api/sysimage/build", req -> begin
        b = _body(req)
        name = strip(String(get(b, "region", "")))
        isempty(name) && return _json(Dict("ok" => false, "error" => "need a region"))
        r = ReportEngine.sysimage_build_for_region!(name)
        _json(Dict("ok" => r.ok, "error" => get(r, :error, nothing), "host" => get(r, :host, nothing)))
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
    # A worker's log tail + status for the topbar worker/region status popup. `?side=` selects the
    # worker (""=main, else a region); local reads the log file, remote ssh-tails it. Polled while open.
    HTTP.register!(router, "GET", "/api/{id}/worker-log", req -> _withnb(h, req, nb -> begin
        q = HTTP.queryparams(HTTP.URI(req.target))
        side = get(q, "side", "")
        lines = clamp(something(tryparse(Int, get(q, "lines", "300")), 300), 1, 5000)
        _json(_worker_log(nb, side, lines))
    end))
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
    # Set/clear a cell behavior flag (collapsed / hidecode / trace / cache / …) across one or many cells
    # in ONE persist → one history entry. Body {flag, value, cells?}: `cells` (a list of ids) targets
    # just those, omitted ⇒ every applicable cell. An eval-affecting flag (trace/cache/…) restales and
    # re-runs in the same round-trip so its effect (e.g. the trace table) appears at once.
    HTTP.register!(router, "POST", "/api/{id}/cell-flag", req -> _withnb(h, req, nb -> begin
        b = _body(req); cs = get(b, "cells", nothing)
        flag = Symbol(String(get(b, "flag", "")))
        changed = set_cell_flag!(nb, flag, get(b, "value", true) === true;
                                 ids = cs isa AbstractVector ? cs : nothing)
        (changed && flag_reruns(flag)) && _eval!(nb)
        _json(state_json(nb))
    end))
    # Set a cell's full tag set from the tag editor (known behaviour tags + free-form). Re-runs stale
    # cells so a `trace` toggle takes effect in one round-trip.
    HTTP.register!(router, "POST", "/api/{id}/tags/{cid}", req -> _withnb(h, req, nb -> begin
        tags = get(_body(req), "tags", String[])
        before = _mesh_group_sig(_nb_defined_regions(nb))
        set_cell_tags!(nb, HTTP.getparam(req, "cid"), tags isa AbstractVector ? tags : String[])
        _eval!(nb)
        _mesh_group_sig(_nb_defined_regions(nb)) == before || _mesh_consent_check!(nb)  # tag added a region (§5.1)
        _json(state_json(nb))
    end))
    # Set which named regions this notebook uses — a comma-separated list of names from the global
    # registry. Tears down the old region kernels, persists the `regions` footer, echoes the new state.
    # Empty clears all. Cells are then tagged into a region via /api/{id}/tags (`region=<name>`).
    HTTP.register!(router, "POST", "/api/{id}/regions", req -> _withnb(h, req, nb -> begin
        set_notebook_regions!(nb, strip(String(get(_body(req), "regions", ""))))
        _json(state_json(nb))
    end))
    # ── Consent-gated region introduction (PEER_TUNNEL_PLAN §5.1) ──────────────────────────────────
    # GET the pending mesh consent (a fresh tab checks this on load; live tabs also get an SSE
    # `mesh-consent:` push). POST introduce ARMS the whole-group mesh (installs SSH keys/grants — the one
    # place that touches ~/.ssh, only on the user's explicit grant). POST dismiss records "not now" so the
    # popup won't re-nag until the region set changes again.
    HTTP.register!(router, "GET", "/api/{id}/mesh-consent", req -> _withnb(h, req, nb -> begin
        # ?force=1 (the DAG "⇄ connect" action) recomputes the consent status FRESH — bypassing both the
        # pending stash AND the "not now" dismissal — so the user can summon the popup back on demand after
        # declining (the popup's own "connect later from the peer routing plan" promise). A plain GET (a
        # fresh tab checking on load) returns only a genuinely-pending payload, so it never re-nags on its own.
        if get(HTTP.queryparams(HTTP.URI(req.target)), "force", "0") == "1"
            st = try
                ReportEngine.mesh_consent_status(_nb_defined_regions(nb))
            catch e
                Dict("connected" => true, "pairs" => Any[], "error" => first(sprint(showerror, e), 200))
            end
            return _json(merge(Dict("pending" => !get(st, "connected", true)), st))
        end
        p = _mesh_pending(nb.id)
        _json(p === nothing ? Dict("pending" => false) : merge(Dict("pending" => true), p))
    end))
    HTTP.register!(router, "POST", "/api/{id}/mesh-introduce", req -> _withnb(h, req, nb -> begin
        names = _nb_defined_regions(nb)
        prog(d) = _broadcast(nb, "mesh-build:" * JSON.json(d))    # per-pair "i/n" progress → the consent popup
        r = try
            installed = ReportEngine.introduce_group!(names;     # idempotent; whole group (§5.1)
                on_progress = (i, n, src, pul) -> prog(Dict("phase" => "run", "i" => i, "n" => n, "src" => src, "puller" => pul)))
            prog(Dict("phase" => "complete", "n" => length(installed)))
            _mesh_resolve!(nb.id); _mesh_broadcast_clear!(nb)
            Dict("ok" => true, "installed" => length(installed), "plan" => ReportEngine.peer_plan_data(names))
        catch e
            prog(Dict("phase" => "error"))
            Dict("ok" => false, "error" => first(sprint(showerror, e), 300))
        end
        _json(r)
    end))
    HTTP.register!(router, "POST", "/api/{id}/mesh-dismiss", req -> _withnb(h, req, nb -> begin
        _mesh_dismiss!(nb)
        _mesh_broadcast_clear!(nb)
        _json(Dict("ok" => true))
    end))
    # REVOKE the mesh (the inverse of introduce): drop the region('s) slate ed25519 key, its scoped
    # authorized_keys grants on every peer, and its host-key pins — the UUID-tagged artifacts, nothing a
    # human added — then forget the cached route verdicts so transfers re-probe (→ relay). `?region=<name>`
    # revokes just that one; no param revokes the whole notebook group. Reversible: introduce re-installs.
    HTTP.register!(router, "POST", "/api/{id}/mesh-teardown", req -> _withnb(h, req, nb -> begin
        one = get(HTTP.queryparams(HTTP.URI(req.target)), "region", "")
        names = isempty(one) ? _nb_defined_regions(nb) : String[one]
        r = try
            for n in names; ReportEngine.teardown_region_mesh!(n); end
            _mesh_broadcast_clear!(nb)
            Dict("ok" => true, "torn_down" => names, "plan" => ReportEngine.peer_plan_data(_nb_defined_regions(nb)))
        catch e
            Dict("ok" => false, "error" => first(sprint(showerror, e), 300))
        end
        _json(r)
    end))
    # Peer-mesh plan for the DAG region-map view: the cached route verdict per cross-region pair, the
    # on-host mesh artifacts, and the exact `ssh -N -L` each cross-host pull would run (PEER_TUNNEL_PLAN
    # §6.2). `?refresh=1` first clears the cached verdicts so the next transfer re-probes (the DAG
    # "recalculate" action — a fresh verdict lands on the next transfer, since probing needs live workers).
    HTTP.register!(router, "GET", "/api/{id}/peer-plan", req -> _withnb(h, req, nb -> begin
        # The region set the DAG actually shows = declared footer ∪ cell-tagged (a cell can be tagged into a
        # region the footer never listed). Mirror `_regions_json` so the plan matches the zones on screen.
        names = unique(String[String(get(d, "name", "")) for d in _regions_json(nb)])
        filter!(!isempty, names)
        ref = get(HTTP.queryparams(HTTP.URI(req.target)), "refresh", "0") == "1"
        isempty(names) && return _json(Dict("regions" => String[], "routes" => [], "hosts" => [], "refreshed" => ref))
        data = try; ReportEngine.peer_plan_data(names; refresh = ref)
               catch e; Dict("regions" => names, "routes" => [], "hosts" => [],
                             "error" => first(sprint(showerror, e), 200)); end
        # LIVE transfers touching this notebook's regions (active first, then recent) — drives the DAG's
        # animated region edges. Off the gate; this reads the hub's orchestration view.
        rset = Set(names); now = time()
        data["transfers"] = [begin
            el = (v.finished > 0 ? v.finished : now) - v.started
            Dict("src" => v.src, "dst" => v.dst, "name" => v.name, "via" => v.via,
                 "done" => v.done, "total" => v.total, "active" => (v.finished == 0.0), "err" => v.err,
                 "mbps" => (el > 0 && v.done > 0) ? round(v.done / el / 1e6; digits = 1) : 0.0)
        end for v in ReportEngine.xfer_views() if (v.src in rset || v.dst in rset)]
        _json(data)
    end))
    # On-demand transfer PROBE (the DAG "recalculate" action): for every ordered cross-region pair, run a
    # throwaway measured transfer (random bytes, never memo-cached) so the route verdict + throughput are
    # measured NOW instead of waiting for a cell to drive one. Reuses the region kernels + the peer transport;
    # results also land in the peer-rate memory and the live `transfers` view. Returns per-pair kind/bytes/mbps.
    HTTP.register!(router, "POST", "/api/{id}/probe", req -> _withnb(h, req, nb -> begin
        names = unique(String[String(get(d, "name", "")) for d in _regions_json(nb)])
        filter!(!isempty, names)
        # Every ordered cross-region pair, counted up front so we can PUSH "i/n" progress over the notebook's
        # SSE channel (same `_broadcast` bus as `mesh-consent:`) as each probe runs — a probe is a real test
        # transfer that takes seconds, so a single blocking POST would otherwise show no step-by-step feedback.
        pairs = [(a, b) for a in names for b in names if a != b]
        n = length(pairs)
        prog(d) = _broadcast(nb, "probe-progress:" * JSON.json(d))
        results = Any[]
        for (i, (a, b)) in enumerate(pairs)
            prog(Dict("phase" => "run", "i" => i, "n" => n, "src" => a, "dst" => b))
            ka = try; _region_kernel!(nb, a); catch; nothing; end
            kb = try; _region_kernel!(nb, b); catch; nothing; end
            (ka === nothing || kb === nothing) && continue
            r = try; ReportEngine.probe_transfer!(ka, kb)
                catch e; (; kind = :error, bytes = 0, seconds = 0.0, mbps = 0.0, err = first(sprint(showerror, e), 160)); end
            String(r.kind) == "local" && continue          # same host with no wire — nothing to measure
            res = Dict("src" => a, "dst" => b, "kind" => String(r.kind), "bytes" => r.bytes,
                       "mbps" => round(r.mbps; digits = 1), "err" => hasproperty(r, :err) ? String(r.err) : "")
            push!(results, res)
            prog(merge(Dict("phase" => "done", "i" => i, "n" => n), res))
        end
        prog(Dict("phase" => "complete", "n" => n))
        _json(Dict("probed" => results))
    end))
    # Retained transfer TRACES for the summary dashboard: each recent region→region transfer with its
    # per-poll (t, cumulative-bytes) series → the frontend derives instantaneous throughput, timelines, the
    # peer-to-peer grid, and the distribution. Filtered to the notebook's regions; `now` anchors relative time.
    HTTP.register!(router, "GET", "/api/{id}/transfer-stats", req -> _withnb(h, req, nb -> begin
        names = unique(String[String(get(d, "name", "")) for d in _regions_json(nb)])
        filter!(!isempty, names); rset = Set(names)
        traces = [Dict("src" => t.src, "dst" => t.dst, "name" => t.name, "via" => t.via,
                       "started" => t.started, "finished" => t.finished, "total" => t.total, "err" => t.err,
                       "ts" => t.ts, "bs" => t.bs)
                  for t in ReportEngine.xfer_traces() if (t.src in rset || t.dst in rset)]
        _json(Dict("traces" => traces, "now" => time()))
    end))
    # Static export: a self-contained HTML document of the notebook. `?dl=1` downloads; `?source=0`
    # hides code; `?theme=light|dark`; `?code=normal|small|smaller|tiny|hidden` sizes/hides listings.
    # No scripts/server needed; KaTeX (CDN) typesets math, figures are embedded.
    HTTP.register!(router, "GET", "/api/{id}/export.html", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        _run = get(qp, "bundle", "0") == "1"   # embed the reproducible bundle + a "Run live" launcher
        mb = get(qp, "memo", "")               # precomputed-results budget (MB) for the embedded bundle
        budget = isempty(mb) ? typemax(Int) :
                 (v = tryparse(Float64, mb); v === nothing ? typemax(Int) : round(Int, v * 1024^2))
        pv = get(qp, "preview", "")            # interim-render budget (MB) for the embedded bundle's preview
        pbudget = isempty(pv) ? _PREVIEW_MAX_TOTAL :
                  (v = tryparse(Float64, pv); v === nothing ? _PREVIEW_MAX_TOTAL : round(Int, v * 1024^2))
        wq = get(qp, "width", "")                   # content column width: px, "full" (=100%), or unset ⇒ default
        pw = wq == "full" ? 0 : (v = tryparse(Int, wq); v === nothing ? 900 : v)
        html = export_html(nb; include_source = get(qp, "source", "1") != "0",
                           theme = get(qp, "theme", "dark"), charttheme = get(qp, "charttheme", ""),
                           override = get(qp, "override", "0") == "1", code = get(qp, "code", "normal"),
                           outputs = get(qp, "outputs", "all"), runnable = _run, embed_bundle = _run,
                           history = get(qp, "history", "0") == "1",   # source-only by default (public page)
                           memo_budget = budget, preview_budget = pbudget, width = pw)
        headers = Pair{String,String}["Content-Type" => "text/html; charset=utf-8"]
        if get(qp, "dl", "0") == "1"
            fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".html"
            push!(headers, "Content-Disposition" => "attachment; filename=\"$fn\"")
        end
        HTTP.Response(200, headers, html)
    end))
    # Secret GitHub gist of the HTML export (via the `gh` CLI). Same page options as export.html
    # (theme/charttheme/override/code/outputs/width/source); returns {ok,url,preview,error} as JSON.
    HTTP.register!(router, "POST", "/api/{id}/export.gist", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        wq = get(qp, "width", "")
        pw = wq == "full" ? 0 : (v = tryparse(Int, wq); v === nothing ? 900 : v)
        r = export_gist(nb; include_source = get(qp, "source", "1") != "0",
                        theme = get(qp, "theme", "dark"), charttheme = get(qp, "charttheme", ""),
                        override = get(qp, "override", "0") == "1", code = get(qp, "code", "normal"),
                        outputs = get(qp, "outputs", "all"), width = pw)
        _json(Dict{String,Any}("ok" => r.ok, "url" => r.url, "preview" => r.preview,
                               "raw" => r.raw, "curl" => r.curl, "error" => r.error))
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
                       charttheme = get(qp, "charttheme", ""),
                       override = get(qp, "override", "0") == "1",
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
                       charttheme = get(qp, "charttheme", ""),
                       override = get(qp, "override", "0") == "1",
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
        # `memo` = byte budget for embedded precomputed results (MB in the query, → bytes):
        # ""/absent = all memoizable results; "0" = none. Entries chosen by compute-saved-per-byte.
        mb = get(qp, "memo", "")
        budget = isempty(mb) ? typemax(Int) :
                 (v = tryparse(Float64, mb); v === nothing ? typemax(Int) : round(Int, v * 1024^2))
        # `preview` = byte budget for the embedded interim render (MB → bytes): ""/absent = the
        # default cap; "0" = omit the frozen preview entirely (smaller file, cells show un-run on open).
        pv = get(qp, "preview", "")
        pbudget = isempty(pv) ? _PREVIEW_MAX_TOTAL :
                  (v = tryparse(Float64, pv); v === nothing ? _PREVIEW_MAX_TOTAL : round(Int, v * 1024^2))
        jl = try
            export_standalone(nb; history = get(qp, "history", "1") != "0",   # full git history by default (deliberate share)
                              memo_budget = budget, preview_budget = pbudget)
        catch e
            return HTTP.Response(500, "Standalone export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".standalone.jl"
        HTTP.Response(200, ["Content-Type" => "text/x-julia; charset=utf-8",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], jl)
    end))
    # Precomputed-results catalog for the export dialog's size/quality slider: this notebook's
    # embeddable memo entries ranked by compute-saved-per-byte (densest first), with totals.
    # Snapshots current values into the store as a side effect (idempotent), so the numbers are exact.
    HTTP.register!(router, "GET", "/api/{id}/memo-catalog", req -> _withnb(h, req, nb -> begin
        cat = try
            memo_catalog(nb)
        catch e
            Dict{String,Any}("entries" => Any[], "total_bytes" => 0, "total_ms" => 0.0,
                             "error" => sprint(showerror, e))
        end
        _json(cat)
    end))
    # ── Files tab: browse + edit the notebook's own project source ─────────────
    # `assetbase` is the project root; the tree is `src/`, `notebooks/`, Project.toml, etc. A write
    # goes straight to disk — the worker's Revise watcher reloads it like any external edit (no rerun
    # here; the existing hot-reload notice + memo `_src_digest` invalidation do the rest).
    HTTP.register!(router, "GET", "/api/{id}/tree", req -> _withnb(h, req, nb -> begin
        root = _proj_root(nb)
        isempty(root) && return _json(Dict("root" => "", "detached" => true, "tree" => Any[]))
        _json(Dict("root" => root, "name" => basename(normpath(root)),
                   "detached" => false, "tree" => _proj_tree(root, root)))
    end))
    HTTP.register!(router, "GET", "/api/{id}/file", req -> _withnb(h, req, nb -> begin
        rel = String(get(HTTP.queryparams(HTTP.URI(req.target)), "path", ""))
        ap = _safe_proj_path(_proj_root(nb), rel)
        isempty(ap) && return HTTP.Response(400, "bad or out-of-project path")
        isfile(ap) || return HTTP.Response(404, "no such file")
        filesize(ap) > 4_000_000 && return HTTP.Response(413, "file too large to edit here")
        _json(Dict("path" => rel, "content" => read(ap, String), "bytes" => filesize(ap)))
    end))
    HTTP.register!(router, "POST", "/api/{id}/file", req -> _withnb(h, req, nb -> begin
        body = try; JSON.parse(String(req.body)); catch; Dict{String,Any}(); end
        rel = String(get(body, "path", "")); content = String(get(body, "content", ""))
        ap = _safe_proj_path(_proj_root(nb), rel)
        isempty(ap) && return HTTP.Response(400, "bad or out-of-project path")
        isfile(ap) || return HTTP.Response(404, "won't create new files here (v1 edits existing source only)")
        try
            write(ap, content)
        catch e
            return HTTP.Response(500, "write failed: " * first(sprint(showerror, e), 200))
        end
        # The write lands on disk; the worker's Revise hot-reload watcher picks it up (restaling the
        # affected cells) AND kicks a background `Pkg.precompile()` in the warm worker to refresh the
        # now-stale on-disk cache — see `_kick_bg_precompile!` in worker.jl (logs to the worker log).
        _json(Dict("ok" => true, "path" => rel, "bytes" => sizeof(content)))
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
    # Watchdog health: stall/runaway alerts the 5s supervisor sweep classified (also rides state meta).
    HTTP.register!(router, "GET", "/api/{id}/health", req -> _withnb(h, req, nb -> _json(_health_json(nb))))
    HTTP.register!(router, "POST", "/api/{id}/bind/{cid}", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        set_bind!(nb, HTTP.getparam(req, "cid"), get(body, "name", ""), get(body, "value", nothing))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/table-page", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        tid = String(get(b, "table_id", ""))
        res = lock(nb.lock) do                       # serialize vs eval (shared gate connection)
            # A region-produced table's provider lives on that region's kernel — route there.
            k = _side_kernel!(nb, _table_side(nb, tid))
            ReportEngine.table_page(k, nb.report, tid, b)
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
    # Restart the worker. Body {side:"<region>"} restarts JUST that region's worker (leaving the main
    # kernel + other regions up); no side / "" restarts the main kernel (and tears regions down).
    HTTP.register!(router, "POST", "/api/{id}/restart", req -> _withnb(h, req, nb -> begin
        side = String(get(_body(req), "side", ""))
        isempty(side) ? restart_kernel!(nb) : restart_region!(nb, side)
        _json(state_json(nb))
    end))
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
        (isempty(cell) || isempty(img)) && return _json(Dict("ok" => false))
        try; set_snapshot!(nb.id, cell, Vector{UInt8}(Base64.base64decode(img))); catch; return _json(Dict("ok" => false)); end
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
        _json(Dict("entries" => SlateHistory.entries(nb.path),   # the log is a compact delta — cheap to read whole
                   "current" => SlateHistory.latest_hash(nb.path)))))
    # Per-cell version timeline (newest first) for the editor's undo-through-history: the
    # distinct past SOURCES of one cell, each with its age + diff-label. Sources are pulled
    # from the snapshot objects (parsed once per snapshot, memoized across the list).
    HTTP.register!(router, "GET", "/api/{id}/cell-history/{cid}", req -> _withnb(h, req, nb -> begin
        cid = HTTP.getparam(req, "cid")
        reports = Dict{String,Any}()
        out = Dict{String,Any}[]
        for v in SlateHistory.cell_versions(nb.path, cid)
            hash = String(v["hash"])
            rep = get!(reports, hash) do
                src = SlateHistory.content(nb.path, hash)
                src === nothing ? nothing : (try; parse_report(src); catch; nothing; end)
            end
            rep === nothing && continue
            idx = findfirst(c -> c.id == cid, rep.cells)
            idx === nothing && continue
            push!(out, Dict("seq" => v["seq"], "ts" => v["ts"],
                            "label" => v["label"], "source" => rep.cells[idx].source))
        end
        _json(Dict("cell" => cid, "versions" => out))
    end))
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
const _WS_RE = r"^/api/([^/]+)/ws$"           # per-page WebSocket for JS→Julia calls (window.slateCall)
const _PUBLISH_RE = r"^/api/([^/]+)/publish-run\b"
const _SITE_PUBLISH_RE = r"^/api/([^/]+)/site-publish\b"
# Anchored to `?`/end so it matches the SSE endpoint `/api/publish/site-sync[?…]` but NOT its sibling
# `/api/publish/site-sync-plan` (a JSON route) — a bare `\b` also matched the `-plan` path, hijacking
# the plan request into the SSE stream handler (client then failed to JSON-parse `event: log…`).
const _SITE_SYNC_RE = r"^/api/publish/site-sync(?:\?|$)"

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
# `JSON.parse` yields library types (`JSON.Object`, lazy strings) that a worker whose env lacks JSON.jl
# can't `deserialize` over the gate → "malformed request". Rebuild the call args as plain Base types
# (Dict/Vector/scalars) so a call is env-INDEPENDENT — no worker needs JSON to receive one.
_plainify(x::AbstractDict) = Dict{String,Any}(String(k) => _plainify(v) for (k, v) in x)
_plainify(x::AbstractVector) = Any[_plainify(v) for v in x]
_plainify(x::AbstractString) = String(x)
_plainify(x) = x

# Invoke a cell-registered `slate_on` handler on the notebook's kernel and normalize the outcome to a
# JSON-able reply Dict (`ok`/`value` or `ok=false`/`error`). Never throws — a dead kernel / missing
# channel / throwing handler all come back as a clean `error` so the browser Promise rejects cleanly.
function _do_slate_call(nb::LiveNotebook, channel::AbstractString, args, call_id::AbstractString = "")
    args = _plainify(args)   # strip JSON.jl types so ANY worker env can deserialize the request payload
    # A `slate_on` handler lives in the namespace of the kernel its cell RAN ON — under a region that may
    # be a region worker, not the main one. Try the main kernel, then each active region kernel, and use
    # whichever actually has the channel registered: a "no handler here" moves on, a handler that RETURNS
    # or THROWS stops the search (its outcome is the answer).
    kernels = Any[nb.kernel]
    append!(kernels, lock(_REGION_LOCK) do
        Any[k for ((id, _side), k) in _REGION_KERNELS if id == nb.id]
    end)
    lasterr = "no slate_on handler registered for channel '$channel'"
    for k in kernels
        found, reply = _try_slate_call(nb, k, channel, args, call_id)
        found && return reply
        lasterr = get(reply, "error", lasterr)
    end
    return Dict{String,Any}("ok" => false, "error" => lasterr)
end

# Attempt the call on ONE kernel. Returns (found, reply): found=true if this kernel owns the channel
# (the handler returned a value or threw — either way, that's the answer); found=false only for
# "no handler here" or an infra hiccup, so the caller tries the next kernel.
function _try_slate_call(nb::LiveNotebook, k, channel::AbstractString, args, call_id::AbstractString = "")
    _nohandler(e) = occursin("no slate_on handler", e) || occursin("handlers unavailable", e)
    try
        if k isa ReportEngine.GateKernel
            r = ReportEngine._tool(k, "__slate_call",
                    Dict{String,Any}("channel" => String(channel), "args" => args, "call_id" => String(call_id)); timeout = 30.0)
            _gf(r, :ok, false) === true &&
                return (true, Dict{String,Any}("ok" => true, "value" => _gf(r, :value, nothing)))
            err = string(_gf(r, :error, "call failed"))
            return (!_nohandler(err), Dict{String,Any}("ok" => false, "error" => err))
        end
        # In-process kernel: invoke the handler directly in the report's namespace module. A 2-arg handler
        # gets a `progress` closure that pushes on the reserved `__slate_call_progress` emit channel (routed
        # to the caller's onProgress by call id) — the in-process twin of the worker's progress closure.
        m = ReportEngine.report_module(nb.report)
        hs = try; Base.invokelatest(getglobal, m, :__slate_handlers); catch; nothing; end
        (hs isa AbstractDict) || return (false, Dict{String,Any}("ok" => false, "error" => "call handlers unavailable"))
        f = get(hs, String(channel), nothing)
        f === nothing && return (false, Dict{String,Any}("ok" => false, "error" => "no slate_on handler registered for channel '$channel'"))
        progress = isempty(call_id) ? (p -> nothing) :
            (p -> ReportEngine._do_emit(nb.report.id, "__slate_call_progress", (id = String(call_id), data = p)))
        return (true, Dict{String,Any}("ok" => true,
            "value" => ReportEngine._invoke_slate_handler(f, ReportEngine._slate_args(args), progress)))
    catch e
        return (false, Dict{String,Any}("ok" => false, "error" => first(sprint(showerror, e), 300)))
    end
end

# ── Per-page WebSocket: JS→Julia CALLS + server→browser STREAM (slate_emit) ──────────────────────
# The whole reverse-direction channel. Calls ride it (`{id,channel,args}` → `{t:"reply",id,ok,value}`),
# AND `slate_emit` now pushes here (`{t:"emit",channel,data}`) instead of SSE — SSE coalesces under
# backpressure (correct for idempotent cell patches, but LOSSY for a stream where each frame matters:
# it silently dropped ~93% of a 1k burst). Each connection owns a bounded outbound queue drained by its
# own task, so a slow client never blocks the poller/reactivity; on overflow we drop + emit an explicit
# `{t:"dropped",n}` marker rather than silently coalescing. (SSE keeps the idempotent cell patches.)
mutable struct _WSConn
    out::Channel{String}
    dropped::Threads.Atomic{Int}
end
_wsconn(cap::Int) = _WSConn(Channel{String}(cap), Threads.Atomic{Int}(0))

const _WS_CONNS = Dict{String,Vector{_WSConn}}()   # nb id → live page sockets (slate_emit push targets)
const _WS_LOCK = ReentrantLock()
_ws_register!(nb::LiveNotebook, c::_WSConn) = lock(_WS_LOCK) do; push!(get!(_WS_CONNS, nb.id, _WSConn[]), c); end
_ws_unregister!(nb::LiveNotebook, c::_WSConn) = lock(_WS_LOCK) do
    v = get(_WS_CONNS, nb.id, nothing); v === nothing || filter!(!==(c), v)
end

# Enqueue one frame to a connection, NON-blocking. Full queue ⇒ drop + count; the next successful
# enqueue is preceded by a `{t:"dropped",n}` marker so the client knows it fell behind. Thread-safe:
# emits arrive on the poller task, replies on per-call tasks — `put!` is safe, the count is atomic.
function _ws_send!(c::_WSConn, msg::AbstractString)
    isopen(c.out) || return nothing
    if Base.n_avail(c.out) >= c.out.sz_max
        Threads.atomic_add!(c.dropped, 1); return nothing
    end
    d = Threads.atomic_xchg!(c.dropped, 0)
    d > 0 && (try; put!(c.out, "{\"t\":\"dropped\",\"n\":$d}"); catch; end)
    try; put!(c.out, String(msg)); catch; end
    return nothing
end

# Send a pre-built JSON frame to every live page socket of a notebook (no-op when none are connected).
function _ws_broadcast!(nb::LiveNotebook, frame::AbstractString)
    conns = lock(_WS_LOCK) do; v = get(_WS_CONNS, nb.id, nothing); v === nothing ? _WSConn[] : copy(v); end
    for c in conns; _ws_send!(c, frame); end
    return nothing
end

# slate_emit → push `{t:"emit",channel,data}` to every live page socket. `value` is a Julia value (the
# slate_emit unification); JSON-encoded once here on the hub.
function _ws_emit!(nb::LiveNotebook, channel, value)
    frame = try
        string("{\"t\":\"emit\",\"channel\":", JSON.json(String(channel)), ",\"data\":", JSON.json(value), "}")
    catch
        return nothing
    end
    _ws_broadcast!(nb, frame)
end

# Watchdog health → push over the WS (`{t:"health",data}`), replacing the browser's periodic
# GET /api/health poll (which showed as constant network-tab traffic). Sent on each watchdog scan and
# once per socket on connect. The GET endpoint stays for a fresh page / non-WS clients.
_ws_health!(nb::LiveNotebook) = (try
    _ws_broadcast!(nb, string("{\"t\":\"health\",\"data\":", JSON.json(_health_json(nb)), "}"))
catch; end; nothing)

# ── Worker telemetry + log → per-page WebSocket push ──────────────────────────────────────────────────
# The gate-stream poller (gate_kernel.jl) records each worker's 2s telemetry sample and every log record,
# then fires the sinks below (ReportEngine._TELEMETRY_SINK / _LOG_SINK, installed by `_install_worker_push!`).
# These map the worker's stable gate `conn.name` back to its notebook + side and PUSH a frame to that
# notebook's open pages — so the worker pills/popup update from "just what the server sends", no polling.

# conn_name → (LiveNotebook, side) for the live worker owning that gate connection: the MAIN kernel is
# side "", a region kernel its region name. Matches the SAME kernels `_worker_entry` enumerates. Returns
# nothing when no open notebook owns the conn (reaped worker / race) — the push is then a silent no-op.
# Takes the two locks separately (never nested) to avoid a lock-order hazard with `_REGION_LOCK`.
function _worker_conn_owner(h, conn_name::AbstractString)
    isempty(conn_name) && return nothing
    nbs = try; lock(h.lock) do; collect(values(h.notebooks)); end; catch; return nothing; end
    for nb in nbs
        k = nb.kernel
        if k isa ReportEngine.GateKernel && k.conn !== nothing && k.conn.name == conn_name
            return (nb, "")
        end
    end
    reg = lock(_REGION_LOCK) do
        [(id, side, k) for ((id, side), k) in _REGION_KERNELS]
    end
    for (id, side, k) in reg
        if k isa ReportEngine.GateKernel && k.conn !== nothing && k.conn.name == conn_name
            nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
            nb === nothing || return (nb, side)
        end
    end
    return nothing
end

# Telemetry sample → `{t:"telemetry",side,stats}`. `stats` is the SAME JSON STRING the roster pill parses
# (`_worker_entry` sets `d["stats"] = JSON.json(sample)`), so the browser reuses its `_wpStats`/`_wpPillStat`
# verbatim — hence the double-encode (JSON string embedded as a JSON string value).
function _telemetry_push!(h, conn_name::AbstractString, sample)
    owner = _worker_conn_owner(h, conn_name); owner === nothing && return nothing
    nb, side = owner
    frame = try
        string("{\"t\":\"telemetry\",\"side\":", JSON.json(String(side)),
               ",\"stats\":", JSON.json(JSON.json(sample)), "}")
    catch; return nothing; end
    _ws_broadcast!(nb, frame)
    return nothing
end

# Worker log line → `{t:"log",side,line}`. The browser appends it only if the popup for that side is open.
function _log_push!(h, conn_name::AbstractString, line::AbstractString)
    owner = _worker_conn_owner(h, conn_name); owner === nothing && return nothing
    nb, side = owner
    frame = try
        string("{\"t\":\"log\",\"side\":", JSON.json(String(side)), ",\"line\":", JSON.json(String(line)), "}")
    catch; return nothing; end
    _ws_broadcast!(nb, frame)
    return nothing
end

# Current worker/pill list → `{t:"workers",data:[...]}`. Pushed at a region spawn-START (so the pill
# appears immediately in a "starting" state, before the worker's gate is even up and any telemetry flows)
# and again on connect — the browser's renderWorkers() then draws/updates the pills without waiting for
# the next notebook state version-bump (which is why they used to pop in only after the first run).
function _workers_push!(nb::LiveNotebook)
    frame = try
        string("{\"t\":\"workers\",\"data\":", JSON.json(_workers_json(nb)), "}")
    catch; return nothing; end
    _ws_broadcast!(nb, frame)
    return nothing
end

# Install the telemetry + log push sinks (ReportEngine → hub → WS). Mirrors the bring-up sink: re-registered
# on every `_hub()` access so a Revise reload re-wires without a full restart. Closures capture the live hub.
function _install_worker_push!(h)
    try; ReportEngine._TELEMETRY_SINK[] = (cn, sample) -> _telemetry_push!(h, cn, sample); catch; end
    try; ReportEngine._LOG_SINK[]       = (cn, line)   -> _log_push!(h, cn, line);         catch; end
    return nothing
end

function _ws_calls(stream, nb::LiveNotebook)
    if !HTTP.WebSockets.isupgrade(stream.message)
        HTTP.setstatus(stream, 426); HTTP.startwrite(stream); return nothing
    end
    HTTP.WebSockets.upgrade(stream) do ws
        c = _wsconn(1024)
        _ws_register!(nb, c)
        writer = @async try                      # single writer per socket (a WS can't interleave concurrent sends)
            for msg in c.out; HTTP.WebSockets.send(ws, msg); end
        catch; end
        try; _ws_send!(c, string("{\"t\":\"health\",\"data\":", JSON.json(_health_json(nb)), "}")); catch; end   # initial health snapshot
        try
            for raw in ws
                req = try; JSON.parse(raw isa String ? raw : String(raw)); catch; nothing; end
                (req isa AbstractDict) || continue
                cid = get(req, "id", nothing)
                cid === nothing && continue      # no id ⇒ not a call (a one-way send is reserved for later)
                ch = string(get(req, "channel", "")); args = get(req, "args", nothing)
                @async begin
                    reply = _do_slate_call(nb, ch, args, string(cid)); reply["id"] = cid; reply["t"] = "reply"
                    payload = try
                        JSON.json(reply)
                    catch e    # non-JSON-serializable handler result → a clean error, not a client-side timeout
                        JSON.json(Dict{String,Any}("t" => "reply", "id" => cid, "ok" => false,
                            "error" => "result not JSON-serializable: " * first(sprint(showerror, e), 160)))
                    end
                    _ws_send!(c, payload)
                end
            end
        finally
            _ws_unregister!(nb, c)
            close(c.out)                         # ends the writer task
        end
    end
    return nothing
end

# A REMOTE provision streams raw `Pkg.instantiate()`/`Pkg.precompile()` output through here. Runs the
# SAME classifier the local worker uses, so the remote banner reads a structured "Precompiling k/N · Makie"
# headline instead of dumping resolver churn (`[hash] + Pkg v…`). Provisions are serialized in practice
# (one hydrating notebook at a time), so a single module-global tracker suffices; it resets on a terminal
# phase or when a fresh instantiate's `Updating` follows a precompile run.
const _REMOTE_PREP = Ref{Any}(nothing)   # (tracker, last-touch-time) | nothing
function _remote_prep_tracker(::AbstractString)
    prev = _REMOTE_PREP[]
    # A fresh run when: nothing yet; the previous run finished/errored (every provision path ends with an
    # `@@SLATE_PREP done` marker → phase "done"); or a long idle gap (an error-aborted provision leaves the
    # tracker mid-precompile — a later provision must not resume its counts). The gap is generous so a single
    # slow package (Makie can compile for minutes with no output) never false-resets mid-run.
    fresh = prev === nothing || prev[1].phase in ("done", "error") || (time() - prev[2] > 300)
    tr = fresh ? ReportEngine.PrepareTracker(time()) : prev[1]
    _REMOTE_PREP[] = (tr, time())
    return tr
end

# Push one remote bring-up line to every HYDRATING notebook's browser: the raw line as `bringup:` (the
# banner's collapsible detail log) AND, when it advances the classifier, a structured `prepare:` headline.
# Runs on the provisioner's thread, so it stays cheap and swallows errors — losing a line never disrupts a
# bring-up.
function _bringup_broadcast(h, line::AbstractString)
    s = strip(String(line)); isempty(s) && return nothing
    prepmsg = try
        tr = _remote_prep_tracker(s)
        (ReportEngine.prepare_feed!(tr, s) && ReportEngine.prepare_active(tr)) ?
            "prepare:" * ReportEngine.prepare_json(tr) : nothing
    catch; nothing; end
    # `@@SLATE_PREP …` control markers drive the structured banner ONLY — keep them out of the raw build log.
    raw = startswith(s, "@@SLATE_PREP") ? nothing : "bringup:" * first(s, 200)
    nbs = try; lock(h.lock) do; collect(values(h.notebooks)); end; catch; return nothing; end
    for nb in nbs
        get(nb.report.meta, "hydrating", false) === true || continue
        raw === nothing || (try; _broadcast(nb, raw); catch; end)
        prepmsg === nothing || (try; _broadcast(nb, prepmsg); catch; end)
    end
    return nothing
end

function start_hub(; host = "127.0.0.1", port = 8765)
    # Stamp the payload SHA the running hub code was loaded from — `_hub_src_stale()` compares the live
    # on-disk SHA to this to flag "Slate src changed since this server started; restart to apply".
    _HUB_START_SHA[] = try; ReportEngine._payload_sha(); catch; ""; end
    try; SlateHistory.migrate_once!(); catch e   # one-time: compact legacy history logs + compress objects
        @warn "KaimonSlate: history migration failed" exception = (e, catch_backtrace())
    end
    h = Hub(Dict{String,LiveNotebook}(), nothing, host, port, ReentrantLock())
    # Surface a remote worker's live bring-up output (streamed instantiate/precompile) in the browser
    # hydrating banner, not just remote.log — the provisioner narrates each line through this sink hook.
    try; ReportEngine._BRINGUP_SINK[] = line -> _bringup_broadcast(h, line); catch; end
    _install_worker_push!(h)   # worker telemetry + log → per-page WebSocket push (no browser polling)
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
        elseif (mw = match(_WS_RE, target)) !== nothing        # per-page WebSocket — JS→Julia calls
            nb = lock(h.lock) do; get(h.notebooks, mw.captures[1], nothing); end
            nb === nothing && (nb = _reopen_persisted!(h, mw.captures[1]))
            nb === nothing ? (HTTP.setstatus(stream, 404); HTTP.startwrite(stream)) : _ws_calls(stream, nb)
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
    _ensure_run_supervisor!(h)   # eval-level self-healing: reconcile orphaned RUNNING cells every 5s
    @info "Kaimon Slate hub" url = _hub_url(h)
    return h
end

"""
    open_notebook!(hub, path) -> id

Load the notebook at `path` into the hub (reusing the existing entry if already
open) and start its file watcher. Returns the hub id (its `/n/<id>` route).
"""
function open_notebook!(h::Hub, path::AbstractString; threads::AbstractString = "", runon::AbstractString = "",
                        autorun::Bool = true, inactive::Bool = false)
    file = abspath(path)
    id = lock(h.lock) do
        for nb in values(h.notebooks)
            abspath(nb.path) == file && return nb.id
        end
        id = _unique_id(h, file)
        nb = load_notebook(file; id = id, threads = threads, runon = runon, autorun = autorun, inactive = inactive)
        h.notebooks[id] = nb
        _start_watcher!(nb)
        return id
    end
    _persist_registry!(h)        # remember id→path so a restart can lazily re-open it
    nb = lock(h.lock) do; get(h.notebooks, id, nothing); end
    nb === nothing || _ensure_docid!(nb)     # silent lazy upgrade: stamp the stable `docid` if the file has none
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
        # Capture the final rendered state as the next reopen's interim preview, past the debounce.
        try; _save_preview!(nb; force = true); catch; end
        _close_listeners(nb)
        _close_agent!(nb)
        _unwire_callbacks!(nb)
        # Signal any in-flight runner to stop BEFORE tearing anything else down — its `Threads.@spawn`
        # task isn't otherwise interruptible, and a reopen of this same path reuses this exact id (see
        # `_RUNNER_CANCEL`'s docstring), so an orphaned runner would silently block the reopened
        # notebook from ever draining. Cheap even when no runner is active (most closes).
        if lock(_RUNNER_LOCK) do; get(_RUNNERS, id, false); end
            ReportEngine._rlog("slate: closing $(id) with its runner still draining — signalling it to stop")
            lock(_RUNNER_LOCK) do; _RUNNER_CANCEL[id] = true; end
        end
        try; shutdown!(nb.kernel); catch; end
        _teardown_region!(nb)                 # detach — a remote region idles warm like the main kernel
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
            _teardown_region!(nb)
        end
        empty!(h.notebooks)
    end
    h.server === nothing || close(h.server)
    return nothing
end

