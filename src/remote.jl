# ═══════════════════════════════════════════════════════════════════════════════
# Remote session landscape ── run a notebook's worker on another machine, transparently.
#
# The hub, browser, notebook file, and agents stay LOCAL; only the SlateWorker (compute +
# its project env + the module /src) runs on the chosen host. Cell code + outputs + reactive
# events flow over the same KaimonGate ZMQ gate the local worker uses — so everything
# downstream (reactivity, streaming, hot-reload) is location-transparent. This is exactly
# what `attach_gate_kernel` was designed for; here we add the spawn-remote + provision +
# sync + encryption around it.
#
# Two transports, mirroring TachiRei:
#   :tunnel  — remote binds 127.0.0.1, plaintext ZMQ, reached over `ssh -L` (SSH encrypts;
#              CURVE would be redundant). Firewall-safe: needs only port 22. Supervised —
#              the forward respawns on a drop (autossh-lite).
#   :direct  — remote binds 0.0.0.0, CURVE-encrypted ZMQ dialled straight to host:port.
#              The worker's CURVE server pubkey is fetched over the (authenticated) SSH
#              channel and pinned — no trust-on-first-use gap.
#
# Provisioning is seamless: the remote gets `julia` (assumed on PATH), a KaimonGate worker
# env (added from the registry — KaimonGate is registered), Slate's worker payload, and the
# notebook's parent project (Project.toml + /src), all rsync'd and kept in sync so the remote
# worker's Revise hot-reloads exactly like local. Package *adds* execute on the remote worker.
#
# `import Sockets`, `FileWatching` — stdlib. SSH/rsync are shelled `Cmd` argv (no shell string,
# so hostnames/paths can't inject). KaimonGate CURVE bits are reached through the client the
# hub already uses (`connect_tcp!(…; server_key=…)` does the client-side CURVE itself).
# ═══════════════════════════════════════════════════════════════════════════════

import Sockets
import FileWatching
import Dates

# ── Durable orchestration log ─────────────────────────────────────────────────────
# The extension logger drops @info/@warn structured kwargs (only the message string survives),
# which made remote provisioning/spawn effectively invisible — the exact opacity that makes a
# remote spawn undebuggable. So EVERY step of the remote path also appends here, verbatim, with a
# timestamp. This file is the answer to "where is the record of what happened?" — always on disk,
# never dependent on how the host logger renders. Read it with `slate.diag` / the worker-log tool.
const _REMOTE_LOG = joinpath(homedir(), ".cache", "kaimonslate", "remote.log")

function _rlog(msg::AbstractString)
    try
        mkpath(dirname(_REMOTE_LOG))
        open(_REMOTE_LOG, "a") do io
            println(io, "[", Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"), "] ", msg)
        end
    catch
    end
    @info "slate remote: $msg"   # also to the host logger (message string survives kwarg-stripping)
    return nothing
end

"Tail the durable remote-orchestration log (last `maxbytes`)."
function remote_log(; maxbytes::Int = 60_000)
    isfile(_REMOTE_LOG) || return "(no remote activity logged yet — $_REMOTE_LOG)"
    s = read(_REMOTE_LOG, String)
    return ncodeunits(s) > maxbytes ? "…(truncated)…\n" * String(last(s, maxbytes)) : s
end

"""
    fetch_remote_worker_log(k; maxbytes) -> String

Tail the SSH host's own `worker-<port>.log` (the remote Julia process's stdout/stderr: KaimonGate
load, serve() banner, eval output, crashes). This is the factorio-side record — fetched over the
same authenticated SSH channel we spawned it on, so it's visible locally in the browser worker-log.
"""
function fetch_remote_worker_log(k; maxbytes::Int = 30_000)
    t = k.target
    t isa RemoteTarget || return "(not a remote kernel)"
    k.port == 0 && return "(remote worker not spawned yet)"
    logf = "$_REMOTE_WORKER/worker-$(k.port).log"
    ok, out = _ssh_capture(t.ssh_host, `tail -c $maxbytes $logf`)
    ok || return "(no remote log yet at $(t.ssh_host):$logf — worker may not have started)"
    return isempty(strip(out)) ? "(remote log empty — worker may still be booting)" : out
end

# ── Run target ──────────────────────────────────────────────────────────────────
abstract type RunTarget end

"Run the worker on this machine (the default — unchanged behaviour)."
struct LocalTarget <: RunTarget end

"""
    RemoteTarget(ssh_host; transport=:tunnel, project="~/.cache/kaimonslate/remote")

Run the worker on `ssh_host` — an SSH target you have ALREADY set up (a `Host` in
`~/.ssh/config`, key-based auth). We piggyback on that: no password prompts, no host-key
negotiation here. `transport` is `:tunnel` (firewall-safe, SSH-encrypted) or `:direct`
(CURVE-encrypted straight dial). `project` is the remote path the notebook's parent project
is provisioned into (kept in sync from local).
"""
struct RemoteTarget <: RunTarget
    ssh_host::String
    transport::Symbol            # :tunnel | :direct
    project::String              # remote parent-project path (provisioned + synced)
end
RemoteTarget(ssh_host::AbstractString; transport::Symbol = :tunnel,
             project::AbstractString = "~/.cache/kaimonslate/remote") =
    RemoteTarget(String(ssh_host), transport, String(project))

is_remote(::LocalTarget) = false
is_remote(::RemoteTarget) = true

# Remote layout under the host's $HOME (all $HOME-relative → scp/ssh log in at $HOME).
const _REMOTE_ROOT      = ".cache/kaimonslate"
const _REMOTE_WORKER    = "$_REMOTE_ROOT/worker"      # Slate's worker payload (src/*.jl)
const _REMOTE_KGATE_ENV = "$_REMOTE_ROOT/kgate-env"   # a project with KaimonGate (+ Revise) instantiated
const _REMOTE_KEY_PATH  = "~/.cache/kaimon/curve/server.key"

# ── Supervised SSH tunnel (lifted from TachiRei/tunnel.jl; migrate to KaimonGate later) ──
"An OS-assigned free local TCP port (bind :0, read it, release — small race window)."
function _free_local_port()
    srv = Sockets.listen(Sockets.localhost, 0)
    p = Int(Sockets.getsockname(srv)[2])
    close(srv)
    return p
end

"""
    Tunnel — a supervised `ssh -L` forward set. Respawns the SSH process if it drops
    (autossh-lite), so the ZMQ client's reconnect survives a network blip.
"""
mutable struct Tunnel
    host::String
    forwards::Vector{Tuple{Int,Int}}   # (local_port, remote_port) — remote side is 127.0.0.1
    proc::Union{Base.Process,Nothing}
    running::Bool
    task::Union{Task,Nothing}
end

function _run_tunnel!(t::Tunnel)
    while t.running
        lflags = String[]
        for (lp, rp) in t.forwards
            push!(lflags, "-L", "$(lp):127.0.0.1:$(rp)")
        end
        # Dedicated connection; ServerAlive* makes ssh notice a dead link in ~15s and exit →
        # we respawn on the SAME local ports. stdin=devnull so background `ssh -N` doesn't exit
        # on inherited-stdin EOF.
        cmd = `ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 $lflags $(t.host)`
        try
            t.proc = Base.run(pipeline(cmd; stdin = devnull, stdout = devnull, stderr = devnull); wait = false)
            wait(t.proc)
        catch
        end
        t.proc = nothing
        t.running || break
        sleep(1.0)
    end
    return nothing
end

function open_tunnel(host::AbstractString, forwards)
    t = Tunnel(String(host), collect(Tuple{Int,Int}, forwards), nothing, true, nothing)
    t.task = Threads.@spawn _run_tunnel!(t)
    return t
end

function close_tunnel(t::Tunnel)
    t.running = false
    p = t.proc
    p === nothing || (try; kill(p); catch; end)
    return nothing
end

# ── shell helpers (argv Cmds — no shell string, so host/path can't inject) ────────
# Every remote op captures its output and LOGS on failure — provisioning must NEVER fail silently
# (that opacity is exactly what makes a remote spawn undebuggable).
_ssh(host, argv::Cmd) = `ssh -o BatchMode=yes -o ConnectTimeout=15 $host $argv`

# Run `cmd`, merging stdout+stderr; on failure, @warn the command + captured output. Returns (ok, output).
function _run_logged(cmd::Cmd, what::AbstractString)
    buf = IOBuffer()
    ok = try; run(pipeline(cmd; stdout = buf, stderr = buf)); true; catch; false; end
    s = String(take!(buf))
    ok || _rlog("FAILED: $what\n    cmd: $(string(cmd))\n    out: $(first(strip(s), 1200))")
    return (ok, s)
end

_ssh_ok(host, argv::Cmd) = first(_run_logged(_ssh(host, argv), "ssh $host"))

# Existence/predicate check over ssh — a nonzero exit is a normal FALSE (e.g. `test -f` on a missing
# file), NOT a failure, so it is deliberately NOT logged (unlike _ssh_ok, which treats nonzero as an error).
_ssh_test(host, argv::Cmd) =
    try; run(pipeline(_ssh(host, argv); stdout = devnull, stderr = devnull)); true; catch; false; end

# Run Julia CODE on the remote by shipping it as a FILE — NEVER `julia -e "…"` over ssh. ssh flattens its
# argv and the remote shell re-splits + glob-expands the result, so `;`, `[...]`, `(...)` and any newline
# mangle the program (verified: `-e 'using Pkg; …'` arrived as bare `using` → "premature end of input",
# and zsh globbed `Pkg.activate(ARGS[1])` → "no matches found"). A script path is a single clean token, so
# it survives. The script self-activates via `homedir()` (a `--project=~/…` wouldn't expand under ssh).
# Returns ok::Bool; the remote script is removed after.
function _ssh_julia!(host, code::AbstractString, what::AbstractString)
    _ssh_ok(host, `mkdir -p $_REMOTE_ROOT`) || return false
    tmp = tempname()
    write(tmp, code)
    remote = "$_REMOTE_ROOT/$(basename(tmp)).jl"
    scp_ok = try
        run(pipeline(`scp -q $tmp $(string(host, ":", remote))`; stdout = devnull, stderr = devnull)); true
    catch; false; end
    rm(tmp; force = true)
    scp_ok || (_rlog("FAILED: scp provisioning script → $host ($what)"); return false)
    ok = first(_run_logged(_ssh(host, `julia --startup-file=no $remote`), what))
    try; run(pipeline(_ssh(host, `rm -f $remote`); stdout = devnull, stderr = devnull)); catch; end
    return ok
end

# Value-fetch over ssh (curve key, SSH_CONNECTION): keep stdout CLEAN (stderr separate) but log it on failure.
function _ssh_capture(host, argv::Cmd)
    out = IOBuffer(); err = IOBuffer()
    ok = try; run(pipeline(_ssh(host, argv); stdout = out, stderr = err)); true; catch; false; end
    ok || @warn "slate remote: ssh $host FAILED" cmd = string(argv) stderr = first(strip(String(take!(err))), 800)
    return (ok, String(take!(out)))
end

# rsync a local dir → the host, over ssh. Trailing slash on src copies CONTENTS.
function _rsync!(host, localdir::AbstractString, remotedir::AbstractString; delete::Bool = false,
                 excludes::Vector{String} = String[])
    _ssh_ok(host, `mkdir -p $remotedir`)   # openrsync (macOS) has no --mkpath; ensure the dest exists
    args = String["-az"]
    delete && push!(args, "--delete")
    for e in excludes; push!(args, "--exclude", e); end
    push!(args, string(rstrip(localdir, '/'), "/"), string(host, ":", remotedir))
    return first(_run_logged(`rsync $args`, "rsync → $host:$remotedir"))
end

# ── provisioning ──────────────────────────────────────────────────────────────
# Slate's worker payload = worker.jl + every src/*.jl it (transitively) include()s. We ship ALL
# top-level src `.jl` files rather than a curated list — a curated list silently breaks the moment
# worker.jl gains an include. Hub-only files ride along unused (the worker never include()s them).

"""
    provision_remote!(t::RemoteTarget, parent_project) -> nothing

Idempotent. Ensure the host can run a SlateWorker: (1) rsync Slate's worker payload,
(2) materialise a KaimonGate worker env (added from the registry) + Revise, instantiate,
(3) rsync the notebook's parent project (Project.toml + /src) and instantiate it. Cheap on
reruns (rsync only ships deltas; the env instantiate is skipped once `.ready` exists).
"""
function provision_remote!(t::RemoteTarget, parent_project::AbstractString)
    host = t.ssh_host
    _rlog("provision START host=$host transport=$(t.transport) project=$(t.project) parent=$parent_project")
    # 1. worker payload
    srcdir = @__DIR__
    tmp = mktempdir()
    try
        for f in readdir(srcdir)
            (endswith(f, ".jl") && isfile(joinpath(srcdir, f))) && cp(joinpath(srcdir, f), joinpath(tmp, f))
        end
        _rlog("provision [1/3] rsync worker payload → $host:$_REMOTE_WORKER")
        _rsync!(host, tmp, _REMOTE_WORKER) || error("provision: rsync worker payload → $host failed")
    finally
        rm(tmp; recursive = true, force = true)
    end
    # 2. KaimonGate worker env (from the registry) — instantiate once
    if !_ssh_test(host, `test -f $_REMOTE_KGATE_ENV/.ready`)
        _rlog("provision [2/3] building KaimonGate env on $host (first run — adds KaimonGate+Revise; can take minutes)")
        code = """
        import Pkg
        Pkg.activate(joinpath(homedir(), raw"$_REMOTE_KGATE_ENV"))
        Pkg.add(["KaimonGate", "Revise"])
        Pkg.instantiate()
        """
        _ssh_julia!(host, code, "build KaimonGate env on $host") ||
            error("provision: could not build the remote KaimonGate env on $host (is `julia` on its PATH?)")
        _ssh_ok(host, `touch $_REMOTE_KGATE_ENV/.ready`)
    else
        _rlog("provision [2/3] KaimonGate env already built on $host (skip)")
    end
    # 3. parent project (Project.toml + /src) → t.project, then instantiate
    if !isempty(parent_project) && isdir(parent_project)
        _rlog("provision [3/3] rsync parent project → $host:$(t.project) + instantiate")
        _rsync!(host, parent_project, t.project; excludes = ["Manifest.toml", ".git", "*.cov"]) ||
            error("provision: rsync parent project → $host failed")
        rel = startswith(t.project, "~/") ? t.project[3:end] : t.project   # homedir()-join in the script; ~ won't expand under ssh
        code = """
        import Pkg
        Pkg.activate(joinpath(homedir(), raw"$rel"))
        Pkg.instantiate()
        """
        _ssh_julia!(host, code, "instantiate parent project on $host")
    else
        _rlog("provision [3/3] no parent project (detached notebook) — skip")
    end
    _rlog("provision DONE host=$host")
    return nothing
end

# ── continuous sync ────────────────────────────────────────────────────────────
# Watch the local parent project (/src + Project.toml) and rsync deltas to the remote on
# change, so the remote worker's Revise hot-reloads exactly like local. One task per target;
# coalesced (a burst of saves → one rsync). Package adds happen on the remote worker itself.
mutable struct SyncWatcher
    task::Task
    running::Bool
end
const _SYNCERS = Dict{String,SyncWatcher}()   # keyed by "host:remote_project"
const _SYNC_LOCK = ReentrantLock()

function start_sync!(t::RemoteTarget, parent_project::AbstractString)
    (isempty(parent_project) && !isdir(parent_project)) && return
    key = string(t.ssh_host, ":", t.project)
    lock(_SYNC_LOCK) do
        haskey(_SYNCERS, key) && _SYNCERS[key].running && return
        w = SyncWatcher(Threads.@spawn(_sync_loop(t, parent_project, key)), true)
        _SYNCERS[key] = w
    end
    return nothing
end

function _sync_loop(t::RemoteTarget, parent_project::AbstractString, key::String)
    watchdir = isdir(joinpath(parent_project, "src")) ? joinpath(parent_project, "src") : parent_project
    while get(_SYNCERS, key, nothing) !== nothing && _SYNCERS[key].running
        try
            FileWatching.watch_folder(watchdir, 2.0)          # block until a change (or 2s tick)
            sleep(0.15)                                        # coalesce a burst of saves
            _rsync!(t.ssh_host, parent_project, t.project;
                    excludes = ["Manifest.toml", ".git", "*.cov"])
        catch e
            @warn "slate remote: sync loop error" host = t.ssh_host exception = (e,) maxlog = 3
            sleep(1.0)
        end
    end
    try; FileWatching.unwatch_folder(watchdir); catch; end
    return nothing
end

function stop_sync!(t::RemoteTarget)
    key = string(t.ssh_host, ":", t.project)
    lock(_SYNC_LOCK) do
        w = get(_SYNCERS, key, nothing)
        w === nothing || (w.running = false)
        delete!(_SYNCERS, key)
    end
    return nothing
end

# ── remote worker spawn + CURVE bootstrap ────────────────────────────────────────
# The remote worker script — run as `julia <file>` (a FILE, NOT `-e`: verified on factorio that
# `-e` + nested-ssh quoting silently mangles the program). Resolves the provisioned KaimonGate env
# + worker payload via `homedir()` on the remote, includes the payload, and serves. For :direct it
# serves CURVE and allow-lists ONLY the hub's client pubkey (mutual auth: hub pins the server key).
function _remote_worker_script(t::RemoteTarget, port::Int, stream_port::Int, parent::String,
                               client_pub::String)
    bind = t.transport === :direct ? "0.0.0.0" : "127.0.0.1"
    curve = t.transport === :direct                       # tunnel = SSH-encrypted, CURVE redundant
    allow = curve ? "String[raw\"$client_pub\"]" : "String[]"
    return """
    _kg = joinpath(homedir(), raw"$_REMOTE_KGATE_ENV")
    _wk = joinpath(homedir(), raw"$_REMOTE_WORKER", "worker.jl")
    insert!(LOAD_PATH, 1, _kg)
    import KaimonGate
    try; @eval using Revise; catch; end
    include(_wk)
    SlateWorker.PARENT_PROJECT[] = raw"$parent"
    SlateWorker.start(; host="$bind", port=$port, stream_port=$stream_port,
                      curve=$curve, allowed_clients=$allow)
    while true; sleep(3600); end   # serve() returns after starting its loop on a spawned thread; keep alive
    """
end

# The hub's persistent CURVE client pubkey — the one `connect_tcp!` will present. The remote worker
# allow-lists exactly this, so no `allow_any`.
function _hub_client_pubkey()::String
    try
        kg = getfield(_kaimon(), :KaimonGate)
        return String(kg._load_or_create_client_keypair()[1])
    catch
        return ""
    end
end

"""
    spawn_and_connect_remote!(k, t::RemoteTarget, parent_project) -> (conn, tunnel|nothing)

Provision (idempotent) + start a SlateWorker on the host + connect the hub's kernel to it,
CURVE-pinned (direct) or over a supervised SSH tunnel. `k` is the GateKernel (its `.project`
is the REMOTE project path; `.port`/`.stream_port` are set here). Returns the REPLConnection
and the Tunnel (or nothing). Also starts the continuous /src sync.
"""
function spawn_and_connect_remote!(k, t::RemoteTarget, parent_project::AbstractString)
    K = _kaimon()
    host = t.ssh_host
    _rlog("═══ REMOTE SPAWN requested: notebook worker → $host (transport=$(t.transport)) ═══")
    provision_remote!(t, parent_project)
    start_sync!(t, parent_project)

    # Fixed remote ports for this worker (loopback-bound for :tunnel, 0.0.0.0 for :direct).
    port, stream_port = _next_ports()
    k.port = port; k.stream_port = stream_port
    script = _remote_worker_script(t, port, stream_port, t.project, _hub_client_pubkey())

    # Ship the worker script as a FILE (verified: `-e` + nested-ssh quoting mangles it) and launch it
    # detached with `setsid` so it outlives the ssh exec. Paths are $HOME-relative (ssh login cwd).
    remote_script = "$_REMOTE_WORKER/worker-$port.jl"
    logf = "$_REMOTE_WORKER/worker-$port.log"
    tmp = tempname()
    write(tmp, script)
    try
        run(pipeline(`scp -q $tmp $(string(host, ":", remote_script))`; stdout = devnull, stderr = devnull))
    finally
        rm(tmp; force = true)
    end
    threads = effective_worker_threads(k.threads)
    proj = startswith(t.project, "~/") ? "\$HOME/" * t.project[3:end] : t.project   # --project=~ won't expand
    launch = "cd \$HOME && setsid nohup julia --project=$proj --startup-file=no --threads=$threads $remote_script > $logf 2>&1 &"
    _rlog("spawn: launching worker on $host  (port=$port stream=$stream_port threads=$threads)\n    remote log: $host:$logf")
    # Pass the whole launch line as ONE ssh arg → the remote login shell parses `&&`/`>`/`&`/`$HOME` intact.
    # (`sh -c $launch` would be re-flattened by ssh into separate tokens and mis-parsed.)
    _ssh_ok(host, `$launch`) ||
        _rlog("spawn: worker launch returned nonzero on $host (it may still be starting)")

    # Resolve connect coordinates + CURVE server key.
    server_key = ""
    if t.transport === :direct
        # fetch the worker's CURVE server pubkey over the authenticated SSH channel, then pin.
        server_key = _fetch_and_pin_curve!(t, _remote_ip(host), port)
        connect_host, connect_port, connect_stream = _remote_ip(host), port, stream_port
        tunnel = nothing
    else
        lport, lstream = _free_local_port(), _free_local_port()
        tunnel = open_tunnel(host, [(lport, port), (lstream, stream_port)])
        connect_host, connect_port, connect_stream = "127.0.0.1", lport, lstream
    end

    # Connect (retry: remote Julia boot + KaimonGate load is slow, ~90s).
    _rlog("connect: dialing $connect_host:$connect_port (stream $connect_stream, transport=$(t.transport)) — waiting for remote boot (≤120s)")
    deadline = time() + 120; last = ""; conn = nothing; tries = 0
    while time() < deadline
        tries += 1
        try
            conn = K.connect_tcp!(_manager(), connect_host, connect_port;
                                  name = "slate-$(host)-$(port)", stream_port = connect_stream,
                                  server_key = server_key, label = k.label)
            break
        catch e
            last = sprint(showerror, e); sleep(1.0)
        end
    end
    if conn === nothing
        _rlog("connect FAILED: could not reach worker on $host:$port after $tries tries ($last)")
        error("slate remote: could not reach worker on $host:$port ($last)")
    end
    _rlog("connect OK: attached to worker on $host:$port after $tries tries → notebook now runs on $host")
    return (conn, tunnel)
end

# The routable address of `host` for a :direct dial. An ssh alias (~/.ssh/config Host) may not
# resolve as a plain hostname, so ask ssh to echo the connected peer; fall back to the alias.
function _remote_ip(host::AbstractString)
    ok, out = _ssh_capture(host, `sh -c "echo \${SSH_CONNECTION%% *}"`)
    ip = ok ? strip(first(split(strip(out), '\n'); init = "")) : ""
    return isempty(ip) ? String(host) : String(ip)
end

# Fetch the remote gate's CURVE server pubkey over SSH and pin it in Kaimon's trust store.
function _fetch_and_pin_curve!(t::RemoteTarget, connect_host::AbstractString, port::Int)
    ok, out = _ssh_capture(t.ssh_host, `head -n1 $_REMOTE_KEY_PATH`)
    pub = ok ? strip(out) : ""
    isempty(pub) && error("slate remote: no CURVE server key on $(t.ssh_host) at $_REMOTE_KEY_PATH")
    # Pin via KaimonGate's trust store when reachable through Kaimon; harmless if absent.
    try
        kg = getfield(_kaimon(), :KaimonGate)
        kg.pin_server!(connect_host, port, String(pub))
    catch
    end
    return String(pub)
end

# Tear down a remote kernel's off-machine resources: close the supervised tunnel, stop the /src
# sync, and best-effort kill the remote worker for this port — so nothing is orphaned (a leaked
# tunnel or worker is a classic remote-session failure mode). Called from `_kill_worker!`.
function teardown_remote!(k)
    if k.tunnel !== nothing
        try; close_tunnel(k.tunnel); catch; end
        k.tunnel = nothing
    end
    t = k.target
    if t isa RemoteTarget
        try; stop_sync!(t); catch; end
        # Only kill a worker we actually spawned (port assigned). pkill exits nonzero when nothing
        # matches — a normal outcome, not a failure — so route it through the quiet predicate, not _ssh_ok.
        if k.port != 0
            _rlog("teardown: closing tunnel + sync, killing remote worker-$(k.port).jl on $(t.ssh_host)")
            try; _ssh_test(t.ssh_host, `pkill -f $("worker-" * string(k.port) * ".jl")`); catch; end
        else
            _rlog("teardown: closing tunnel + sync on $(t.ssh_host) (no worker was spawned)")
        end
    end
    return nothing
end
