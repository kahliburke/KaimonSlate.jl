"""
    KaimonSlate

A warm-session, **reactive** Julia notebook served as a live browser UI — packaged
as a Kaimon extension.

Cells evaluate in isolated modules; edits and `@bind` widgets drive *pruned*
reactive recompute; Makie/MIME figures and interactive ECharts render inline; the
source round-trips to a plain `.jl` file so the agent and the browser share one
source of truth.

It runs **out-of-process on HTTP 2.0**, independent of Kaimon core's HTTP version —
the two talk over the Gate (ZMQ), never a shared HTTP stack.

Standalone use:

```julia
using KaimonSlate
serve_notebook("notebook.jl"; port = 8765)   # blocks
```

As a Kaimon extension, `create_tools` exposes `slate.open` / `slate.list` /
`slate.close` to the agent, and Kaimon manages the subprocess lifecycle.
"""
module KaimonSlate

import JSON

include("engine.jl")    # module ReportEngine (+ eval / deps / bind / echarts)
include("render.jl")    # module ReportRender
include("slate_home.jl") # module SlateHome — KaimonSlate's own XDG config/data/cache homes
include("ledger.jl")    # module PublishLedger — the publish ledger + LedgerStore backends
include("server.jl")    # module NotebookServer (uses ..ReportEngine, ..ReportRender, ..SlateHome)

using .ReportEngine
using .ReportRender
using .NotebookServer: serve_notebook, start_server, LiveNotebook,
                      Hub, start_hub, open_notebook!, close_notebook!, stop_hub, set_run_on!,
                      find_live, notebook_digest,
                      agent_add_cell!, agent_edit_cell!, agent_run!, agent_delete_cell!, agent_delete_cells!, agent_rename_cell!, agent_scratch_eval!, agent_scratch_eval_bg!, scratch_check, agent_surface_controls!,
                      acquire_floor!, release_floor!, floor_status,
                      index_docs!, search_docs, cell_image, cell_image_fresh, cell_inspect, diag_report,
                      request_live_eval, export_standalone, export_pdf, expand

export serve_notebook, LiveNotebook, expand, register_extension

# ── Auto-registration as a Kaimon extension ───────────────────────────────────
# The intended path is zero-setup: install KaimonSlate, and if Kaimon is present on
# this machine it registers itself in Kaimon's extension list — then the user just
# launches Kaimon and opens the browser. No hand-editing of config, no manual
# `serve_notebook`. Detection is simply "Kaimon's config dir exists".

# Kaimon's config dir. Mirrors Kaimon's own `kaimon_config_dir()` — respects `XDG_CONFIG_HOME` so a
# notebook launched with an isolated config (e.g. a headless "run this live" instance) registers into
# THAT config, not the user's real `~/.config/kaimon`. A function (not a const) so it re-reads ENV.
_kaimon_dir() = joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "kaimon")

# Is `path` a KaimonSlate package checkout? Used to dedup extension entries by IDENTITY rather than
# by exact path, so a second checkout / git worktree / packaged copy doesn't add a duplicate hub.
function _is_slate_project(path::AbstractString)
    isempty(path) && return false
    f = joinpath(path, "Project.toml")
    isfile(f) || return false
    return occursin(r"(?m)^\s*name\s*=\s*\"KaimonSlate\"", read(f, String))
end

"""
    register_extension(; auto_start=true, enabled=true, force=false, project_path=pkgdir(KaimonSlate)) -> Bool

Add this package to Kaimon's extension registry (`~/.config/kaimon/extensions.json`) so Kaimon
loads the `slate.*` tools automatically — no hand-wiring. **Idempotent**: returns `false`
(nothing written) if Kaimon isn't installed here or the entry already exists, and `true` when an
entry is added. Registration is consented: the `slate` app prompts on first run (see app.jl), and
loads only self-register when spawned AS the extension (see `__init__`). Call it explicitly to
(re)register a specific `project_path` or to flip `auto_start`.
"""
function register_extension(; auto_start::Bool = true, enabled::Bool = true, force::Bool = false,
                            project_path = pkgdir(@__MODULE__))
    kdir = _kaimon_dir()
    isdir(kdir) || return false                              # Kaimon not installed / no config dir here
    project_path === nothing && return false                 # can't locate ourselves (unusual)
    path = abspath(String(project_path))
    file = joinpath(kdir, "extensions.json")
    data = isfile(file) ? (try; JSON.parsefile(file); catch; Dict{String,Any}(); end) : Dict{String,Any}()
    exts = get(data, "extensions", nothing)
    exts isa AbstractVector || (exts = Any[])
    # Dedup by IDENTITY, not exact path: if a KaimonSlate is already registered (from any checkout,
    # git worktree, or the packaged install), don't add another — multiple entries spawn multiple
    # hubs that fight over ports. Just working in a worktree must not pollute the config. `force=true`
    # re-points to a specific checkout (drops other KaimonSlate entries first).
    slate_idx = findall(e -> e isa AbstractDict && _is_slate_project(String(get(e, "project_path", ""))), exts)
    if !isempty(slate_idx)
        force || return false                                # already have one — leave it be
        deleteat!(exts, slate_idx)                           # force: replace whatever was there
    end
    push!(exts, Dict("project_path" => path, "enabled" => enabled, "auto_start" => auto_start))
    data["extensions"] = exts
    write(file, JSON.json(data, 2))
    @info "Registered KaimonSlate as a Kaimon extension — launch Kaimon and open the browser." file
    return true
end

# Auto-register on load ONLY when this process was spawned BY Kaimon as the extension
# (KAIMON_EXTENSION set — a no-op then, since being spawned proves the entry exists). Everything
# else goes through the `slate` app's consent prompt (app.jl): a bare `using KaimonSlate` never
# touches Kaimon's config, and a REMOVED extension entry stays removed (the app re-asks; nothing
# silently re-registers — even after a previous Yes). Best-effort and idempotent — never breaks
# loading; opt out with `ENV["KAIMONSLATE_NO_AUTOREGISTER"] = "1"`.
function __init__()
    get(ENV, "KAIMONSLATE_NO_AUTOREGISTER", "0") in ("1", "true") && return nothing
    haskey(ENV, "KAIMON_EXTENSION") || return nothing
    try
        register_extension()
    catch e
        @debug "KaimonSlate auto-registration skipped" exception = (e, catch_backtrace())
    end
    return nothing
end

# Is a KaimonSlate checkout (any identity, see `_is_slate_project`) already in Kaimon's extension
# registry? Drives the app's first-run onboarding ("already wired in → don't ask").
function _slate_registered()
    file = joinpath(_kaimon_dir(), "extensions.json")
    isfile(file) || return false
    data = try; JSON.parsefile(file); catch; return false; end
    exts = get(data, "extensions", nothing)
    exts isa AbstractVector || return false
    return any(e -> e isa AbstractDict && _is_slate_project(String(get(e, "project_path", ""))), exts)
end

# ── Single-server hub ─────────────────────────────────────────────────────────
# The extension serves *all* notebooks from one HTTP 2.0 server on one port,
# routing per-notebook by id (`/n/<id>`, `/api/<id>/…`); `/` is a switcher index.
# The hub runs in the extension subprocess alongside the Gate loop.

# Port is configurable via the KAIMONSLATE_PORT env var (default 8765) so a
# config UI / launcher can pin it; the hub auto-starts at extension init.
const _PORT = something(tryparse(Int, get(ENV, "KAIMONSLATE_PORT", "8765")), 8765)
const _HUB = Ref{Union{Hub,Nothing}}(nothing)
const _LOCK = ReentrantLock()

_base() = "http://127.0.0.1:$_PORT"

# The running hub (started lazily on first open).
function _hub()
    lock(_LOCK) do
        _HUB[] === nothing && (_HUB[] = start_hub(; port = _PORT))
        # (Re)register the remote bring-up → browser-banner sink HERE too, not only in `start_hub`: this
        # runs on every hub access, so a Revise reload of the server picks it up WITHOUT a full restart
        # (start_hub only runs once, at boot). The closure reads `_HUB[]` at call time → always the live hub.
        try; ReportEngine._BRINGUP_SINK[] = line -> NotebookServer._bringup_broadcast(_HUB[], line); catch; end
        try; NotebookServer._install_worker_push!(_HUB[]); catch; end   # re-wire telemetry/log WS push on reload
        return _HUB[]::Hub
    end
end

# Cross-platform: PIDs of processes whose command line contains `needle`. Unix uses
# `pgrep -f` (which excludes its own PID); Windows queries Win32_Process via PowerShell,
# restricted to `julia` processes so the query's own PowerShell host — whose argv also
# contains `needle` — isn't matched. Never throws: a missing tool or no match ⇒ `Int[]`.
function _pids_matching(needle::AbstractString)::Vector{Int}
    pids = Int[]
    try
        toks = if Sys.iswindows()
            q = "Get-CimInstance Win32_Process -Filter \"Name LIKE 'julia%' AND CommandLine LIKE '%$needle%'\" | " *
                "ForEach-Object { \$_.ProcessId }"
            split(readchomp(`powershell -NoProfile -NonInteractive -Command $q`))
        else
            split(readchomp(`pgrep -f $needle`))
        end
        for t in toks
            p = tryparse(Int, strip(t))
            p === nothing || push!(pids, p)
        end
    catch  # tool absent / no matches — nothing to report
    end
    return pids
end

# Best-effort hard-kill by raw PID, cross-platform (`taskkill /F` on Windows, `kill -9`
# elsewhere). Never throws — a missing process or tool is ignored.
function _kill_pid(pid::Integer)
    try
        if Sys.iswindows()
            run(pipeline(`taskkill /F /PID $pid`; stdout = devnull, stderr = devnull); wait = false)
        else
            run(pipeline(`kill -9 $pid`; stderr = devnull); wait = false)
        end
    catch
    end
    return nothing
end

# Restart-reaping backstop: kill leftover worker subprocesses from a previous
# extension instance that exited non-gracefully (crash / hard kill), since that
# path skips `on_shutdown`. Each worker's boot script carries the `SlateWorker.start`
# marker in its argv, so a command-line match finds exactly ours. Called once at init,
# BEFORE this instance spawns any worker, so it never targets our own children.
function _reap_orphan_workers!()
    for pid in _pids_matching("SlateWorker.start")
        _kill_pid(pid)
    end
    return nothing
end

# ── Persistent extension settings (edited via the Kaimon TUI panel) ───────────
# A small JSON file alongside the extension registry. Currently holds the worker Julia-thread spec —
# more compute threads enable true multi-core CPU parallelism for independent cells. Read at init into
# ReportEngine.WORKER_THREADS[] (which `_spawn_worker!` consumes), and editable live from the panel.
_slate_config_path() = SlateHome.config_file()   # our OWN XDG config home (off Kaimon's dir; see SlateHome)

_slate_config() = (f = _slate_config_path(); isfile(f) ?
    (try; JSON.parsefile(f); catch; Dict{String,Any}(); end) : Dict{String,Any}())

"Current worker Julia-thread spec (\"<compute>,<interactive>\"); \"\" means the adaptive default (min(cores,8),2)."
worker_threads()::String = String(get(_slate_config(), "worker_threads", ""))

"""
    set_worker_threads!(spec; respawn=true) -> String

Persist the worker Julia-thread spec (e.g. `"4,1"` or `"auto"`), apply it to future worker spawns,
and — by default — respawn every running notebook's worker so it takes effect immediately. Returns
the stored spec. Called by the Kaimon TUI panel via `ctx.eval`.
"""
function set_worker_threads!(spec::AbstractString; respawn::Bool = true)
    s = strip(String(spec))
    ReportEngine.WORKER_THREADS[] = s
    cfg = _slate_config(); cfg["worker_threads"] = s
    try
        mkpath(SlateHome.config_home()); write(_slate_config_path(), JSON.json(cfg, 2))
    catch e
        @warn "slate: could not persist worker-threads setting" exception = e
    end
    if respawn && _HUB[] !== nothing
        nbs = lock(_HUB[].lock) do; collect(values(_HUB[].notebooks)); end
        for nb in nbs
            try; NotebookServer.restart_kernel!(nb); catch e; @warn "slate: worker respawn failed" notebook = nb.id exception = e; end
        end
    end
    @info "slate: worker threads set" spec = s respawned = respawn
    return s
end

"Configured durable memo-store cap in GB; 0.0 means unset (worker env / adaptive default applies)."
memo_cap_gb()::Float64 = something(tryparse(Float64, string(get(_slate_config(), "memo_cap_gb", ""))), 0.0)

"""
    set_memo_cap_gb!(gb; respawn=true) -> Float64

Persist the durable memo-store ceiling (GB) and apply it to future worker spawns; `respawn=true`
recycles running workers so it takes effect immediately. `0` clears the override back to the
adaptive default (a quarter of free disk, clamped 2–20 GB). Called by the Kaimon TUI panel.
"""
function set_memo_cap_gb!(gb::Real; respawn::Bool = true)
    v = max(0.0, Float64(gb))
    ReportEngine.MEMO_CAP_GB[] = v
    cfg = _slate_config(); v > 0 ? (cfg["memo_cap_gb"] = v) : delete!(cfg, "memo_cap_gb")
    try
        mkpath(SlateHome.config_home()); write(_slate_config_path(), JSON.json(cfg, 2))
    catch e
        @warn "slate: could not persist memo-cap setting" exception = e
    end
    if respawn && _HUB[] !== nothing
        nbs = lock(_HUB[].lock) do; collect(values(_HUB[].notebooks)); end
        for nb in nbs
            try; NotebookServer.restart_kernel!(nb); catch e; @warn "slate: worker respawn failed" notebook = nb.id exception = e; end
        end
    end
    @info "slate: memo cap set" gb = v respawned = respawn
    return v
end

"Configured data-channel chunk size in MB; 0.0 = unset (env / 8 MiB default applies)."
blob_chunk_mb()::Float64 = something(tryparse(Float64, string(get(_slate_config(), "blob_chunk_mb", ""))), 0.0)

"""
    set_blob_chunk_mb!(mb) -> Float64

Persist the memo data-channel chunk size (MB per round-trip) and apply it live — no worker
respawn needed (the transfer runs hub-side). Smaller chunks keep a slow uplink responsive;
bigger ones amortize the RTT. `0` clears back to the env / 8 MiB default. Settings panel knob.
"""
function set_blob_chunk_mb!(mb::Real)
    v = max(0.0, Float64(mb))
    ReportEngine.BLOB_CHUNK_MB[] = v
    cfg = _slate_config(); v > 0 ? (cfg["blob_chunk_mb"] = v) : delete!(cfg, "blob_chunk_mb")
    try; mkpath(SlateHome.config_home()); write(_slate_config_path(), JSON.json(cfg, 2)); catch e; @warn "slate: could not persist chunk-size setting" exception = e; end
    return v
end

"Configured boot-carry per-entry ceiling in seconds; 0.0 = unset (env / 30s default applies)."
carry_max_s()::Float64 = something(tryparse(Float64, string(get(_slate_config(), "carry_max_s", ""))), 0.0)

"Configured transfer-preview threshold (s); -1 = unset (env / 15s default), 0 = previews off."
xfer_confirm_s()::Float64 = something(tryparse(Float64, string(get(_slate_config(), "xfer_confirm_s", ""))), -1.0)

"Persist the transfer-preview threshold and apply it live. -1 clears to default; 0 disables."
function set_xfer_confirm_s!(s::Real)
    v = Float64(s) < 0 ? -1.0 : Float64(s)
    ReportEngine.XFER_CONFIRM_S[] = v
    cfg = _slate_config(); v >= 0 ? (cfg["xfer_confirm_s"] = v) : delete!(cfg, "xfer_confirm_s")
    try; mkpath(SlateHome.config_home()); write(_slate_config_path(), JSON.json(cfg, 2)); catch e; @warn "slate: could not persist preview-threshold setting" exception = e; end
    return v
end

"""
    set_carry_max_s!(s) -> Float64

Persist the boot-window memo-carry ceiling (max seconds any single entry may spend transferring
before the cost gate skips it — the cell recomputes remotely instead) and apply it live. `0`
clears back to the env / 30s default. Settings panel knob.
"""
function set_carry_max_s!(s::Real)
    v = max(0.0, Float64(s))
    ReportEngine.CARRY_MAX_S[] = v
    cfg = _slate_config(); v > 0 ? (cfg["carry_max_s"] = v) : delete!(cfg, "carry_max_s")
    try; mkpath(SlateHome.config_home()); write(_slate_config_path(), JSON.json(cfg, 2)); catch e; @warn "slate: could not persist carry-ceiling setting" exception = e; end
    return v
end

"The user's onboarding answer for extension registration: \"yes\" | \"dismissed\" | \"\" (not asked)."
ext_prompt_choice()::String = String(get(_slate_config(), "ext_prompt", ""))

"Persist the onboarding answer (see `ext_prompt_choice`). Returns the stored choice."
function set_ext_prompt_choice!(choice::AbstractString)
    cfg = _slate_config(); cfg["ext_prompt"] = String(choice)
    try
        mkpath(SlateHome.config_home()); write(_slate_config_path(), JSON.json(cfg, 2))
    catch e
        @warn "slate: could not persist onboarding choice" exception = e
    end
    return String(choice)
end

"Whether inter-cell parallel execution is on by default for notebooks (persisted; default true)."
parallel_default()::Bool = get(_slate_config(), "parallel", true) === true

"""
    set_parallel_default!(on::Bool) -> Bool

Persist whether new/re-opened notebooks run cells in parallel by default, and apply it live. The
per-notebook Settings toggle still overrides for a specific notebook.
"""
function set_parallel_default!(on::Bool)
    NotebookServer.PARALLEL_DEFAULT[] = on
    cfg = _slate_config(); cfg["parallel"] = on
    try; mkpath(SlateHome.config_home()); write(_slate_config_path(), JSON.json(cfg, 2)); catch e; @warn "slate: could not persist parallel default" exception = e; end
    return on
end

"The machine's GLOBAL default run-location for new notebooks (\"host[,transport]\"; \"\" = local)."
run_location_default()::String = String(get(_slate_config(), "run_location", ""))

"""
    set_run_location_default!(spec) -> String

Persist the global default run-location (where new notebooks run) to slate.json and apply it live.
Per-notebook and per-session overrides still win. Returns the stored spec.
"""
set_run_location_default!(spec::AbstractString) = NotebookServer.set_runon_default!(spec)

# Load persisted settings into the engine BEFORE any worker spawns (called at init).
function _load_slate_config!()
    s = worker_threads()
    isempty(s) || (ReportEngine.WORKER_THREADS[] = s)
    ReportEngine.MEMO_CAP_GB[] = memo_cap_gb()
    ReportEngine.BLOB_CHUNK_MB[] = blob_chunk_mb()
    ReportEngine.CARRY_MAX_S[] = carry_max_s()
    ReportEngine.XFER_CONFIRM_S[] = xfer_confirm_s()
    NotebookServer.PARALLEL_DEFAULT[] = parallel_default()
    NotebookServer.RUNON_DEFAULT[] = run_location_default()
    # Persist hook for the browser Settings panel's transfer knobs (route in server_complete.jl —
    # NotebookServer has no JSON-config ownership, same pattern as _RUNON_PERSIST).
    NotebookServer._XFER_PERSIST[] = function (chunk_mb, carry_s, confirm_s)
        set_blob_chunk_mb!(chunk_mb); set_carry_max_s!(carry_s); set_xfer_confirm_s!(confirm_s)
        return nothing
    end
    # Install the persist hook so set_runon_default! (from the browser route / gate tool) writes slate.json.
    NotebookServer._RUNON_PERSIST[] = function (spec)
        cfg = _slate_config(); cfg["run_location"] = String(spec)
        mkpath(SlateHome.config_home()); write(_slate_config_path(), JSON.json(cfg, 2))
        return nothing
    end
    return nothing
end

# ── Extension entrypoints ─────────────────────────────────────────────────────

"""
    create_tools(GateTool) -> Vector{GateTool}

Tools exposed to the agent under the `slate.*` namespace. `GateTool` is passed in
so the extension needs no Kaimon dependency — handlers are plain typed functions,
reflected into MCP JSON Schema by Kaimon.
"""
function create_tools(GateTool::Type)
    # The invoking agent's identity (its MCP session id), or "" for a sessionless/self call.
    # Keys the build-floor implicitly, so the model never threads a token (and can't self-lock).
    _caller() = (c = parentmodule(GateTool).current_caller(); c === nothing ? "" : String(c))

    # The owning Kaimon agent's id for this call ("" for an external MCP client), via the
    # X-Kaimon-Agent-Id correlation Kaimon sets on a spawned agent's session. Companion to
    # `_caller()`: `_caller()` is the raw session id; this is which agent (if any) owns it.
    _agent_id() = (a = parentmodule(GateTool).current_agent_id(); a === nothing ? "" : String(a))

    # Run a mutating tool, then surface it in the chat panel IF an outside driver made the
    # call (crew calls already stream in over the agent bus). Returns the tool's result so a
    # wrapper can `return _surfaced(...)`. A ⛔-prefixed result (e.g. a rejected floor commit)
    # renders as a failed row.
    _surfaced(nb, tool, args, res) =
        (NotebookServer.note_external_tool!(nb, _agent_id(), tool, args, res;
            ok = !startswith(lstrip(res), "⛔")); res)

    """
        open(path::String; threads::String="") -> String

    Open a reactive notebook for the `.jl` file at `path` and start its live
    browser server (creating the file if it does not exist). Returns the URL.
    Opening the same file again returns the existing server.

    `threads` ("<compute>,<interactive>", e.g. "8,1") overrides the worker Julia
    thread count for THIS notebook only — useful for a CPU-heavy notebook. Empty →
    the global setting (Extensions panel / slate.json) / adaptive default.
    """
    function nb_open(path::String; threads::String = "")::String
        path = expanduser(path)
        isfile(path) || write(path, "#%% md id=intro\n# New Notebook\n")
        h = _hub()
        id = open_notebook!(h, path; threads = threads)
        return "Serving $(abspath(path)) at $(_base())/n/$id"
    end

    """
        list() -> String

    List the notebooks currently being served and their URLs (index: the base URL).
    """
    function nb_list()::String
        h = _HUB[]
        (h === nothing || isempty(h.notebooks)) && return "No notebooks open."
        lines = lock(h.lock) do
            ["$(_base())/n/$(nb.id)  ←  $(abspath(nb.path))" for nb in values(h.notebooks)]
        end
        return join(["Index: $(_base())"; lines], "\n")
    end

    """
        close(path::String) -> String

    Stop serving the notebook at `path` (the hub stays up for the others).
    """
    function nb_close(path::String)::String
        h = _HUB[]
        h === nothing && return "Not open: $(abspath(path))"
        file = abspath(expanduser(path))
        id = lock(h.lock) do
            for nb in values(h.notebooks)
                abspath(nb.path) == file && return nb.id
            end
            return nothing
        end
        id === nothing && return "Not open: $file"
        close_notebook!(h, id)
        return "Closed $file"
    end

    # ── Cell-level operations (the incremental-build loop) ────────────────────
    # These let the agent operate the LIVE notebook one cell at a time — add a
    # cell, run it, read the result, decide the next — instead of composing the
    # whole thing blind and dumping one big file Edit. `notebook` is the id (e.g.
    # "para") or the .jl path. All args are flat scalars (gate-reflection friendly).
    function _nb(notebook::String)
        h = _HUB[]
        h === nothing && return (nothing, "No notebooks are open.")
        nb = find_live(h, notebook)
        nb === nothing && return (nothing, "No open notebook '$notebook' (use slate.list).")
        return (nb, "")
    end

    """
        run_on(notebook::String, host::String, scope::String) -> String

    Choose WHERE this notebook's worker runs — per notebook. `host=""` runs it LOCALLY.
    `host="ssh_host"` — or the full spec `"ssh_host[,transport[,port,stream_port]]"` (transport =
    tunnel|direct, default tunnel; the optional ports PIN the worker's remote ports, needed for
    `direct` through a firewall where specific ports are opened) — PROVISIONS
    + spawns the worker on that SSH host and connects over an SSH tunnel or CURVE; the notebook then
    behaves exactly as if local (reactivity, hot-reload, streaming all transparent). The host must be an
    SSH target you've already set up (a `Host` in ~/.ssh/config with key auth). Different notebooks can
    target different hosts/envs independently. Switches a live notebook and re-runs.

    `scope` picks which layer this sets: `"session"` (default) = this session only, not saved;
    `"notebook"` = durable, saved in the .jl so it reopens there; `"clear"` = drop both overrides and
    fall back to the global default / local. Use `check_remote` first to validate + prime a new host.
    """
    # `scope` MUST be a keyword arg: the gate silently strips optional POSITIONALS
    # (see _reflect_tool/_dispatch_tool_call notes) — as a positional this defaulted to
    # "session" no matter what the caller passed. Same fix on check_remote/publish_history.
    function run_on(notebook::String, host::String; scope::String = "session")::String
        nb, err = _nb(notebook); nb === nothing && return err
        sc = Symbol(strip(scope)); sc in (:session, :notebook, :clear) || (sc = :session)
        set_run_on!(nb, host; scope = sc)
        sc === :clear && return "✅ $(basename(nb.path)) → run-location cleared (follows global default / local)."
        isempty(strip(host)) && return "✅ $(basename(nb.path)) → LOCAL worker ($(sc))."
        return "✅ $(basename(nb.path)) → provisioning + spawning on '$host' ($(sc)); watch `slate.diag` or the worker log for progress."
    end

    """
        sync_memo(notebook::String) -> String

    Push this notebook's LOCAL durable-cache entries (manifests + content-addressed blobs) to its
    remote worker over the blob data channel (gate port + 2) — so the remote RESTORES cached
    results instead of recomputing them ("your session follows you"). Dedup-aware: blobs the
    remote already has don't move. Runs automatically in the boot window on every remote
    (re)attach; this tool is the MID-SESSION push. Both transports: `direct` dials the CURVE-
    encrypted data socket; `tunnel` rides a dedicated ssh forward (its own ssh process, so a
    big shipment never queues ahead of cell results). Arrow/raw-codec blobs land mmap-ready
    and duckdb/pyarrow-readable.
    """
    function sync_memo(notebook::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        k = nb.kernel
        (k isa ReportEngine.GateKernel && k.target isa ReportEngine.RemoteTarget) ||
            return "Notebook isn't on a remote worker — nothing to sync."
        k.port == 0 && return "Remote worker not up yet — run a cell first."
        r = ReportEngine.push_notebook_memo!(k, nb.report)
        return "✅ memo sync → $(k.target.ssh_host):$(k.port + 2) — $r"
    end

    """
        check_remote(host::String, transport::String) -> String

    Test + prime an SSH host for remote notebooks: a full reported dry-run — ssh reachability, Julia
    presence (+version), env provisioning, KaimonGate load, CURVE key (for `direct`), then a real
    spawn → connect → round-trip eval → clean teardown. `transport` = "tunnel" (default) | "direct".
    Returns a step-by-step checklist. Slow on a cold host (first-time provisioning). Run this before
    `run_on` to catch setup problems early; it also primes the host so the first real run is fast.
    """
    function check_remote(host::String; transport::String = "tunnel")::String
        h = strip(host); isempty(h) && return "Give an ssh host (a `Host` in ~/.ssh/config)."
        tr = Symbol(strip(transport)); tr in (:tunnel, :direct) || (tr = :tunnel)
        r = ReportEngine.preflight_remote(h; transport = tr)
        io = IOBuffer()
        println(io, (r["ok"] ? "✅" : "❌"), " preflight '$h' ($(r["transport"])) — ", r["ok"] ? "ALL OK" : "FAILED")
        for s in r["steps"]
            mark = s["status"] == "ok" ? "✓" : s["status"] == "skip" ? "–" : "✗"
            println(io, "  $mark $(s["name"])  ($(s["ms"])ms)", isempty(s["detail"]) ? "" : "\n      $(s["detail"])")
        end
        return String(take!(io))
    end

    """
        remote_workers(host::String) -> String

    List the Slate workers on `host`: which notebook each serves, whether it's still running, its last
    computation time, and whether it looks abandoned — so you can decide what to clean up. Reap a
    specific one with `reap_worker`. Never kills anything.
    """
    function remote_workers(host::String)::String
        h = strip(host); isempty(h) && return "Give an ssh host."
        ws = ReportEngine.list_remote_workers(h)
        isempty(ws) && return "No Slate workers found on '$h' (or host unreachable)."
        io = IOBuffer(); println(io, "Workers on '$h':")
        for w in ws
            mf = w["manifest"]
            reg = ReportEngine._manifest_get(mf, "region")
            nbk = ReportEngine._manifest_get(mf, "notebook"); nbk = isempty(nbk) ? (isempty(reg) ? "?" : "warm·$reg") : nbk
            spawned = ReportEngine._manifest_get(mf, "spawned")
            la = w["lastActivity"]; age = la == 0 ? "never" : string(round(Int, (time() - la) / 60), "m ago")
            # lifecycle sidecar: attached (a hub is using it) / idle (detached, warm, adoptable)
            st = get(w, "state", "")
            badge = !w["alive"] ? "⚪ stopped" :
                    st == "idle" ? (isempty(reg) ? "🟡 idle (warm)" : "🔵 warm·$reg (adoptable)") :
                    st == "attached" ? "🟢 attached" : "🟢 running"
            println(io, "  • port $(w["port"])  $badge  notebook=$(nbk)  last activity: $age", isempty(spawned) ? "" : "  (spawned $spawned)")
            # latest telemetry sample (2s sampler → .stats sidecar); numbers are unquoted JSON
            stj = get(w, "stats", "")
            if !isempty(stj)
                g(key) = (m = match(Regex("\"" * key * "\":(-?[0-9.]+)"), stj); m === nothing ? nothing : m.captures[1])
                mb(v) = string(round(parse(Float64, v) / 2^20; digits = 1), "MB")
                hb(v) = (x = parse(Float64, v); x >= 2^30 ? string(round(x / 2^30; digits = 1), "GB") : mb(string(x)))
                cpu = g("cpu"); rss = g("rss"); memo = g("memo_bytes"); ev = g("evals")
                parts = String[]
                (cpu !== nothing && cpu != "-1.0") && push!(parts, "cpu $(cpu)%")
                rss === nothing || push!(parts, "rss $(mb(rss))")
                memo === nothing || push!(parts, "memo $(mb(memo))")
                ev === nothing || push!(parts, "$(ev) running")
                # System-wide (the whole HOST, not just this worker) — added for remote regions so the
                # box's overall load/memory is visible next to the process figures.
                scpu = g("sys_cpu"); load1 = g("load1"); smt = g("sys_mem_total"); smf = g("sys_mem_free")
                (scpu !== nothing && scpu != "-1.0") && push!(parts, "host-cpu $(scpu)%")
                (load1 !== nothing && load1 != "-1.0") && push!(parts, "load $(load1)")
                (smt !== nothing && smf !== nothing && smt != "0") &&
                    push!(parts, "host-mem $(hb(string(parse(Float64, smt) - parse(Float64, smf))))/$(hb(smt))")
                isempty(parts) || println(io, "      stats: ", join(parts, " · "))
            end
        end
        println(io, "\nReap one with reap_worker(host, port).")
        return String(take!(io))
    end

    """
        reap_worker(host::String, port::Int) -> String

    Explicitly kill the worker on `host:port` and remove its files. Manual only — nothing is auto-reaped,
    so a worker holding useful results is safe until you choose to remove it. Use `remote_workers` first.
    """
    function reap_worker(host::String, port::Int)::String
        h = strip(host); isempty(h) && return "Give an ssh host."
        try; NotebookServer._drop_kernels_for_worker!(_HUB[], h, port); catch; end   # wake any eval bound to this worker before it dies
        ReportEngine.reap_remote_worker(h, port)
        return "✅ reaped worker-$port on '$h' (process killed, files removed)."
    end

    """
        region(name::String; host="", transport="tunnel", base_port=0, preload="", data_root="", cache_root="", warm=0, threads="") -> String

    Define (or update) a named region — a global compute target: a `host` reached over `transport`
    (`tunnel`|`direct`), an optional `preload` (a LOCAL project dir replicated on the host so its
    packages load warm), a `data_root` (a REMOTE absolute path pinned as the workers' `datadir()`/`@sfile`),
    and `warm` (how many workers to keep booted and ready to adopt — 0 = cold spin on demand). Many
    regions may point at the same host with different config. Full-record upsert; reconciles toward
    `warm` in the background. Notebooks reference a region by NAME via `region_on` + `region=<name>`
    cell tags. `base_port` pins the port range for a `:direct` region (worker *i* → base_port+3i..+2).
    `cache_root` (a REMOTE absolute path) pins the workers' `KAIMONSLATE_CACHE_HOME` — a SEPARATE
    content-addressed store per region, so co-located region workers don't share `~/.cache/kaimonslate/memo`
    (they otherwise dedup a cross-region blob to 0 bytes instead of moving it over the peer channel).
    """
    function region(name::String; host::String = "", transport::String = "tunnel", base_port::Int = 0,
                    preload::String = "", data_root::String = "", cache_root::String = "", warm::Int = 0,
                    threads::String = "", sysimage::Bool = false)::String
        nm = strip(name); isempty(nm) && return "Give a region name."
        tr = Symbol(strip(transport)); tr in (:tunnel, :direct) || (tr = :tunnel)
        pl = strip(preload); (isempty(pl) || isdir(expanduser(pl))) || return "preload project dir not found: $pl"
        r = ReportEngine.region_set!(nm; host = String(strip(host)), transport = tr, base_port = base_port,
                                     preload = isempty(pl) ? "" : abspath(expanduser(pl)),
                                     data_root = String(strip(data_root)), cache_root = String(strip(cache_root)),
                                     warm = max(0, warm), threads = String(strip(threads)), sysimage = sysimage)
        r.warm > 0 && Threads.@spawn try; ReportEngine.region_reconcile!(r.name); catch; end
        return "✅ region '$(r.name)' → $(isempty(r.host) ? "(no host)" : r.host) ($(r.transport))" *
               (r.warm > 0 ? ", warm=$(r.warm) (reconciling)" : "") *
               (r.sysimage ? ", sysimage=on" : "") *
               (isempty(r.data_root) ? "" : ", data_root=$(r.data_root)") *
               (isempty(r.cache_root) ? "" : ", cache_root=$(r.cache_root)")
    end

    """
        region_on(notebook, regions) -> String

    Choose which named regions this notebook uses — a comma-separated list of names from the global
    registry (define them with `region`). Cells tagged `region=<name>` then run on that region's
    worker; boundary values cross automatically as content-addressed blobs (a DataFrame crosses as
    Arrow IPC; unchanged values dedup to nothing), so a huge frame produced AND consumed inside one
    region never moves. Mutations auto-follow their data. Durable (notebook footer). `regions=""`
    clears. Pure `using` cells run on every side; keep `@bind` cells on the main kernel.
    """
    function region_on(notebook::String, regions::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        names = NotebookServer.set_notebook_regions!(nb, regions)   # teardown old region kernels + persist the footer
        isempty(names) && return "✅ regions cleared — all cells run on the main kernel again."
        unknown = [nm for nm in names if ReportEngine.region_get(nm) === nothing]
        n = count(c -> !isempty(NotebookServer._cell_region(c)), nb.report.cells)
        return "✅ $(basename(nb.path)) uses region(s): " * join(names, ", ") *
               (isempty(unknown) ? "" : "  ⚠ not defined in the registry: " * join(unknown, ", ")) *
               ". Tag cells with `region=<name>` ($n tagged now)."
    end

    """
        memo_trace(notebook; cell="") -> String

    What the durable memo cache DID on each cell's latest eval — the direct probe for "why did
    this cell (not) restore?". Per cell: action (restored / stored / recomputed / unkeyed), the
    full cache key with its src- and manifest-digest components (compare across hosts to spot a
    key drift), the per-binding blobs (name/codec/bytes/sha) read or written, and the exact miss
    reason on a recompute (no manifest / blob missing / decode failed / below threshold / …).
    `cell=""` returns every recorded cell. Reads the LIVE worker — run a cell first.
    """
    function memo_trace(notebook::String; cell::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        k = nb.kernel
        k isa ReportEngine.GateKernel || return "In-process kernel — no durable memo layer to trace."
        t = try
            ReportEngine.memo_trace(k, strip(cell))
        catch e
            return "memo_trace failed: $(first(sprint(showerror, e), 200))"
        end
        t === nothing && return "Worker not connected — run a cell first."
        fmt(d) = join(sort!(["  $k2: $(v2 isa AbstractVector ? join((string(x) for x in v2), "; ") : v2)"
                             for (k2, v2) in d]), "\n")
        if !isempty(strip(cell))
            return "memo trace — cell '$cell':\n" * fmt(t)
        end
        isempty(t) && return "No memoized evals recorded yet this worker session."
        io = IOBuffer()
        for cid in sort!(collect(keys(t)))
            println(io, "• $cid:\n", fmt(t[cid]))
        end
        return String(take!(io))
    end

    """
        regions() -> String

    The compute registry at a glance, no ssh: every configured region (name, host, transport, warm
    count, preload env, data root, and the last reconcile outcome) and every parked wire (a live
    connection kept across a notebook close for instant reattach). For the LIVE per-host roster —
    which workers actually run, their state and telemetry — use `remote_workers(host)`; for one
    notebook's placement use `whereis(notebook)`.
    """
    function regions()::String
        rs = ReportEngine.regions()
        parked = ReportEngine.parked_wires()
        isempty(rs) && isempty(parked) &&
            return "No regions configured and no parked wires. Define one with region(name; host, warm, …)."
        io = IOBuffer()
        if !isempty(rs)
            println(io, "Regions (desired state; live roster → remote_workers(host)):")
            for r in rs
                ports = (r.transport === :direct && r.base_port > 0 && r.warm > 0) ?
                        "  ports=$(r.base_port)–$(r.base_port + 3r.warm - 1)" : ""
                println(io, "  • $(r.name)  → $(isempty(r.host) ? "(no host)" : r.host)  warm=$(r.warm)  ",
                        "transport=$(r.transport)$ports  preload=",
                        isempty(r.preload) ? "(none)" : r.preload,
                        isempty(r.data_root) ? "" : "  data_root=$(r.data_root)")
                st = ReportEngine.region_status(r.name)
                st === nothing || println(io, "      last: ", st.ok ? "ok" : "FAILED", " — ", st.msg)
            end
        end
        if !isempty(parked)
            println(io, "Parked wires (live conns kept across close — reattach is ~0 network):")
            for p in parked
                println(io, "  • $(p.label) → $(p.host):$(p.port)  (idle $(p.idle_s)s)")
            end
        end
        return String(take!(io))
    end

    """
        whereis(notebook) -> String

    Where this notebook's cells execute RIGHT NOW: local worker (pid/port) or remote host —
    with transport, ports (main/stream/data), connection state, and for a remote worker its
    lifecycle state, pool provenance (adopted from a warm pool?), and latest telemetry
    (cpu/rss/memo). The placement queries: `pools()` for the hub view, `remote_workers(host)`
    for a host's full roster.
    """
    function whereis(notebook::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        k = nb.kernel
        k isa ReportEngine.GateKernel || return "'$notebook' runs IN-PROCESS (no worker — standalone/fallback kernel $(typeof(k)))."
        io = IOBuffer()
        t = k.target
        if t isa ReportEngine.RemoteTarget
            println(io, "'$notebook' runs REMOTELY on '$(t.ssh_host)' (transport=$(t.transport))")
            println(io, "  ports: main $(k.port) · stream $(k.stream_port) · data $(k.port + 2)  (remote env: $(t.project))")
            println(io, "  connection: ", k.conn === nothing ? "not connected (connects on next run)" :
                        "live" * (k.tunnel === nothing ? " (direct CURVE)" : " (ssh tunnel)"))
            # one ssh probe for the worker's own view: lifecycle state, pool provenance, telemetry
            w = nothing
            try
                for x in ReportEngine.list_remote_workers(t.ssh_host)
                    x["port"] == k.port && (w = x; break)
                end
            catch
            end
            if w !== nothing
                mf = w["manifest"]
                prov = ReportEngine._manifest_get(mf, "adopted") == "1" ? "adopted from the warm pool" :
                       ReportEngine._manifest_get(mf, "pool") == "1" ? "warm-pool member (unadopted)" : "spawned for this notebook"
                println(io, "  worker: ", w["alive"] === true ? "alive" : "NOT RUNNING", " · state=$(get(w, "state", "?")) · $prov")
                stj = get(w, "stats", "")
                isempty(stj) || println(io, "  stats: ", stj)
            end
        elseif k.remote
            println(io, "'$notebook' is ATTACHED to a pre-running worker at 127.0.0.1:$(k.port) (stream $(k.stream_port)) — not managed by this hub.")
        else
            alive = k.proc !== nothing && (try; Base.process_running(k.proc); catch; false; end)
            println(io, "'$notebook' runs LOCALLY: worker port $(k.port) (stream $(k.stream_port)), ",
                    alive ? "pid $(getpid(k.proc))" : "no live process (spawns on next run)")
            println(io, "  env: $(k.project)")
        end
        return String(take!(io))
    end

    """
        read(notebook::String; cells="", delta_since="") -> String

    Your view of the live notebook. `notebook` is its id or .jl path. Three modes:
    - default: a compact OUTLINE — one line per cell (id, kind, state, the names it defines, a
      one-line result / md heading). Token-cheap; use it to map a large notebook, then drill in.
    - `cells="id1,id2"`: the FULL source + output of just those cells.
    - `delta_since="<token>"`: only the cells added/edited/removed since that token.
    Every read ends with a STATE TOKEN ("state=…") — pass it back as `delta_since` to catch up.
    """
    function read_cells(notebook::String; cells::String = "", delta_since::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        return notebook_digest(nb; cells = cells, delta_since = delta_since)
    end

    """
        api() -> String

    The Kaimon Slate notebook API reference: the Slate-specific helpers injected into every cell —
    `echart` (custom ECharts DSL), `@bind` widgets, `animate`/`playhead`, `reactive`/`@onclick`/
    `@onchange` for live updates, `slate_table`, `slate_progress`, and cell tags. READ THIS before
    writing cells that plot or add interactivity — these names are NOT in package docs, and a
    `search_docs` for "chart"/"series" returns CairoMakie, which will lead you astray. Call with no
    `topic` for the full reference, or a topic ("animate", "widgets", "@bind") to drill into one area.
    These helpers are also indexed for `search_docs` under module "Slate".
    """
    api(topic::String = "")::String = NotebookServer.slate_api_reference(topic)   # SSOT (also feeds the prompt)

    """
        add_cell(notebook, source, after, kind) -> String

    Append a cell containing `source`, RUN it, and return its result (value/output,
    or the error to fix). `after` = the id to insert after ("" = end of notebook).
    `kind` = "code" or "md". `id` = an optional explicit cell id (a meaningful label like
    "ground_state"); must be UNIQUE — errors if already in use — and is folded to header-safe
    characters (letters/digits/underscore). Omit it to auto-generate. `tags` = optional cell tags
    (comma/space-separated), both behaviour tags (`hidecode`, `collapsed`, `trace`, `nocache`, …)
    and free-form metadata. Add ONE cell at a time and read its result before the next — do not
    compose the whole notebook up front.

    Cells run in a REACTIVE notebook with Slate helpers injected (charts via `echart`, widgets
    via `@bind`, live updates via `reactive`/`@onclick`, tables via `slate_table`) — call
    `slate.api` for the reference before plotting or adding interactivity; their names are not in
    package docs.
    """
    function add_cell(notebook::String, source::String; after::String = "", kind::String = "code", id::String = "", tags::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        res = agent_add_cell!(nb, source; after = after, kind = kind, id = id, tags = tags, caller = _caller())
        return _surfaced(nb, "add_cell",
            Dict{String,Any}("source" => source, "after" => after, "kind" => kind, "id" => id, "tags" => tags), res)
    end

    """
        rename_cell(notebook, cell, newid) -> String

    Rename cell `cell`'s id (its label) to `newid`. Ids must be UNIQUE (errors if `newid` is
    already in use) and are folded to header-safe characters (letters/digits/underscore).
    Dependencies are preserved. Use to give cells meaningful ids (e.g. "ground_state", "viz_conv").
    """
    function rename_cell(notebook::String, cell::String, newid::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        res = agent_rename_cell!(nb, cell, newid; caller = _caller())
        return _surfaced(nb, "rename_cell", Dict{String,Any}("cell" => cell, "newid" => newid), res)
    end

    """
        edit_cell(notebook, cell, source, tags) -> String

    Replace cell `cell`'s source, run it, and return its result. Use to fix a cell
    that errored, or to revise one in place. `tags` (optional, comma/space-separated) REPLACES the
    cell's tags — behaviour tags (`hidecode`, `collapsed`, `trace`, `nocache`, …) and free-form
    metadata; omit it to leave the existing tags unchanged.
    """
    function edit_cell(notebook::String, cell::String, source::String; tags::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        res = agent_edit_cell!(nb, cell, source; tags = tags, caller = _caller())
        return _surfaced(nb, "edit_cell",
            Dict{String,Any}("cell" => cell, "source" => source, "tags" => tags), res)
    end

    """
        run(notebook, cell, token, expected_version) -> String

    Run cell `cell` and return its result; `cell` = "" recomputes all stale cells.
    """
    function run_cell(notebook::String, cell::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        res = agent_run!(nb, cell; caller = _caller())
        return _surfaced(nb, "run", Dict{String,Any}("cell" => cell), res)
    end

    """
        delete_cell(notebook, cell) -> String

    Delete a cell from the notebook. `cell` is a cell id — or SEVERAL ids (comma- or
    space-separated) to delete many at once in a single step, so you needn't call this once per
    cell. Ids that don't exist are reported, and the rest still delete.
    """
    function delete_cell(notebook::String, cell::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        ids = String.(split(strip(cell), r"[\s,]+"; keepempty = false))   # ids are [A-Za-z0-9_] → safe to split
        isempty(ids) && return "(no cell id given)"
        if length(ids) == 1
            res = agent_delete_cell!(nb, ids[1]; caller = _caller())
            return _surfaced(nb, "delete_cell", Dict{String,Any}("cell" => ids[1]), res)
        end
        res = agent_delete_cells!(nb, ids; caller = _caller())
        return _surfaced(nb, "delete_cell", Dict{String,Any}("cells" => join(ids, ", ")), res)
    end

    """
        surface(notebook, cell, controls) -> String

    Surface `@bind` controls onto `cell`'s control strip — the presentation layer that renders the
    live widgets WITH a plotting/output cell instead of back at their `@bind` definition, so a reader
    adjusts the knobs right next to the figure they drive. Presentation only (no re-eval).

    Two authoring patterns for interactive cells:
      • EMBED — declare `@bind x Slider(…)` in the SAME cell that reads `x`; the widget renders there
        automatically (no surface call needed). Best when the control is local to one plotting cell.
      • SURFACE — declare the `@bind`s once (e.g. a hidden `hidecode` setup cell), then surface those
        variables onto the figure cell(s) that use them. Best when several cells share controls, or to
        keep the knobs beside the figure.

    `controls` uses the layout grammar: `a,b,c` = a row of single controls; `[a,b],c` = a stacked
    column `[a,b]` then a column `c`; `""` clears the strip. Names must be `@bind` variables defined
    somewhere in the notebook (a typo is rejected with the list of available controls).
    """
    function surface_controls(notebook::String, cell::String, controls::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        res = agent_surface_controls!(nb, cell, controls; caller = _caller())
        return _surfaced(nb, "surface", Dict{String,Any}("cell" => cell, "controls" => controls), res)
    end

    # ── Multi-agent write safety (MULTIAGENT.md §3) ───────────────────────────
    # Only needed when SEVERAL agents drive one notebook. A solo agent ignores all of
    # this — your edits already carry your session id implicitly, so they just work.

    """
        acquire_floor(notebook) -> String

    Claim the notebook's BUILD-FLOOR before a run of edits, so no other agent can
    commit underneath you ("one voice at a time"). No token to manage — every edit you
    make is recognized as yours automatically; just `release_floor` when done. The lease
    auto-expires after a few minutes idle. If another agent holds it, you get told who.
    """
    function acquire_floor(notebook::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        ok, why = acquire_floor!(nb, _caller())
        ok || return "⛔ build-floor $why. Try again shortly, or coordinate via the team."
        return "🔓 build-floor acquired — you hold it; other agents are locked out until slate.release_floor (auto-expires after $(Int(NotebookServer.FLOOR_TTL))s idle). Your edits carry your session automatically."
    end

    """
        release_floor(notebook) -> String

    Release the build-floor you hold so other agents can commit.
    """
    function release_floor(notebook::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return release_floor!(nb, _caller()) ? "✅ build-floor released." : "(you don't hold the build-floor — nothing to release)"
    end

    """
        index_docs(notebook, modules) -> String

    Index the documentation of `using`'d packages/modules (comma- or space-separated
    names) into semantic search so `search_docs` can find them. The modules must be
    loaded in the notebook first (a cell with `using Foo`).
    """
    function index_docs(notebook::String, modules::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        mods = String[strip(m) for m in split(modules, r"[,\s]+") if !isempty(strip(m))]
        isempty(mods) && return "Name the packages/modules to index (comma-separated); they must be `using`'d in the notebook."
        recs = ReportEngine.harvest_docs(nb.kernel, nb.report, mods)
        n = index_docs!(recs)
        n == 0 || NotebookServer.ensure_docs_fts!()   # light up lexical search + module filters for these
        return n == 0 ?
            "Indexed nothing — are the modules loaded (run `using …`) and the docs service (Ollama/Qdrant) up?" :
            "Indexed $n documented symbols from $(join(mods, ", ")). Search them with slate.search_docs."
    end

    """
        search_docs(notebook, query) -> String

    Fuzzy SEMANTIC search of indexed docs ("a function that sorts in place") — discover
    Julia/package API by meaning instead of reading source (you have no file access).
    Build the index first with `index_docs`.
    """
    function search_docs_tool(notebook::String, query::String)::String
        nb, _ = _nb(notebook)   # scope to this notebook's packages when resolvable; unfiltered otherwise
        mods = nb === nothing ? String[] : NotebookServer._inscope_modules(nb)
        res = search_docs(query; modules = mods)
        isempty(res) && return "No matches — build the index first with slate.index_docs, or rephrase."
        io = IOBuffer()
        for r in res
            println(io, "● $(r["module"]).$(r["name"])  (", round(Float64(get(r, "score", 0.0)); digits = 3), ")")
            snip = join(first(split(rstrip(string(r["doc"])), "\n"), 4), "\n")
            isempty(strip(snip)) || println(io, snip)
            println(io)
        end
        return String(take!(io))
    end

    """
        view(notebook, cell) -> image

    SEE a cell's rendered figure — returns the cell's PNG as an image you can look at
    (e.g. a CairoMakie plot), so you can inspect/verify/fix a visualization. Use this
    after running a plotting cell. ECharts/tables are interactive (not raster) — read
    those with `read`; text output also comes back via `read`.
    """
    function view_cell(notebook::String, cell::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        findfirst(c -> c.id == cell, nb.report.cells) === nothing &&
            return "No cell '$cell' in '$notebook' (use slate.read to list cells)."
        png = cell_image_fresh(nb, cell)   # CairoMakie/ECharts raster, or a fresh on-demand capture (md/table/value)
        png === nothing && return "Cell '$cell' has no figure to view yet — run a plotting cell (CairoMakie or an ECharts chart); text/data → use slate.read."
        isdefined(Main, :Kaimon) || return "Image view needs the Kaimon host (unavailable in standalone mode)."
        return getfield(Main, :Kaimon).KaimonGate.image_result(png; text = "Cell '$cell' — rendered figure")
    end

    """
        inspect(notebook, cell) -> String

    Everything about one cell, for inspecting while you build: its state (kind/state/deps/
    reads/writes/duration/flags), source, the canonical result, and its edit history. Use it
    after add_cell/edit_cell/run to decide the next step. (Rendered figure → slate.view;
    whole notebook → slate.read.)
    """
    function inspect_cell(notebook::String, cell::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return cell_inspect(nb, cell)
    end

    """
        diag(notebook) -> String

    Browser diagnostics for an OPEN notebook tab: console errors, failed resource loads
    (e.g. 404s), and unhandled promise rejections captured by the live page. Push-based —
    reflects the most recent tab session, so open the notebook in a browser and reload to
    refresh. Use after a front-end change to verify the console is clean (no headless browser
    needed). Reports "✓ clean" when nothing was captured.
    """
    function notebook_diag(notebook::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return diag_report(nb)
    end

    """
        eval_js(notebook, code) -> String

    Run `code` as JavaScript IN THE OPEN BROWSER TAB and return its result — the general way to
    drive or inspect the live notebook UI without a headless browser. Runs in the page's global
    scope, so page globals are reachable: invoke actions (`renderCharts(c)`, open a dialog, click a
    handler), read live state (`nbState`, a chart's resolved option `charts[id][0].getOption()`,
    DOM/computed styles), or trigger a reactive flow. The last expression is the return value; a
    returned Promise is awaited (so `await`-style snippets work). The value comes back JSON-encoded
    (functions / DOM nodes / cycles are collapsed, size-capped). Needs an OPEN tab — returns a notice
    if none answers in time. NOTE: this CANNOT capture a browser download (e.g. the PDF blob from
    `exportPdf()`); to inspect generated artifacts use the server-side tool (`slate.export_pdf`).
    """
    """
        eval(notebook, source; ephemeral="0", memo_key="", memo_threshold="0") -> String

    Run `source` as Julia in the notebook's LIVE kernel and return its captured output — a
    throwaway diagnostic scratchpad that does NOT create a cell or touch the `.jl`. Use it for
    one-off checks against the notebook's state (inspect a variable, a quick parameter scan, a
    sanity plot you save to a file with `Read`) WITHOUT littering the notebook with diagnostic
    cells. Persistent work still goes through `add_cell`/`edit_cell` — this is for diagnostics.

    It shares the notebook's kernel namespace: a bare `x = …` LEAKS (handy for setting up
    diagnostic state across calls), while wrapping in `let … end` — or passing `ephemeral="1"`,
    which wraps your code in a child scope — keeps bindings local (a pure read-only poke). Runs
    ON the notebook's eval queue (serialised with cell runs), so it never races a parallel batch.

    LONG EVALS DON'T TIME OUT: if the eval outruns a ~30s grace window it's promoted to a background
    job (like the gate `ex`) and the call returns a job id immediately — the eval keeps computing on
    the worker; poll for its result with `check_eval(notebook, job)`. So use `eval` freely for slow
    computations; you'll just get a job id to poll instead of blocking.
    """
    function scratch_eval(notebook::String, source::String; ephemeral::String = "0",
                          memo_key::String = "", memo_threshold::String = "0")::String
        nb, err = _nb(notebook); nb === nothing && return err
        r = agent_scratch_eval_bg!(nb, source;
            ephemeral = lowercase(ephemeral) in ("1", "true", "yes", "on"),
            memo_key = memo_key, memo_threshold = something(tryparse(Float64, memo_threshold), 0.0))
        return _surfaced(nb, "eval", Dict{String,Any}("source" => source, "ephemeral" => ephemeral), r.text)
    end
    """
        check_eval(notebook, job) -> String

    Poll a background scratch-eval job — the id `eval` hands back when a slow eval outran its ~30s
    grace window. Returns the eval's captured result once it finishes (and forgets the job), else a
    still-running note to poll again. Mirrors the gate `check_eval` for `ex`. The job id is global;
    `notebook` just routes/validates the caller.
    """
    function check_scratch_eval(notebook::String, job::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return scratch_check(job)
    end

    function eval_js(notebook::String, code::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        res = request_live_eval(nb, code)
        res === nothing && return "No open browser tab answered. Open/reload the notebook in a browser, then retry — eval_js runs in the live page."
        res isa AbstractDict || return string(res)
        get(res, "ok", false) === true && return String(get(res, "result", "null"))
        return "JS error: " * String(get(res, "error", "(unknown)"))
    end

    """
        export_pdf(notebook; theme="light", params="0", source="1", style="article",
                   columns="1", code="normal", body="", path="") -> String

    Render the notebook to a publication-quality PDF (the same server-side Typst pipeline as
    the browser's "Export PDF") and WRITE it to a file, so you can open that file with `Read`
    to verify the result — layout, figures, math, and whether interactive chrome or `@bind`
    parameter strips leaked in. This is how you check the PDF without a browser. Options mirror
    the export dialog: `theme ∈ ("light","dark")`; `params="1"` shows the frozen `@bind`
    parameter strip (hidden by default); `source="0"` drops code listings; `style ∈
    ("article","report")`; `columns ∈ ("1","2")`; `code ∈ ("normal","small","smaller","tiny",
    "hidden")`; `body ∈ ("","large","normal","compact","small")`. `path` overrides the output
    file (default: a temp path). Returns the written path — pass it to `Read` to see the pages.

    Set `layout="slides"` to render a 16:9 (or `slideratio=4:3`) presentation DECK — one slide
    per page, segmented by markdown headings + `slide`/`notes` cell tags (see the live "Present"
    mode). On a deck, code is hidden by default (set `source="1"`/`code` to show it) and
    `notes="1"` appends a speaker-notes section.
    """
    function export_pdf_tool(notebook::String; theme::String = "light", params::String = "0",
                             source::String = "1", style::String = "article", columns::String = "1",
                             code::String = "normal", body::String = "", path::String = "",
                             layout::String = "article", notes::String = "0")::String
        nb, err = _nb(notebook); nb === nothing && return err
        # Deck defaults: code hidden unless the caller explicitly opts in.
        slides = layout == "slides"
        slide_source = slides ? (source == "1") : (source != "0")
        pdf = try
            export_pdf(nb; include_source = slide_source, style = style,
                       columns = something(tryparse(Int, columns), 1), theme = theme,
                       code = code, body = body, include_params = params == "1",
                       layout = layout, notes = notes == "1",
                       level = get(nb.report.meta, "slidelevel", 2))
        catch e
            return "PDF export failed: " * sprint(showerror, e)
        end
        out = isempty(path) ? joinpath(tempdir(), "slate-export",
                  replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".pdf") : String(path)
        try
            mkpath(dirname(out)); write(out, pdf)
        catch e
            return "PDF rendered ($(length(pdf)) bytes) but writing to $out failed: " * sprint(showerror, e)
        end
        return "Wrote $(length(pdf)) bytes → $out\n(open it with Read to view the pages)"
    end

    """
        pkg(notebook; op="list", name="") -> String

    View or manage THIS NOTEBOOK's own package dependencies — the packages it adds on top of its
    parent project, kept in the notebook's forked env and recorded in the `.jl` `Slate.env` footer.
    Use THIS, not `Pkg.add` or editing a `Project.toml`, to give a notebook a dependency:

    - `op="list"` (default): the notebook's own added packages, plus the deps inherited from the
      parent project (read-only).
    - `op="add", name="VideoIO"`: install it into the notebook's env, re-run the code cells so a
      `using VideoIO` lights up, and record it in the footer so the notebook stays reproducible.
      Add SEVERAL at once — `name="VideoIO, ColorTypes, ImageMorphology"` (whitespace/comma
      separated) — to resolve + precompile them together and re-run the notebook just once.
      Each add-spec can be a registry name (`Foo` or `Foo@1.2.3` for a pinned version), a **git URL**
      (`https://github.com/u/Y.jl`, optionally `…#rev` where rev is a tag/release, branch, or commit
      SHA → `Pkg.add(url=…, rev=…)`), or a **local path** (`~/dev/MyPkg`, `/abs/path`, `./rel`) which is
      `develop`ed (mutable, hot-reloadable). Registry + git specs stay reproducible and travel to a
      remote worker via the notebook's Manifest; a develop'd local checkout is rsync'd to the remote.
    - `op="rm", name="VideoIO"`: remove it (also accepts several).

    Adding may precompile (can take a while). The parent project's deps are never touched.
    """
    function pkg(notebook::String; op::String = "list", name::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        if op == "list"
            e = NotebookServer._notebook_adds(nb)
            _prov(p) = get(p, "source", "registry") == "path" ? "  [dev: $(get(p, "origin", ""))]" :
                       get(p, "source", "registry") == "git" ? "  [git: $(get(p, "origin", ""))]" : ""
            adds = isempty(e.adds) ? "  (none yet)" :
                   join(["  $(get(p, "name", "")) $(get(p, "version", ""))$(_prov(p))" for p in e.adds], "\n")
            parent = isempty(e.parent) ? "" :
                     "\nInherited from parent ($(basename(e.parentpath))) — read-only:\n  " *
                     join([string(get(p, "name", "")) for p in e.parent], ", ")
            head = e.detached ? "Notebook packages (detached — this env is everything):" :
                                "Notebook packages (its own adds):"
            return "$head\n$adds$parent"
        end
        (op in ("add", "rm")) || return "bad op '$op' — use op=list|add|rm."
        isempty(strip(name)) && return "op=$op needs name=<package>."
        res = NotebookServer.notebook_pkg_op!(nb, op, name)
        get(res, "ok", false) === true ?
            "✅ $(op == "add" ? "added" : "removed") $name — notebook env updated & Slate.env footer synced." :
            "❌ $op $name failed: $(get(res, "message", "?"))"
    end

    """
        publish(notebook; targets="") -> String

    Publish THIS notebook's document to its configured publish TARGETS — re-pushable live
    destinations: GitHub Pages, S3/Cloudflare R2, rsync, … — recording each result in the publish
    ledger (what/when/where). `targets` is a comma-separated list of target names as configured in
    the Publishing manager (`slate.publish_targets`); empty ⇒ the targets already assigned to this
    document. Publishing only ever touches OUTPUT (a `gh-pages`-style branch / bucket), never a
    source repo. ARCHIVES (Zenodo DOIs) are a different verb — permanent and immutable, never part
    of a site push; mint one deliberately with `slate.archive`.
    """
    function publish_tool(notebook::String; targets::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        names = String[String(strip(t)) for t in split(targets, ',') if !isempty(strip(t))]
        note = ""
        if isempty(names)
            info = NotebookServer.publish_doc_info(nb)
            names = String[String(t) for t in get(info, "assignedTargets", String[])]
            # An archive assigned to the doc (a past deposit) must not be re-minted as a side
            # effect of an implicit "publish everywhere" — archives are always explicit.
            archives = try; Set(NotebookServer.archive_target_names()); catch; Set{String}(); end
            skipped = [n for n in names if n in archives]
            if !isempty(skipped)
                filter!(n -> !(n in archives), names)
                note = "\n(skipped archive target$(length(skipped) == 1 ? "" : "s") $(join(skipped, ", ")) — a DOI deposit is deliberate; use slate.archive)"
            end
        end
        isempty(names) && return "No publish targets. Configure one with slate.publish_targets(op=\"add\", …), then pass targets=\"name1,name2\" (or assign them in the Publishing manager)." * note
        res = try
            NotebookServer.run_publish(nb, names)
        catch e
            return _surfaced(nb, "publish", Dict{String,Any}("targets" => join(names, ",")),
                             "⛔ Publish failed: " * sprint(showerror, e))
        end
        lines = ["$(r["ok"] ? "✅" : "❌") $(r["target"]) — $(r["status"])" *
                 (isempty(r["url"]) ? "" : " → " * r["url"]) *
                 (isempty(r["doi"]) ? "" : " (DOI $(r["doi"]))") for r in res["results"]]
        msg = (res["ok"] ? "Published" : "Publish completed with errors") * ":\n" * join(lines, "\n") * note
        return _surfaced(nb, "publish", Dict{String,Any}("targets" => join(names, ",")), msg)
    end

    """
        archive(notebook; target="") -> String

    ⚠ PERMANENT: deposit this notebook's standalone bundle to an ARCHIVE target (Zenodo), minting an
    immutable, citable DOI version that can never be edited or deleted. This is a milestone act (a
    release, a paper) — NEVER do it casually or as part of routine publishing, and CONFIRM WITH THE
    USER before calling unless they just asked for exactly this. `target` is the archive target's
    name from the Publishing manager; empty is accepted only when exactly one archive target is
    configured. Live-site publishing is `slate.publish`.
    """
    function archive_tool(notebook::String; target::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        archives = try
            NotebookServer.archive_target_names()
        catch e
            return "⛔ Could not read the publish ledger: " * sprint(showerror, e)
        end
        isempty(archives) && return "No archive target configured. Add one in the Publishing manager (kind=zenodo, with the API token in Secrets), then retry."
        name = String(strip(target))
        if isempty(name)
            length(archives) == 1 || return "Several archive targets configured ($(join(archives, ", "))) — pass target=\"name\"."
            name = archives[1]
        elseif !(name in archives)
            return "⛔ '$name' is not an archive target (archives: $(join(archives, ", "))). Live sites go through slate.publish."
        end
        res = try
            NotebookServer.run_publish(nb, [name]; archive = true)
        catch e
            return _surfaced(nb, "archive", Dict{String,Any}("target" => name),
                             "⛔ Archive failed: " * sprint(showerror, e))
        end
        r = res["results"][1]
        msg = r["ok"] ?
            "✅ Archived — DOI $(r["doi"]) (permanent, citable; this version can never be changed)" *
            (isempty(r["url"]) ? "" : " → " * r["url"]) :
            "❌ Archive failed: $(r["status"])\n$(r["log"])"
        return _surfaced(nb, "archive", Dict{String,Any}("target" => name), msg)
    end

    """
        publish_history(notebook="") -> String

    The publish ledger — a durable record of what was published where, and when. Pass `notebook` for
    just that document's history (timestamped events with live URLs / DOIs / commit SHAs); leave it
    empty for a summary across all documents and the configured targets.
    """
    function publish_history_tool(; notebook::String = "")::String
        if !isempty(strip(notebook))
            nb, err = _nb(notebook); nb === nothing && return err
            info = NotebookServer.publish_doc_info(nb)
            evs = get(info, "events", Any[])
            isempty(evs) && return string("No publish history for '", get(info, "slug", ""), "' yet.")
            lines = ["  $(e["ts"])  $(e["target"])  $(e["status"])" *
                     (isempty(e["url"]) ? "" : "  " * e["url"]) *
                     (isempty(e["doi"]) ? "" : "  DOI " * e["doi"]) for e in evs]
            return "History for $(get(info, "title", "")) [$(get(info, "docId", ""))]:\n" * join(lines, "\n")
        end
        view = NotebookServer.publish_ledger_view()
        docs = get(view, "documents", Any[]); tgts = get(view, "targets", Any[])
        dl = isempty(docs) ? "  (nothing published yet)" :
             join(["  $(d["title"]) [$(length(d["events"])) events] → $(join(d["targets"], ", "))" for d in docs], "\n")
        tl = isempty(tgts) ? "  (no targets configured)" :
             join(["  $(t["name"]) ($(t["kind"]))" for t in tgts], "\n")
        return "Publish ledger (backend: $(get(view, "backend", "?"))):\nDocuments:\n$dl\nTargets:\n$tl"
    end

    """
        publish_targets(op="list"; name="", kind="", config="") -> String

    Manage the named publish TARGETS in the ledger (shared across notebooks). `op="list"` shows them;
    `op="add"` upserts target `name` of `kind` ("github-pages" | "cloudflare-pages" | "netlify" |
    "s3" | "r2" | "rsync" | "rsync-serve" | "zenodo") with a JSON `config` — e.g.
    `{"repo":"me/site"}`, `{"dest":"s3://bucket","endpoint":"…"}`, `{"secretRef":"zenodo-token"}`, or
    for "rsync-serve" (rsync to your own host + a self-hosted Julia static server there):
    `{"dest":"user@host:/path","url":"http://…","bind":"127.0.0.1","port":8080}`. `op="rm"` deletes
    it. Secret VALUES are never set here — put a `secretRef` in the config and store the token in the
    manager's secret store. Note "zenodo" is an ARCHIVE backend: configured here, but deposits are
    minted only via `slate.archive` (permanent, immutable DOIs) — `slate.publish` refuses it.

    Removal is LOCAL by default (the definition goes away; sites/documents are detached; deployed
    content stays live). `op="rm", purge="true"` ALSO tears down the deployed side where feasible —
    rsync-serve stops its remote server and deletes the served dir; static hosts are a no-op.
    """
    function publish_targets_tool(; op::String = "list", name::String = "", kind::String = "",
                                  config::String = "", purge::String = "")::String
        if op == "list"
            tgts = get(NotebookServer.publish_ledger_view(), "targets", Any[])
            isempty(tgts) && return "No publish targets configured. Add one, e.g.\n  slate.publish_targets(op=add, name=site, kind=github-pages, config={\"repo\":\"me/site\"})."
            rows = [string("  ", t["name"], "  (", t["kind"], ")  ", JSON.json(t["config"])) for t in tgts]
            return "Publish targets:\n" * join(rows, "\n")
        elseif op == "add"
            (isempty(strip(name)) || isempty(strip(kind))) && return "op=add needs name= and kind=."
            cfg = try
                isempty(strip(config)) ? Dict{String,Any}() : JSON.parse(config)
            catch e
                return "bad config JSON: " * sprint(showerror, e)
            end
            NotebookServer.publish_target_set!(String(name), String(kind), cfg)
            return string("✅ target '", name, "' (", kind, ") saved.")
        elseif op == "rm"
            isempty(strip(name)) && return "op=rm needs name=."
            view = NotebookServer.publish_target_delete!(String(name); purge = lowercase(purge) == "true")
            plog = get(view, "purgeLog", String[])
            return string("✅ target '", name, "' removed (references detached).",
                          isempty(plog) ? "" : "\n" * join(plog, "\n"))
        else
            return string("bad op '", op, "' — use list|add|rm.")
        end
    end

    """
        sites(op="list"; name="", targets="", home="", title="", paths="", purge="") -> String

    Manage publish SITES (logical portfolios: one canonical local build synced to a set of
    destination targets). `op="list"` shows them. `op="set"` creates/updates site `name`:
    `targets` = comma-separated target names, `home` = the home doc slug (optional), `title` = the
    site's display title ("" ⇒ the site name), `paths` = optional per-target subpaths as
    `target=subpath` pairs (comma-separated, e.g. `bucket=stat-mech,gh=blog`) so several sites can
    share one target without overwriting each other (blank ⇒ that target's root). A (target,
    subpath) already claimed by another site is refused. `op="delete"` removes the definition AND
    the local build — when the site has destination targets you must DECIDE about the deployed
    content: the first call reports the targets and asks you to re-invoke with `purge="true"` (also
    tear down deployed content where feasible — rsync-serve is stopped and wiped; static hosts stay
    live) or `purge="false"` (leave everything deployed as-is). Ask the user which they want.
    """
    function sites_tool(; op::String = "list", name::String = "", targets::String = "",
                        home::String = "", title::String = "", paths::String = "", purge::String = "")::String
        if op == "list"
            sites = get(NotebookServer.publish_ledger_view(), "sites", Any[])
            isempty(sites) && return "No sites yet. Create one: slate.sites(op=\"set\", name=\"…\", targets=\"t1,t2\")."
            return "Sites:\n" * join(["  $(s["name"])" *
                (isempty(String(get(s, "title", ""))) ? "" : "  “$(s["title"])”") *
                "  → " * (isempty(s["targets"]) ? "(local-only)" :
                    join([let p = String(get(get(s, "paths", Dict()), t, "")); isempty(p) ? t : "$t/$p"; end for t in s["targets"]], ", ")) *
                "  · $(length(get(s, "docs", []))) doc(s)" for s in sites], "\n")
        elseif op in ("set", "create")
            isempty(strip(name)) && return "op=set needs name=."
            ts = String[String(strip(t)) for t in split(targets, ',') if !isempty(strip(t))]
            pmap = Dict{String,String}()
            for pair in split(paths, ',')
                kv = split(pair, '='; limit = 2)
                length(kv) == 2 && !isempty(strip(kv[1])) && (pmap[String(strip(kv[1]))] = String(strip(kv[2])))
            end
            try
                NotebookServer.publish_site_set!(String(name), ts, String(home), String(title); paths = pmap)
            catch e
                return "⛔ " * sprint(showerror, e)
            end
            return string("✅ site '", name, "' saved (targets: ", isempty(ts) ? "none — local staging" :
                join([let p = get(pmap, t, ""); isempty(p) ? t : "$t/$p"; end for t in ts], ", "), ").")
        elseif op == "delete"
            isempty(strip(name)) && return "op=delete needs name=."
            site = let v = NotebookServer.publish_ledger_view()
                idx = findfirst(s -> s["name"] == name, get(v, "sites", Any[]))
                idx === nothing ? nothing : v["sites"][idx]
            end
            site === nothing && return "No site '$name'."
            tnames = String[String(t) for t in get(site, "targets", String[])]
            if !isempty(tnames) && !(lowercase(purge) in ("true", "false"))
                return "Site '$name' deploys to: $(join(tnames, ", ")).\nDECIDE about the deployed content " *
                       "(ask the user): re-invoke with purge=\"true\" to also tear it down where feasible, " *
                       "or purge=\"false\" to remove only the local definition + build."
            end
            view = NotebookServer.publish_site_delete!(String(name); purge = lowercase(purge) == "true")
            plog = get(view, "purgeLog", String[])
            return string("✅ site '", name, "' removed (definition + local build).",
                          isempty(plog) ? "" : "\n" * join(plog, "\n"))
        else
            return string("bad op '", op, "' — use list|set|delete.")
        end
    end

    # Auto-start the hub at extension init so the server is always up on its port
    # (browse the index, open notebooks over HTTP) — no longer gated on the first
    # `slate.open` MCP call. Reap any orphaned workers from a prior crashed instance
    # first, and register an atexit backstop so a normal process exit also reaps.
    # Guarded: a failure here must not break tool registration.
    try
        _load_slate_config!()            # apply the persisted worker-thread spec before any worker spawns
        _reap_orphan_workers!()
        atexit(on_shutdown)
        _hub()
        @info "KaimonSlate hub auto-started" url = _base()
    catch e
        @warn "KaimonSlate hub auto-start failed" exception = (e, catch_backtrace())
    end

    return [
        GateTool("api", api),
        GateTool("open", nb_open),
        GateTool("list", nb_list),
        GateTool("close", nb_close),
        GateTool("run_on", run_on),
        GateTool("region_on", region_on),
        GateTool("sync_memo", sync_memo),
        GateTool("check_remote", check_remote),
        GateTool("remote_workers", remote_workers),
        GateTool("reap_worker", reap_worker),
        GateTool("region", region),
        GateTool("regions", regions),
        GateTool("whereis", whereis),
        GateTool("memo_trace", memo_trace),
        GateTool("read", read_cells),
        GateTool("add_cell", add_cell),
        GateTool("edit_cell", edit_cell),
        GateTool("rename_cell", rename_cell),
        GateTool("run", run_cell),
        GateTool("delete_cell", delete_cell),
        GateTool("surface", surface_controls),
        GateTool("acquire_floor", acquire_floor),
        GateTool("release_floor", release_floor),
        GateTool("view", view_cell),
        GateTool("inspect", inspect_cell),
        GateTool("diag", notebook_diag),
        GateTool("eval", scratch_eval),
        GateTool("check_eval", check_scratch_eval),
        GateTool("eval_js", eval_js),
        GateTool("export_pdf", export_pdf_tool),
        GateTool("index_docs", index_docs),
        GateTool("search_docs", search_docs_tool),
        GateTool("pkg", pkg),
        GateTool("publish", publish_tool),
        GateTool("archive", archive_tool),
        GateTool("publish_history", publish_history_tool),
        GateTool("publish_targets", publish_targets_tool),
        GateTool("sites", sites_tool),
    ]
end

"""
    on_event(channel, data, session_name)

Gate event-bus callback (the extension manifest subscribes to the `agent:` topic
prefix). Kaimon's agent service publishes each agent session's `{kind,turn,data}`
events on `agent:<id>`; we relay them onto the bound notebook's SSE so the chat
pane updates live. Other channels are ignored.
"""
function on_event(channel, data, session_name)
    try
        startswith(String(channel), "agent:") &&
            NotebookServer.relay_agent_event(String(channel), data)
    catch e
        @warn "KaimonSlate on_event failed" channel exception = (e, catch_backtrace())
    end
    return nothing
end

include("app.jl")   # the `slate` Pkg-app entrypoint + Tachikoma status TUI

"""
    on_shutdown()

Stop every running notebook server before the extension subprocess exits.
"""
function on_shutdown()
    lock(_LOCK) do
        _HUB[] === nothing || (try; stop_hub(_HUB[]); catch; end; _HUB[] = nothing)
    end
    @info "KaimonSlate shut down"
end

end # module
