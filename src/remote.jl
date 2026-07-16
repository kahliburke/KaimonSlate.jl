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
import Mmap
import SHA as _SHA

# ── Durable orchestration log ─────────────────────────────────────────────────────
# The extension logger drops @info/@warn structured kwargs (only the message string survives),
# which made remote provisioning/spawn effectively invisible — the exact opacity that makes a
# remote spawn undebuggable. So EVERY step of the remote path also appends here, verbatim, with a
# timestamp. This file is the answer to "where is the record of what happened?" — always on disk,
# never dependent on how the host logger renders. Read it with `slate.diag` / the worker-log tool.
# Slate's LOCAL cache root — respects XDG_CACHE_HOME (append "kaimonslate" under it rather than
# using it verbatim; same rationale as Kaimon's cache_dir). The REMOTE layout stays literal
# ".cache/kaimonslate" ($HOME-relative over ssh) — the remote's XDG env isn't cheaply knowable.
_slate_cache_dir() = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "kaimonslate")

const _REMOTE_LOG = joinpath(_slate_cache_dir(), "remote.log")
# Resolved at write time so a test (or a sandboxed run) can redirect the durable log to a throwaway path
# via `KAIMONSLATE_REMOTE_LOG` — otherwise a test process shares the running hub's real remote.log.
_remote_log_path() = get(ENV, "KAIMONSLATE_REMOTE_LOG", _REMOTE_LOG)

function _rlog(msg::AbstractString)
    path = _remote_log_path()
    try
        mkpath(dirname(path))
        open(path, "a") do io
            # ms resolution: the reattach path is timed in tens of ms now — whole-second
            # timestamps couldn't distinguish "instant" from "1.9s" (both printed as :01→:02).
            println(io, "[", Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS.sss"), "] ", msg)
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
    port::Int                    # pinned remote main/REP port (0 ⇒ auto via _next_ports)
    stream_port::Int             # pinned remote stream/PUB port (0 ⇒ port+1)
    origin_env::String           # LOCAL project dir whose exact env to replicate on the remote ("" ⇒ none)
    datadir::String              # region-declared data root on the remote → the worker's KAIMONSLATE_DATADIR ("" ⇒ <project>/data)
    cache_root::String           # region-declared cache home on the remote → the worker's KAIMONSLATE_CACHE_HOME ("" ⇒ shared ~/.cache/kaimonslate)
    region::String               # the named region this worker serves — the adoption key ("" ⇒ a notebook's own remote main kernel)
    sysimage::Bool               # opt-in: bake + boot a PackageCompiler worker sysimage for this env (default false)
    curve::Bool                  # CURVE-encrypt this region's data channel (default true; false = plaintext, for the §7 bench)
end
RemoteTarget(ssh_host::AbstractString; transport::Symbol = :tunnel,
             project::AbstractString = "~/.cache/kaimonslate/remote",
             port::Int = 0, stream_port::Int = 0, origin_env::AbstractString = "",
             datadir::AbstractString = "", cache_root::AbstractString = "", region::AbstractString = "",
             sysimage::Bool = false, curve::Bool = true) =
    RemoteTarget(String(ssh_host), transport, String(project), port, stream_port,
                 String(origin_env), String(datadir), String(cache_root), String(region), sysimage, curve)

is_remote(::LocalTarget) = false
is_remote(::RemoteTarget) = true

# Remote layout under the host's $HOME (all $HOME-relative → scp/ssh log in at $HOME).
const _REMOTE_ROOT      = ".cache/kaimonslate"
const _REMOTE_WORKER    = "$_REMOTE_ROOT/worker"      # Slate's worker payload (src/*.jl)
const _REMOTE_KGATE_ENV = "$_REMOTE_ROOT/kgate-env"   # a project with KaimonGate (+ Revise) instantiated
const _REMOTE_SYSIMG    = "$_REMOTE_ROOT/sysimg"      # baked worker sysimages, keyed by payload+env hash
const _REMOTE_SYSIMG_BUILDER = "$_REMOTE_ROOT/sysimg-builder"  # env holding PackageCompiler (kept OFF the worker env)
const _REMOTE_KEY_PATH  = "~/.cache/kaimon/curve/server.key"

# ── Remote timing knobs ───────────────────────────────────────────────────────────────────────
# Every value below shipped as a hardcoded literal; each is now overridable per host/deployment
# WITHOUT a rebuild, via the `"remote"` object in slate.json (installed at init) → the KAIMONSLATE_<ENV>
# env var → the default. See `_rcfg` in gate_kernel.jl for the precedence + install mechanism. Values
# are SECONDS unless noted. slate.json key / env var / default / what it governs:
#   ssh_connect_timeout     KAIMONSLATE_SSH_CONNECT_TIMEOUT     15    ConnectTimeout for every ssh/scp/rsync op
#   ssh_control_persist     KAIMONSLATE_SSH_CONTROL_PERSIST     120   mux master warm-hold past the last op
#   tunnel_alive_interval   KAIMONSLATE_TUNNEL_ALIVE_INTERVAL   5     supervised tunnel ServerAliveInterval
#   tunnel_alive_count      KAIMONSLATE_TUNNEL_ALIVE_COUNT      3     supervised tunnel ServerAliveCountMax
#   tunnel_respawn_backoff  KAIMONSLATE_TUNNEL_RESPAWN_BACKOFF  1     backoff after a dropped forward before respawn
#   probe_timeout           KAIMONSLATE_PROBE_TIMEOUT           4     :direct TCP port-open probe
#   firewall_giveup         KAIMONSLATE_FIREWALL_GIVEUP         10    sustained SYN-drop ⇒ declare firewall, fail fast
#   dial_deadline_cold      KAIMONSLATE_DIAL_DEADLINE_COLD      120   cold-spawn dial (covers remote boot + KaimonGate load)
#   dial_deadline_probe     KAIMONSLATE_DIAL_DEADLINE_PROBE     15    reattach-probe / pool-adopt dial
#   dial_deadline_record    KAIMONSLATE_DIAL_DEADLINE_RECORD    5     record-first dial (a live worker answers <1s)
#   blob_chunk_timeout      KAIMONSLATE_BLOB_CHUNK_TIMEOUT      20    per-chunk ZMQ recv/send timeout (applied as ms)
#   blob_xfer_timeout       KAIMONSLATE_BLOB_XFER_TIMEOUT       600   whole-binding / direct-blob move gate timeout
#   sysimage_lock_stale     KAIMONSLATE_SYSIMAGE_LOCK_STALE     1800  concurrent sysimage-build lock staleness window
#   peer_bw_mbps            KAIMONSLATE_PEER_BW_MBPS            30    assumed rate (MB/s) for an unmeasured peer link
_ssh_connect_timeout()    = round(Int, _rcfg("ssh_connect_timeout",    "KAIMONSLATE_SSH_CONNECT_TIMEOUT",    15))
_ssh_control_persist()    = round(Int, _rcfg("ssh_control_persist",    "KAIMONSLATE_SSH_CONTROL_PERSIST",    120))
_tunnel_alive_interval()  = round(Int, _rcfg("tunnel_alive_interval",  "KAIMONSLATE_TUNNEL_ALIVE_INTERVAL",  5))
_tunnel_alive_count()     = round(Int, _rcfg("tunnel_alive_count",     "KAIMONSLATE_TUNNEL_ALIVE_COUNT",     3))
_tunnel_respawn_backoff() = _rcfg("tunnel_respawn_backoff", "KAIMONSLATE_TUNNEL_RESPAWN_BACKOFF", 1.0)
_probe_timeout()          = _rcfg("probe_timeout",          "KAIMONSLATE_PROBE_TIMEOUT",          4.0)
_firewall_giveup()        = _rcfg("firewall_giveup",        "KAIMONSLATE_FIREWALL_GIVEUP",        10.0)
_dial_deadline_cold()     = _rcfg("dial_deadline_cold",     "KAIMONSLATE_DIAL_DEADLINE_COLD",     120.0)
_dial_deadline_probe()    = _rcfg("dial_deadline_probe",    "KAIMONSLATE_DIAL_DEADLINE_PROBE",    15.0)
_dial_deadline_record()   = _rcfg("dial_deadline_record",   "KAIMONSLATE_DIAL_DEADLINE_RECORD",   5.0)
_blob_chunk_timeout_ms()  = round(Int, _rcfg("blob_chunk_timeout", "KAIMONSLATE_BLOB_CHUNK_TIMEOUT", 20.0) * 1000)
_blob_xfer_timeout()      = _rcfg("blob_xfer_timeout",      "KAIMONSLATE_BLOB_XFER_TIMEOUT",      600.0)
_sysimage_lock_stale()    = round(Int, _rcfg("sysimage_lock_stale", "KAIMONSLATE_SYSIMAGE_LOCK_STALE", 1800))
_peer_bw_default()        = _rcfg("peer_bw_mbps",          "KAIMONSLATE_PEER_BW_MBPS",           30.0) * 1.0e6

# ── Supervised SSH tunnel (lifted from TachiRei/tunnel.jl; migrate to KaimonGate later) ──
"An OS-assigned free local TCP port (bind :0, read it, release — small race window)."
function _free_local_port()
    srv = Sockets.listen(Sockets.localhost, 0)
    p = Int(Sockets.getsockname(srv)[2])
    close(srv)
    return p
end

# Bounded TCP reachability probe for a :direct dial. Returns :open (something is listening), :refused
# (host up but nothing on that port yet — e.g. a worker still booting), or :unreachable (no response
# within `timeout` — a closed/firewalled port that DROPS the SYN, the case that would otherwise block
# connect() for the full ~75 s OS TCP timeout and stall the whole run). Non-blocking: a probe that times
# out abandons its connect task (it errors out on its own); we never sit on the OS timeout.
function _probe_tcp(host::AbstractString, port::Integer; timeout::Float64 = 4.0)
    result = Threads.Atomic{Int}(0)     # 0 pending · 1 open · 2 refused · 3 unreachable
    Threads.@spawn begin
        r = try
            s = Sockets.connect(String(host), Int(port)); close(s); 1
        catch e
            occursin("refused", lowercase(sprint(showerror, e))) ? 2 : 3
        end
        Threads.atomic_cas!(result, 0, r)
    end
    t0 = time()
    while result[] == 0 && time() - t0 < timeout
        sleep(0.05)
    end
    v = result[]
    return v == 1 ? :open : v == 2 ? :refused : :unreachable
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
        cmd = `ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=$(_tunnel_alive_interval()) -o ServerAliveCountMax=$(_tunnel_alive_count()) $lflags $(t.host)`
        try
            t.proc = Base.run(pipeline(cmd; stdin = devnull, stdout = devnull, stderr = devnull); wait = false)
            wait(t.proc)
        catch
        end
        t.proc = nothing
        t.running || break
        sleep(_tunnel_respawn_backoff())
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

# SSH connection multiplexing: every remote op here is a separate ssh/scp/rsync exec, each paying
# a full connection setup (key exchange + auth — hundreds of ms on a LAN, seconds on a WAN)
# before doing any work. ControlMaster makes the first connection per host the master and every
# later exec a ~10ms slave through its socket — compounding across the many round-trips of
# provision/spawn/probe/detach. `auto` self-heals (a dead socket falls back to a fresh
# connection); ControlPersist keeps the master warm 2min past the last op. The supervised TUNNEL
# deliberately does NOT use it — it needs a dedicated connection for its ServerAlive liveness.
# Kill switch: KAIMONSLATE_NO_SSH_MUX=1.
function _ssh_mux_opts()
    get(ENV, "KAIMONSLATE_NO_SSH_MUX", "") == "1" && return String[]
    d = joinpath(_slate_cache_dir(), "mux")
    try; mkpath(d); catch; return String[]; end
    return ["-o", "ControlMaster=auto", "-o", "ControlPath=$d/%C", "-o", "ControlPersist=$(_ssh_control_persist())"]
end

# rsync's `-e` value is whitespace-tokenized by rsync itself, so a mux path containing a space
# (an exotic $HOME) would mangle it — in that case rsync just runs unmuxed.
function _rsync_ssh_opt()
    opts = _ssh_mux_opts()
    (isempty(opts) || any(o -> occursin(' ', o), opts)) && return String[]
    return ["-e", "ssh -o BatchMode=yes " * join(opts, " ")]
end

_ssh(host, argv::Cmd) = `ssh -o BatchMode=yes -o ConnectTimeout=$(_ssh_connect_timeout()) $(_ssh_mux_opts()) $host $argv`

# Run `cmd`, merging stdout+stderr; on failure, @warn the command + captured output. Returns (ok, output).
function _run_logged(cmd::Cmd, what::AbstractString)
    buf = IOBuffer()
    ok = try; run(pipeline(cmd; stdout = buf, stderr = buf)); true; catch; false; end
    s = String(take!(buf))
    ok || _rlog("FAILED: $what\n    cmd: $(string(cmd))\n    out: $(first(strip(s), 1200))")
    return (ok, s)
end

# Like `_run_logged`, but STREAMS the merged stdout/stderr into the remote log LINE-BY-LINE as it
# arrives, tagged with `what`, so a long remote step (env instantiate / precompile — minutes, otherwise
# silent) is visible live via `tail -f ~/.cache/kaimonslate/remote.log`. Each line is also handed to
# `online` (a callback the caller can point at the UI bring-up banner). Returns (ok, full output).
function _run_streamed(cmd::Cmd, what::AbstractString; online = nothing)
    out = Pipe()
    proc = try; run(pipeline(cmd; stdout = out, stderr = out); wait = false)
            catch e; _rlog("FAILED: $what (could not start: $(sprint(showerror, e)))"); return (false, ""); end
    close(out.in)
    lines = String[]
    for line in eachline(out)                     # blocks per line until the remote closes the pipe (process exit)
        push!(lines, line)
        s = strip(line); isempty(s) && continue
        _rlog("  ⟨$what⟩ $s")                     # live progress — the remote step narrates itself into the log
        online === nothing || try; online(String(s)); catch; end
    end
    wait(proc)
    ok = success(proc)
    ok || _rlog("FAILED: $what (exit $(proc.exitcode))")
    return (ok, join(lines, "\n"))
end

# Optional sink the SERVER registers to surface a live remote bring-up line in the browser (the hydrating
# banner), so a remote provision narrates itself in the UI, not only in `remote.log`. Best-effort and
# global — unset (the default) makes `_bringup_note` a no-op, so the log streaming stands on its own.
const _BRINGUP_SINK = Ref{Any}(nothing)
_bringup_note(line::AbstractString) = (f = _BRINGUP_SINK[]; f === nothing || (try; f(String(line)); catch; end); nothing)

# Stream a one-line status to the MCP CALLER of the in-flight gate tool (agent-visible progress via
# KaimonGate.progress, keyed to the current request) — so a slow tool like `check_remote` (a cold
# provision is minutes) isn't a silent "evaluating…". No-op if the gate/progress isn't available.
# Distinct from `_bringup_note` (browser bring-up banner) and `_rlog` (durable disk log).
_gate_progress(msg::AbstractString) = (try; getfield(_kaimon(), :KaimonGate).progress(String(msg)); catch; end; nothing)

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
function _ssh_julia!(host, code::AbstractString, what::AbstractString; stream::Bool = false, online = nothing)
    _ssh_ok(host, `mkdir -p $_REMOTE_ROOT`) || return (false, "")
    tmp = tempname()
    write(tmp, code)
    remote = "$_REMOTE_ROOT/$(basename(tmp)).jl"
    scp_ok = try
        run(pipeline(`scp -q $(_ssh_mux_opts()) $tmp $(string(host, ":", remote))`; stdout = devnull, stderr = devnull)); true
    catch; false; end
    rm(tmp; force = true)
    scp_ok || (_rlog("FAILED: scp provisioning script → $host ($what)"); return (false, ""))
    jcmd = _ssh(host, `$(_julia_sh("julia --startup-file=no $remote"))`)
    ok, out = stream ? _run_streamed(jcmd, what; online = online) : _run_logged(jcmd, what)
    try; run(pipeline(_ssh(host, `rm -f $remote`); stdout = devnull, stderr = devnull)); catch; end
    return (ok, out)
end

# Every remote `julia` call goes through this PATH prefix. juliaup installs its launcher shim at
# `~/.juliaup/bin/julia`, which a NON-interactive `ssh host cmd` won't see on PATH under bash (bash
# sources nothing non-interactively; zsh sources ~/.zshenv, which is why zsh hosts "just work"). Prepend
# it so `julia` resolves regardless of the login shell; harmless when julia is a system binary already on
# PATH. `\$HOME`/`\$PATH` stay unescaped for the REMOTE shell to expand.
_julia_sh(cmd::AbstractString) = "export PATH=\"\$HOME/.juliaup/bin:\$PATH\"; $cmd"

# Ensure a usable `julia` on `host`, installing juliaup UNATTENDED when it's missing. Linux/macOS only —
# `uname -s` fails/empties on Windows, where we skip and leave it to a manual install (per the agreed
# scope). Idempotent: a present julia (system or juliaup) short-circuits. Returns true iff julia is
# available afterward. Run at the top of provisioning and the preflight Julia step.
function _ensure_julia!(host)
    ver = "$(VERSION.major).$(VERSION.minor).$(VERSION.patch)"   # match the HUB's Julia
    have, out = _ssh_capture(host, `$(_julia_sh("julia --version"))`)
    if have
        # Present already — flag a version skew (non-fatal): Serialization (the jls codec across the
        # gate) and Manifest resolution can differ across Julia versions. `juliaup add $ver` fixes it.
        m = match(r"(\d+\.\d+\.\d+)", out)
        m !== nothing && m.captures[1] != ver &&
            _rlog("provision: $host runs Julia $(m.captures[1]) but the hub runs $ver — version skew (Serialization/Manifest may differ); run `juliaup add $ver && juliaup default $ver` on $host to match")
        return true
    end
    uok, uname = _ssh_capture(host, `uname -s`)
    (uok && !isempty(strip(uname))) ||
        (_rlog("provision: no `julia` on $host and it isn't a Unix host — install Julia manually (juliaup)"); return false)
    # Pin the install to the HUB's version (`--default-channel $ver`) — not "latest" — so hub↔worker
    # Serialization + Manifest stay compatible. NB: `sh -s` reads the installer SCRIPT from stdin (the
    # curl pipe), so do NOT redirect stdin (a `< /dev/null` starves it → curl broken pipe). `--yes` is unattended.
    _rlog("provision: `julia` missing on $host ($(strip(uname))) — installing juliaup + Julia $ver unattended (a couple of minutes)…")
    _run_streamed(_ssh(host, `$("curl -fsSL https://install.julialang.org | sh -s -- --yes --default-channel $ver")`),
                  "install juliaup ($ver) on $host"; online = _bringup_note)
    ok, _ = _ssh_capture(host, `$(_julia_sh("command -v julia"))`)
    ok || _rlog("provision: juliaup install on $host did not yield a working `julia` (see remote.log)")
    return ok
end

# Parse ~/.ssh/config for `Host` aliases (skipping wildcard patterns) — the candidate hosts the
# run-location picker offers. Best-effort: [] if the file is absent/unreadable.
function ssh_config_hosts()
    path = joinpath(homedir(), ".ssh", "config")
    isfile(path) || return String[]
    hosts = String[]
    try
        for line in eachline(path)
            m = match(r"^\s*Host\s+(.+)$"i, line)
            m === nothing && continue
            for h in split(strip(m.captures[1]))
                (occursin('*', h) || occursin('?', h)) && continue
                String(h) in hosts || push!(hosts, String(h))
            end
        end
    catch
    end
    return hosts
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
    append!(args, _rsync_ssh_opt())
    delete && push!(args, "--delete")
    for e in excludes; push!(args, "--exclude", e); end
    push!(args, string(rstrip(localdir, '/'), "/"), string(host, ":", remotedir))
    return first(_run_logged(`rsync $args`, "rsync → $host:$remotedir"))
end

# ── provisioning ──────────────────────────────────────────────────────────────
# Slate's worker payload = worker.jl + every src/*.jl it (transitively) include()s. We ship ALL
# top-level src `.jl` files rather than a curated list — a curated list silently breaks the moment
# worker.jl gains an include. Hub-only files ride along unused (the worker never include()s them).

# A content SHA over that payload (every top-level `src/*.jl`) — the version of the code a worker is
# RUNNING. It's baked into the boot script so a worker reports the exact payload it loaded (a running
# worker never re-includes its payload — see `attached!`; and `tools()` is fixed at boot, so a newly
# added gate tool can't appear on a live worker). The hub recomputes this on every reattach and reaps
# + cold-spawns any worker whose stamp is behind — so editing `worker.jl` reprovisions the remote
# instead of silently running stale code. Cached by the newest payload mtime (one stat sweep per
# check, not a re-hash). The reprovision ACTION is opt-in (`KAIMONSLATE_REPROVISION_STALE=1`) — see
# `_payload_current`; the stamp itself is always computed so the detection is ready when re-enabled.
const _PAYLOAD_SHA_CACHE = Ref{Tuple{Float64,String}}((-1.0, ""))
function _payload_sha()
    srcdir = @__DIR__
    files = sort!(String[joinpath(srcdir, f) for f in readdir(srcdir)
                         if endswith(f, ".jl") && isfile(joinpath(srcdir, f))])
    mt = try; maximum(mtime, files; init = 0.0); catch; 0.0; end
    (_PAYLOAD_SHA_CACHE[][1] == mt && !isempty(_PAYLOAD_SHA_CACHE[][2])) && return _PAYLOAD_SHA_CACHE[][2]
    ctx = _SHA.SHA1_CTX()
    for f in files
        _SHA.update!(ctx, codeunits(basename(f)))
        _SHA.update!(ctx, read(f))
    end
    sha = bytes2hex(_SHA.digest!(ctx))[1:16]
    _PAYLOAD_SHA_CACHE[] = (mt, sha)
    return sha
end

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
    # Reachability precheck FIRST — a clear message beats a cryptic "rsync … failed" ten steps in when the
    # host is a typo or your ssh config/key isn't set up.
    _ssh_test(host, `true`) ||
        error("Cannot reach '$host' over SSH — check the hostname and your ~/.ssh/config (key-based auth is required; try `ssh $host` in a terminal).")
    # 0. Julia — a fresh box may have none; install juliaup unattended (Linux/macOS). Everything below
    #    needs `julia`, so this gates the rest.
    _ensure_julia!(host) ||
        error("provision: no usable `julia` on '$host' (auto-install skipped/failed — Windows, or juliaup install error). Install Julia (juliaup) manually and retry.")
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
        first(_ssh_julia!(host, code, "build KaimonGate env on $host")) ||
            error("provision: could not build the remote KaimonGate env on $host (is `julia` on its PATH?)")
        _ssh_ok(host, `touch $_REMOTE_KGATE_ENV/.ready`)
    else
        _rlog("provision [2/3] KaimonGate env already built on $host (skip)")
    end
    # 3. Environment — reproduce the notebook's LOCAL env on the remote so packages match EXACTLY:
    #    ship the origin project's Project.toml + Manifest.toml (the Manifest pins registry versions and
    #    records git deps by url+tree-hash → they clone), rsync any dev'd deps' local sources + rewrite
    #    their Manifest paths to the remote copies, then instantiate. Covers registry, GitHub, and dev'd
    #    packages + the project's own /src. (Data files are out of scope for now.)
    # In every case the worker's env (t.project) ends up with KaimonGate + ExpressionExplorer (macro-aware
    # dependency recovery; locally it rides src/worker_ee on LOAD_PATH, which doesn't exist over there) —
    # plus Revise IF the user uses it locally — resolved TOGETHER with whatever else is there (one env,
    # no stacked-env skew).
    rel = startswith(t.project, "~/") ? t.project[3:end] : t.project
    infra = _local_has_revise() ?
        "[Pkg.PackageSpec(name=\"KaimonGate\"), Pkg.PackageSpec(name=\"ExpressionExplorer\"), Pkg.PackageSpec(name=\"OpenSSL_jll\"), Pkg.PackageSpec(name=\"Revise\")]" :
        "[Pkg.PackageSpec(name=\"KaimonGate\"), Pkg.PackageSpec(name=\"ExpressionExplorer\"), Pkg.PackageSpec(name=\"OpenSSL_jll\")]"
    build_env! = function ()
        if !isempty(t.origin_env) && isfile(joinpath(t.origin_env, "Project.toml"))
            _replicate_env!(t)                                # notebook env + worker infra
        elseif !isempty(parent_project) && isdir(parent_project)
            _rlog("provision [3/3] rsync parent project → $host:$(t.project) + instantiate (no resolved origin env)")
            _rsync!(host, parent_project, t.project; excludes = ["Manifest.toml", ".git", "*.cov"]) ||
                error("provision: rsync parent project → $host failed")
            first(_ssh_julia!(host, "import Pkg; Pkg.activate(joinpath(homedir(), raw\"$rel\")); try; Pkg.add($infra; preserve=Pkg.PRESERVE_ALL); catch; Pkg.add($infra); end; Pkg.instantiate()",
                              "instantiate parent project on $host")) || error("provision: parent env build → $host failed")
        else
            _rlog("provision [3/3] bare notebook — worker env = worker infra only")
            first(_ssh_julia!(host, "import Pkg; Pkg.activate(joinpath(homedir(), raw\"$rel\")); Pkg.add($infra); Pkg.instantiate()",
                              "bare worker env on $host")) || error("provision: could not build the worker env on $host")
        end
    end
    try
        build_env!()
    catch e
        # A build failure usually means the env dir carries broken resolve state — a dev-dep whose path
        # vanished, a half-written manifest, a stale entry left by an earlier provision. Reset the env's
        # Project + Manifest and rebuild ONCE from the authoritative local source, so one bad provision
        # self-heals instead of wedging every future spawn on this env. (The isolation keying means this
        # only ever touches THIS project's env.) A second failure is a real problem — let it surface.
        _rlog("provision [3/3] env build failed on $host — resetting env + one retry: " * first(sprint(showerror, e), 140))
        _ssh_ok(host, `rm -f $rel/Project.toml $rel/Manifest.toml`)
        build_env!()
    end
    _rlog("provision DONE host=$host")
    _kickoff_sysimage_build!(t, rel)   # detached + idempotent — fast workers once it lands, plain boot until then
    return nothing
end

# ── worker sysimage (bake the include'd payload's JIT) ────────────────────────────────────────
# KaimonGate's handshake path is already baked into ITS pkgimage, but worker.jl is `include`d — not a
# package — so its payload files (capture, macroexpand, memo layer, ExpressionExplorer usage) and the
# notebook/region deps JIT on the first cell. A PackageCompiler sysimage is the ONLY thing that bakes an
# included payload: it trace-compiles an execution file (we drive one `__slate_eval` through the full
# capture path — the same trivial eval the worker prewarms with) AND bakes the env's direct deps as
# fully-loaded packages. The boot line adds `-J <sysimage>` when one is present (see `_launch_worker!`);
# Revise still hot-reloads runtime /src edits on top of the baked image.
#
# The whole tree is namespaced PER ENV — `sysimg/<envkey>/…`, where envkey hashes the worker's
# `--project` dir — so multiple regions sharing a host don't collide: two regions with different preload
# envs get independent subtrees (own `current`, own images, own build lock), while two that share an env
# legitimately share one image (dedup, no rebuild thrash). Within a subtree the image is keyed by
# SHA(payload src + that env's Manifest), so a `.so` is intrinsically tied to its env: on any payload or
# Manifest drift the key changes, the build clears the stale `current` pointer (live workers fall back to
# a plain boot) and bakes a fresh image. The env-fingerprint half of the key is a CANONICAL projection of
# the resolved deps (name/uuid/version/tree-hash + julia_version), NOT raw Manifest bytes — so TOML
# re-serialization noise doesn't force needless rebuilds, while a real dep/Julia-version change still does.
# The build runs DETACHED on the remote — the first cold worker boots the slow way; every boot after the
# image lands (pool refills, reaps/respawns) is fast. A build defers if host free RAM is below
# KAIMONSLATE_SYSIMAGE_MINFREE_GB (a link is memory-hungry).
#
# OPT-IN per region: only a region with `sysimage=true` (Region.sysimage → RemoteTarget.sysimage) builds +
# boots one — it's off by default because a build is heavy (needs a C compiler + several GB free + minutes)
# and pays off most for package-heavy envs. Notebooks' own remote workers and preflight never build one.
# KAIMONSLATE_SYSIMAGE=0 is a global kill-switch that overrides even an opted-in region.
_sysimage_enabled() = get(ENV, "KAIMONSLATE_SYSIMAGE", "1") != "0"
# Minimum free RAM (GB) on the host before a sysimage build is allowed — a link peaks at several GB, so on a
# small/busy box the build defers instead of OOM-thrashing. Tunable; default sized for a ~300MB image.
_sysimage_minfree_gb() = something(tryparse(Float64, get(ENV, "KAIMONSLATE_SYSIMAGE_MINFREE_GB", "")), 5.0)

# Per-env sysimage subdir (host-$HOME-relative), keyed by a hash of the worker's `--project` dir. Computed
# hub-side from the SAME `t.project` string at both the build and the boot site so they always agree.
_sysimage_envkey(project::AbstractString) = bytes2hex(_SHA.sha1(codeunits(String(project))))[1:12]
_sysimage_dir(project::AbstractString) = "$_REMOTE_SYSIMG/$(_sysimage_envkey(project))"

# The precompile execution file (run with the worker env active): include the payload and drive the
# eval/capture path so its hot specializations bake in. Best-effort throughout — a trace error just means
# fewer baked methods, never a failed build.
_sysimage_exec_contents() = """
# Auto-generated by KaimonSlate — trace-compile the worker payload's eval/capture path into the sysimage.
try
    include(joinpath(homedir(), raw"$_REMOTE_WORKER", "worker.jl"))
    for src in ("1 + 1", "[i^2 for i in 1:4]", "sum(rand(8))")
        try; SlateWorker.__slate_eval(src; filename = "cell:__sysimg_precompile__"); catch; end
    end
catch
end
"""

# The remote build program: recompute the key, skip if already current, else (invalidating a drifted
# pointer first) bake `sysimg/<key>.so` via PackageCompiler from a dedicated builder env, then publish
# `sysimg/current` atomically and prune older images. Self-guarded against concurrent builds by a lockfile.
function _sysimage_build_script(projrel::AbstractString, sysreldir::AbstractString, minfree_gb::Real)
    io = IOBuffer()
    P(s) = println(io, s)
    P("import Pkg, TOML, SHA")   # all stdlib — always available on the remote's default Julia
    P("home = homedir()")
    P("proj = joinpath(home, raw\"$projrel\")")
    P("sysdir = joinpath(home, raw\"$sysreldir\"); mkpath(sysdir)")   # per-env subtree (no cross-region collision)
    # key = SHA1 over the payload (basenames + contents) + a CANONICAL projection of the env's resolved deps
    # (sorted name/uuid/version/tree-hash-or-path + julia_version) — NOT the raw Manifest bytes, which churn
    # on TOML re-serialization and julia_version stamps and would force needless rebuilds. Still change-correct:
    # a real dep bump or a Julia upgrade shifts the key (a sysimage IS Julia-version-specific and must rebuild).
    P("payload = joinpath(home, raw\"$_REMOTE_WORKER\")")
    # Hash the payload SOURCE only — exclude the transient per-port boot scripts (`worker-<port>.jl`) that
    # `_launch_worker!` writes into this same dir, or the key would drift on every single spawn (new port →
    # new boot script) and rebuild endlessly. The rsync'd src payload (worker.jl + its includes) is stable.
    P("files = sort!(filter(f -> endswith(f, \".jl\") && !occursin(r\"^worker-\\d+\\.jl\$\", basename(f)), readdir(payload; join = true)))")
    P("ctx = SHA.SHA1_CTX()")
    P("for f in files; SHA.update!(ctx, codeunits(basename(f))); SHA.update!(ctx, read(f)); end")
    P("mf = joinpath(proj, \"Manifest.toml\")")
    P("if isfile(mf)")
    P("  md = TOML.parsefile(mf)")
    P("  SHA.update!(ctx, codeunits(string(get(md, \"julia_version\", \"\"))))")
    P("  mdeps = get(md, \"deps\", Dict{String,Any}())")
    P("  for name in sort!(collect(keys(mdeps)))")
    P("    for e in mdeps[name]")
    P("      e isa AbstractDict || continue")
    P("      SHA.update!(ctx, codeunits(string(name, \";\", get(e, \"uuid\", \"\"), \";\", get(e, \"version\", \"\"), \";\", get(e, \"git-tree-sha1\", get(e, \"path\", \"\")), \"|\")))")
    P("    end")
    P("  end")
    P("end")
    P("key = bytes2hex(SHA.digest!(ctx))[1:16]")
    P("target = joinpath(sysdir, key * \".so\"); curf = joinpath(sysdir, \"current\")")
    P("println(\"[sysimg] key=\$key\"); flush(stdout)")
    # already current → nothing to do (checked BEFORE the memory guard: skipping needs no headroom)
    P("if isfile(curf) && strip(read(curf, String)) == key && isfile(target); println(\"[sysimg] already current — nothing to do\"); exit(0); end")
    # Free-RAM guard: a sysimage link peaks at several GB; on a tight box DEFER rather than OOM-thrash. We keep
    # any existing `current` bootable (a slightly-stale image still loads — Revise reloads /src on top), so
    # deferring is safe; a later provision on a quieter box builds it. Tunable via KAIMONSLATE_SYSIMAGE_MINFREE_GB.
    # Available RAM is read per-OS (the remote's Julia): Linux /proc/meminfo, macOS `vm_stat` (free+inactive
    # pages), anything else unbounded (Inf ⇒ guard off) rather than assuming a Linux-only /proc.
    P("avail = try")
    P("  if Sys.islinux()")
    P("    parse(Float64, match(r\"MemAvailable:\\s+(\\d+)\", read(\"/proc/meminfo\", String)).captures[1]) / 1048576")
    P("  elseif Sys.isapple()")
    P("    vs = read(`vm_stat`, String); pg = (m = match(r\"page size of (\\d+)\", vs)) === nothing ? 4096 : parse(Int, m.captures[1])")
    P("    fp(re) = ((m = match(re, vs)) === nothing ? 0 : parse(Int, m.captures[1]))")
    P("    (fp(r\"Pages free:\\s+(\\d+)\") + fp(r\"Pages inactive:\\s+(\\d+)\")) * pg / 2^30")
    P("  else; Inf; end")
    P("catch; Inf; end")
    P("if avail < $minfree_gb; println(\"[sysimg] only \$(round(avail; digits = 1))GB free (< $(minfree_gb)GB) — deferring build (lower KAIMONSLATE_SYSIMAGE_MINFREE_GB to force)\"); exit(0); end")
    # drift → clear the stale pointer so workers fall back to a plain boot while we rebuild
    P("if isfile(curf); prev = strip(read(curf, String)); rm(curf; force = true); println(\"[sysimg] payload/env drift (\$prev → \$key) — invalidated; rebuilding\"); end")
    # concurrent-build lock (stale after 30 min)
    P("lk = joinpath(sysdir, \".building\")")
    P("if isfile(lk) && (time() - mtime(lk)) < $(_sysimage_lock_stale()); println(\"[sysimg] another build in progress — skip\"); exit(0); end")
    P("write(lk, key)")
    P("try")
    P("  builder = joinpath(home, raw\"$_REMOTE_SYSIMG_BUILDER\"); Pkg.activate(builder)")
    P("  if !isfile(joinpath(builder, \"Project.toml\")) || !occursin(\"PackageCompiler\", read(joinpath(builder, \"Project.toml\"), String))")
    P("    Pkg.add(\"PackageCompiler\")")
    P("  end")
    P("  Pkg.instantiate()")
    P("  exec = joinpath(sysdir, \"precompile_exec.jl\")")
    P("  open(exec, \"w\") do eio; write(eio, $(repr(_sysimage_exec_contents()))); end")
    P("  pdata = TOML.parsefile(joinpath(proj, \"Project.toml\"))")
    P("  pkgs = sort!(collect(keys(get(pdata, \"deps\", Dict{String,Any}()))))")   # env's direct deps → baked as packages
    P("  println(\"[sysimg] baking \$(length(pkgs)) package(s) + payload trace → \$target\"); flush(stdout)")
    P("  @eval import PackageCompiler")   # added at runtime above → @eval + invokelatest to dodge world-age
    P("  Base.invokelatest(PackageCompiler.create_sysimage, pkgs; sysimage_path = target, project = proj, precompile_execution_file = exec)")
    P("  tmpc = curf * \".tmp\"; write(tmpc, key); mv(tmpc, curf; force = true)")   # publish the pointer atomically
    P("  for f in readdir(sysdir; join = true); (endswith(f, \".so\") && f != target) && rm(f; force = true); end")   # prune old images
    # Prime the pkgimage cache against the NEW base image: the very first boot with a fresh custom sysimage
    # otherwise recompiles the env's pkgimages (~a minute on a slow CPU), which would land under the first
    # real worker. Pay it HERE, detached and idle, by running the exec (include worker.jl + evals = the real
    # boot's load path) once under the new image, so every subsequent worker boot hits the warm cache.
    P("  try; println(\"[sysimg] priming pkgimage cache against new image…\"); flush(stdout); run(pipeline(`\$(Base.julia_cmd()[1]) --sysimage=\$target --project=\$proj --startup-file=no \$exec`; stdout = devnull, stderr = devnull)); catch e; println(\"[sysimg] prime skipped (\$(first(sprint(showerror, e), 80)))\"); end")
    P("  println(\"[sysimg] DONE — current=\$key\")")
    P("finally")
    P("  rm(lk; force = true)")
    P("end")
    return String(take!(io))
end

# Ship the build program to the host and launch it DETACHED (survives the ssh channel closing), stdout →
# the build log. Fire-and-forget: workers boot without the image until it lands, then pick it up via `-J`.
function _kickoff_sysimage_build!(t::RemoteTarget, projrel::AbstractString; force::Bool = false)
    (t.sysimage || force) || return nothing  # OPT-IN per region (Region.sysimage); `force` = an explicit UI/API build
    _sysimage_enabled() || return nothing     # global kill-switch (KAIMONSLATE_SYSIMAGE=0) overrides even an opted-in region
    host = t.ssh_host
    # PackageCompiler needs a system C compiler to link the sysimage. Probe for one FIRST and skip cleanly
    # if the host has none — the worker just keeps booting the plain way, and we avoid a scary linker-error
    # stacktrace in the build log on a minimal box (e.g. a fresh cloud image with no build tools).
    if !_ssh_test(host, `sh -c $("command -v cc || command -v gcc || command -v clang")`)
        _rlog("sysimg: no C compiler (cc/gcc/clang) on $host — skipping sysimage build (install build tools, e.g. `apt install build-essential`, to enable)")
        return nothing
    end
    sysreldir = _sysimage_dir(t.project)            # sysimg/<envkey> — per-env, matches the boot-line resolver
    _ssh_ok(host, `mkdir -p $sysreldir`) || return nothing
    remote = "$sysreldir/build.jl"
    logf = "$sysreldir/build.log"
    tmp = tempname()
    write(tmp, _sysimage_build_script(projrel, sysreldir, _sysimage_minfree_gb()))
    ok = try
        run(pipeline(`scp -q $(_ssh_mux_opts()) $tmp $(string(host, ":", remote))`; stdout = devnull, stderr = devnull)); true
    catch; false; end
    rm(tmp; force = true)
    ok || (_rlog("sysimg: scp build script → $host failed (skip)"); return nothing)
    launch = "cd \$HOME && export PATH=\"\$HOME/.juliaup/bin:\$PATH\" && if command -v setsid >/dev/null 2>&1; then setsid nohup julia --startup-file=no $remote > $logf 2>&1 & else nohup julia --startup-file=no $remote > $logf 2>&1 & fi"
    _rlog("sysimg: launching detached build on $host  (log: $host:$logf)")
    _ssh_ok(host, `$launch`) || _rlog("sysimg: build launch returned nonzero on $host (it may still be starting)")
    return nothing
end

# Sysimage build state for a target's env — ONE ssh that reads the per-env `sysimg/<envkey>/` dir: the
# published `current` key, the built `.so` (size + mtime), whether a build is in progress, whether the host
# even has a C compiler, and a short tail of the build log. Feeds the Regions UI's sysimage panel.
function sysimage_status(t::RemoteTarget)
    host = t.ssh_host
    d = _sysimage_dir(t.project)
    res = Dict{String,Any}("host" => host, "envkey" => _sysimage_envkey(t.project), "opt_in" => t.sysimage,
                           "reachable" => false, "building" => false, "current" => "", "bytes" => 0,
                           "built" => 0, "stale" => false, "compiler" => true, "log" => "")
    isempty(host) && return res
    pr = startswith(t.project, "~/") ? t.project[3:end] : t.project   # env dir → Manifest for the staleness check
    # Pass the WHOLE script as the single remote-command arg (like `_launch_worker!`'s launch line): ssh
    # flattens argv and the remote LOGIN shell re-parses, so `sh -c <multi-word>` would be mangled — but a
    # lone command string is parsed intact (`$(...)`, `[ … ]`, `;`, `&&` all survive).
    # Staleness is an mtime heuristic (cheap, no content hash): a payload `.jl` (EXCLUDING the transient
    # per-port `worker-<port>.jl` boot scripts, which the build key also ignores) or the env Manifest newer
    # than the `.so` ⇒ the image predates a code/dep change and should be rebuilt.
    sh = "D=\$HOME/$d; CUR=\$(cat \$D/current 2>/dev/null); echo \"current=\$CUR\"; " *
         "if [ -n \"\$CUR\" ] && [ -f \"\$D/\$CUR.so\" ]; then SO=\$D/\$CUR.so; echo \"bytes=\$(stat -c %s \$SO 2>/dev/null || stat -f %z \$SO 2>/dev/null)\"; echo \"built=\$(stat -c %Y \$SO 2>/dev/null || stat -f %m \$SO 2>/dev/null)\"; " *
         "N=\$(find \$HOME/$_REMOTE_WORKER -maxdepth 1 -name '*.jl' ! -name 'worker-*.jl' -newer \$SO -print -quit 2>/dev/null); " *
         "MF=\$HOME/$pr/Manifest.toml; if [ -z \"\$N\" ] && [ -f \"\$MF\" ] && [ \"\$MF\" -nt \"\$SO\" ]; then N=\$MF; fi; " *
         "[ -n \"\$N\" ] && echo stale=1; fi; " *
         "if [ -f \$D/.building ]; then echo building=1; fi; " *
         "if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then echo nocompiler=1; fi; " *
         # Marker must NOT start with `=` — zsh (a common login shell) would try equals-expansion on `===LOG===`
         # (`=cmd` → path of cmd), fail with a nonzero exit, and make the whole ssh command look like it failed.
         # `|| true` so a MISSING build.log (a host that hasn't built yet) doesn't make `tail` — the last
         # command — exit nonzero, which _ssh_capture would read as an unreachable host (false "status
         # unavailable"). A genuine ssh/connection failure still returns nonzero via ssh itself.
         "echo __SLATELOG__; tail -n 14 \$D/build.log 2>/dev/null || true"
    ok, out = try; _ssh_capture(host, `$sh`); catch; (false, ""); end
    ok || return res
    res["reachable"] = true
    parts = split(out, "__SLATELOG__")
    for line in split(strip(parts[1]), '\n')
        kv = split(line, '='; limit = 2); length(kv) == 2 || continue
        k, v = strip(kv[1]), strip(kv[2])
        k == "current" && (res["current"] = String(v))
        k == "bytes" && (res["bytes"] = something(tryparse(Int, v), 0))
        k == "built" && (res["built"] = something(tryparse(Int, v), 0))
        k == "building" && (res["building"] = true)
        k == "stale" && (res["stale"] = true)
        k == "nocompiler" && (res["compiler"] = false)
    end
    length(parts) > 1 && (res["log"] = String(strip(parts[2])))
    return res
end

# Region-level wrappers for the UI/API: read a region's sysimage state, or kick off an EXPLICIT build
# (forced past the opt-in gate). The build first provisions (idempotent — ensures the env's Project/Manifest
# exist) then launches detached; both in a background task so the request returns at once (UI polls status).
# Telemetry history the hub recorded for the worker on (host, port) — the ring for the kernel connected to
# it (conn.name == "slate-<host>-<port>"). Empty when the hub has no live connection (only attached workers
# stream telemetry in; an idle / other-hub worker surfaces just its point-in-time `.stats` sidecar). Each
# sample is the flat telemetry NamedTuple (cpu, rss, memo, sys_cpu, load1, …, rcv = hub arrival time).
worker_stats_history(host::AbstractString, port::Integer) =
    (st = kernel_stats("slate-$host-$port"); st === nothing ? Any[] : st.history)

sysimage_status_for_region(name) = (r = region_get(name); r === nothing ? nothing : sysimage_status(_region_target(r)))
function sysimage_build_for_region!(name)
    r = region_get(name); r === nothing && return (; ok = false, error = "no region '$name'")
    isempty(r.host) && return (; ok = false, error = "region '$(r.name)' has no host")
    t = _region_target(r)
    rel = startswith(t.project, "~/") ? t.project[3:end] : t.project
    Threads.@spawn try
        provision_remote!(t, r.preload)               # idempotent — ensures the env exists before the build reads its Manifest
        _kickoff_sysimage_build!(t, rel; force = true)
    catch e
        _rlog("sysimg: manual build for region '$(r.name)' failed to start — $(sprint(showerror, e))")
    end
    return (; ok = true, host = t.ssh_host, envkey = _sysimage_envkey(t.project))
end

# Dev'd dependencies in a Manifest = entries carrying a `path` (a local checkout, `Pkg.develop`). Returns
# name => absolute-local-path. Registry deps have no path; git deps have a `repo-url` (they clone on the
# remote straight from the Manifest, so need no special handling). Paths may be relative to the env dir.
# A line-scan of the stable `[[deps.Name]]` … `path = "…"` format — no TOML dep needed on the hub side.
function _dev_deps(manifest::AbstractString, envdir::AbstractString)
    out = Pair{String,String}[]
    isfile(manifest) || return out
    curname = ""
    for line in eachline(manifest)
        m = match(r"^\[\[deps\.(.+?)\]\]\s*$", line)
        if m !== nothing; curname = String(m.captures[1]); continue; end
        startswith(strip(line), "[") && (curname = "")           # entered some other table → out of a deps block
        isempty(curname) && continue
        pm = match(r"^\s*path\s*=\s*\"(.*)\"\s*$", line)
        pm === nothing && continue
        p = String(pm.captures[1])
        push!(out, curname => (isabspath(p) ? p : abspath(joinpath(envdir, p))))
        curname = ""
    end
    return out
end

const _REMOTE_DEVSRC = "$_REMOTE_ROOT/devsrc"   # rsync'd sources for dev'd deps (Pkg.develop targets)

"""
    _replicate_env!(t::RemoteTarget) -> nothing

Reproduce `t.origin_env` (the notebook's local project) on the remote at `t.project`: rsync it wholesale
(Project.toml + Manifest.toml + any /src), rsync each dev'd dep's source into `devsrc/<name>` and rewrite
BOTH the Manifest `path` and Project.toml's `[sources]` path (Julia ≥1.11 resolves dev deps from the
latter) to point there, then instantiate. The Manifest makes registry versions exact and clones git deps
from their recorded urls; the dev-source rsync makes local checkouts resolve on the host.
"""
function _replicate_env!(t::RemoteTarget)
    host = t.ssh_host
    origin = t.origin_env
    _rlog("env: replicating origin env → $host:$(t.project)  (from $origin)")
    # 1. the origin project WHOLESALE, INCLUDING the Manifest (exact versions) + its own /src.
    _rsync!(host, origin, t.project; excludes = [".git", "*.cov", ".ready"]) ||
        error("env: rsync origin project → $host failed")
    # 2. dev'd deps: rsync each local source into devsrc/<name>; collect (name → $HOME-relative remote path).
    devs = _dev_deps(joinpath(origin, "Manifest.toml"), origin)
    rewrites = Tuple{String,String}[]
    for (name, lpath) in devs
        # The project itself appears in its own Manifest as a path dep (`path = "."`). It IS `t.project`
        # on the remote (the active project) — don't copy it into devsrc or redirect its path there.
        # Normalize + strip the trailing slash the `path="."` form leaves (abspath("x/.") → "x/"), so it
        # compares equal to the env dir.
        if rstrip(normpath(abspath(lpath)), '/') == rstrip(normpath(abspath(origin)), '/')
            _rlog("env: dev dep '$name' is the project itself — left as the active project (not redirected to devsrc)")
            continue
        end
        if !isdir(lpath)
            _rlog("env: dev dep '$name' source missing locally ($lpath) — skipping (its Manifest path will dangle)")
            continue
        end
        rp = "$_REMOTE_DEVSRC/$name"
        _rsync!(host, lpath, rp; excludes = [".git", "*.cov"]) ||
            (_rlog("env: rsync dev dep '$name' → $host failed"); continue)
        push!(rewrites, (name, rp))
        _rlog("env: dev dep '$name' → $host:$rp")
    end
    # 3. rewrite the remote Manifest's dev paths to the rsync'd locations, then instantiate.
    projrel = startswith(t.project, "~/") ? t.project[3:end] : t.project
    # STREAM the instantiate/precompile — the long, otherwise-silent step — into the remote log live, so a
    # multi-minute bring-up narrates its progress (resolve, install, Precompiling …) instead of going dark.
    ok, out = _ssh_julia!(host, _env_instantiate_script(projrel, rewrites, _local_has_revise()),
                          "instantiate on $host"; stream = true, online = _bringup_note)
    ok || error("env: instantiate failed on $host — $(first(strip(out), 500))")
    return nothing
end

# Does the USER use Revise locally (it's in their global default env)? If so we mirror it onto the remote
# worker so hot-reload matches their setup; if they don't use Revise, we don't force it into the worker env.
function _local_has_revise()
    mf = joinpath(first(Base.DEPOT_PATH), "environments", "v$(VERSION.major).$(VERSION.minor)", "Manifest.toml")
    isfile(mf) || return false
    try
        for line in eachline(mf)
            occursin(r"^\[\[deps\.Revise\]\]\s*$", line) && return true
        end
    catch
    end
    return false
end

# The remote script: rewrite each dev dep's Manifest `path` to its rsync'd remote source, then instantiate
# the project. Uses the TOML stdlib on the remote (always available); homedir() resolves the absolute paths.
function _env_instantiate_script(projrel::AbstractString, rewrites::Vector{Tuple{String,String}}, add_revise::Bool)
    infra = add_revise ?
        "[Pkg.PackageSpec(name=\"KaimonGate\"), Pkg.PackageSpec(name=\"ExpressionExplorer\"), Pkg.PackageSpec(name=\"Revise\")]" :
        "[Pkg.PackageSpec(name=\"KaimonGate\"), Pkg.PackageSpec(name=\"ExpressionExplorer\")]"
    io = IOBuffer()
    println(io, "import Pkg, TOML")
    println(io, "proj = joinpath(homedir(), raw\"$projrel\")")
    println(io, "mf = joinpath(proj, \"Manifest.toml\")")
    if !isempty(rewrites)
        println(io, "if isfile(mf)")
        println(io, "  data = TOML.parsefile(mf)")
        println(io, "  deps = get(data, \"deps\", Dict{String,Any}())")
        for (name, rp) in rewrites
            println(io, "  if haskey(deps, raw\"$name\")")
            println(io, "    for e in deps[raw\"$name\"]; e isa AbstractDict && (e[\"path\"] = joinpath(homedir(), raw\"$rp\")); end")
            println(io, "  end")
        end
        println(io, "  open(mf, \"w\") do _io; TOML.print(_io, data); end")
        println(io, "end")
        # Julia ≥1.11 records a `Pkg.develop`'d path in Project.toml's `[sources]`, and that is what the
        # RESOLVER reads (`Pkg.add`/instantiate) — rewriting only the Manifest leaves `[sources]` pointing
        # at the local `../dep` path, which dangles on the remote. Redirect it to the rsync'd devsrc too.
        println(io, "pf = joinpath(proj, \"Project.toml\")")
        println(io, "if isfile(pf)")
        println(io, "  pdata = TOML.parsefile(pf)")
        println(io, "  src = get(pdata, \"sources\", nothing)")
        println(io, "  if src isa AbstractDict")
        for (name, rp) in rewrites
            println(io, "    if get(src, raw\"$name\", nothing) isa AbstractDict && haskey(src[raw\"$name\"], \"path\")")
            println(io, "      src[raw\"$name\"][\"path\"] = joinpath(homedir(), raw\"$rp\")")
            println(io, "    end")
        end
        println(io, "    open(pf, \"w\") do _io; TOML.print(_io, pdata); end")
        println(io, "  end")
        println(io, "end")
    end
    println(io, "Pkg.activate(proj)")
    # Add the worker infra INTO this same env so it resolves against the notebook's exact dependency
    # versions (no stacked-env skew). KaimonGate is always needed (the gate); ExpressionExplorer too
    # (worker-side macro-aware dep recovery — local workers get it via src/worker_ee on LOAD_PATH, but
    # that path doesn't exist on a remote host); Revise only if the user uses it locally (see
    # `_local_has_revise` at the call site) — mirror their setup, don't force it.
    # preserve=PRESERVE_ALL keeps the notebook's EXACT pins so the infra can't bump a shared dep and
    # invalidate the notebook's (very expensive, e.g. Makie) precompile cache — that doubles the build.
    # Fall back to a normal add only if the infra genuinely can't be satisfied against those pins.
    println(io, "try; Pkg.add($infra; preserve=Pkg.PRESERVE_ALL); catch; Pkg.add($infra); end")
    println(io, "Pkg.instantiate()")
    return String(take!(io))
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
            # Sync /src (project code) only — NEVER the env files, or we'd clobber the replicated
            # Project/Manifest (the exact env `_replicate_env!` set up) on every save.
            _rsync!(t.ssh_host, parent_project, t.project;
                    excludes = ["Manifest.toml", "Project.toml", ".git", "*.cov"])
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
                               client_pub::String; warm_deps::Bool = false)
    bind = t.transport === :direct ? "0.0.0.0" : "127.0.0.1"
    curve = t.transport === :direct                       # tunnel = SSH-encrypted, CURVE redundant
    allow = curve ? "String[raw\"$client_pub\"]" : "String[]"
    # ONE environment: the worker runs with --project=<rproj>, which provisioning has populated with the
    # notebook's own packages PLUS KaimonGate + Revise — all resolved together. We deliberately do NOT
    # stack a separate KaimonGate env on the LOAD_PATH: that caused Revise (precompiled against its env's
    # deps) to skew against the notebook env's versions of shared deps (OrderedCollections, …) and crash
    # its package-load callback. One consistent resolve = no skew.
    # A region can PIN this worker's data root (`datadir()`/`@sfile`) to a declared path — a fast
    # scratch disk, a shared mount that already holds the data. Set it BEFORE the worker starts so
    # `datadir()` resolves it from t=0 (a cold-spawned region worker is correct from birth; an
    # ADOPTED pool worker gets the same via `__slate_adopt`). Empty ⇒ the worker's own <project>/data.
    dd = isempty(t.datadir) ? "" : "ENV[\"KAIMONSLATE_DATADIR\"] = expanduser(raw\"$(t.datadir)\")\n    "
    # Likewise a region can PIN this worker's CACHE home (its content-addressed store) so co-located
    # region workers get SEPARATE CAS instead of sharing `~/.cache/kaimonslate/memo` — the store split
    # that makes a cross-region blob actually move over the peer channel instead of dedup'ing to 0.
    # Set before start so `_memo_dir()` resolves it from t=0. Empty ⇒ the shared default.
    cr = isempty(t.cache_root) ? "" : "ENV[\"KAIMONSLATE_CACHE_HOME\"] = expanduser(raw\"$(t.cache_root)\")\n    "
    return """
    _t0 = time(); _bt(m) = try; println("[slate-boot] +" * string(round(time() - _t0; digits = 1)) * "s " * m); flush(stdout); catch; end
    $(dd)$(cr)_wk = joinpath(homedir(), raw"$_REMOTE_WORKER", "worker.jl")
    _bt("script start (unix=" * string(round(Int, time())) * ")")   # correlate with the hub's launch time
    _bt("image=" * try; basename(unsafe_string(Base.JLOptions().image_file)); catch; "?"; end)   # confirm plain vs `-J` sysimage boot
    import KaimonGate
    _bt("KaimonGate loaded")
    try; @eval using Revise; catch; end
    _bt("Revise loaded")
    include(_wk)
    _bt("worker payload loaded")
    SlateWorker.PARENT_PROJECT[] = expanduser(raw"$parent")   # `~/.cache/…` → absolute, so @asset/@sfile/datadir don't emit un-expandable tilde paths
    SlateWorker.PAYLOAD_SHA[] = raw"$(_payload_sha())"
    SlateWorker.start(; host="$bind", port=$port, stream_port=$stream_port,
                      curve=$curve, allowed_clients=$allow, data_port=$(port + 2),
                      warm_deps=$warm_deps, blob_curve=$(_blob_curve(t)), blob_bind="0.0.0.0",
                      stats_path=joinpath(homedir(), raw"$_REMOTE_WORKER", "worker-$port.stats"))
    _bt("serving")   # phase breakdown: Julia-init = launch→script-start; then KaimonGate / Revise / payload / serve
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

# Ship a worker boot script to the host and launch it detached (setsid/nohup), then write its
# manifest + state sidecar. Fire-and-forget: callers dial the port to learn whether the worker
# actually came up. Shared by the notebook spawn path and `warm_pool!` — a pool worker is just
# a launch with no notebook (`label=""`, `pool=true`, state starts at `idle`, and `warm_deps`
# pays the preload env's package loads while nobody is attached).
function _launch_worker!(t::RemoteTarget, port::Int, stream_port::Int;
                         label::AbstractString, parent::AbstractString,
                         threads::AbstractString = "", warm::Bool = false,
                         region::AbstractString = "", warm_deps::Bool = false)
    host = t.ssh_host
    hubkey = _hub_client_pubkey()
    script = _remote_worker_script(t, port, stream_port, t.project, hubkey; warm_deps = warm_deps)

    # Ship the worker script as a FILE (verified: `-e` + nested-ssh quoting mangles it) and launch it
    # detached so it outlives the ssh exec. `setsid` gives a clean new session but is Linux-only
    # (absent on macOS), so we fall back to plain `nohup … &`, which — with stdio redirected to the
    # log file — also survives the ssh channel closing. Paths are $HOME-relative (ssh login cwd).
    remote_script = "$_REMOTE_WORKER/worker-$port.jl"
    logf = "$_REMOTE_WORKER/worker-$port.log"
    tmp = tempname()
    write(tmp, script)
    try
        run(pipeline(`scp -q $(_ssh_mux_opts()) $tmp $(string(host, ":", remote_script))`; stdout = devnull, stderr = devnull))
    finally
        rm(tmp; force = true)
    end
    nthreads = effective_worker_threads(threads)
    proj = startswith(t.project, "~/") ? "\$HOME/" * t.project[3:end] : t.project   # --project=~ won't expand
    # Self-identifying process tag: which region/notebook/port this worker serves, so `ps` isn't a wall of
    # anonymous `julia … worker-<port>.jl`. Exposed BOTH ways — as `KAIMONSLATE_WORKER` (visible in `ps e` /
    # /proc/<pid>/environ) and as a trailing cmdline arg the worker ignores (visible in plain `ps aux`, e.g.
    # `ps aux | grep slate:`). Region AND/OR notebook, whichever this spawn has (see `_worker_tag`).
    tag = _worker_tag(label, region, port)
    # Boot with the baked worker sysimage when one is present, resolved ON THE REMOTE so there's no extra
    # ssh round-trip: `<envdir>/current` names the live image for THIS worker's env; absent/unbuilt ⇒ `$JOPT`
    # is empty and the worker boots the plain way (graceful fallback). The env subdir matches what
    # `_kickoff_sysimage_build!` builds into, so co-hosted regions never cross-boot each other's image.
    # Use `--sysimage=<path>` (ONE token, no space) rather than `-J <path>`: the remote login shell is often
    # zsh, which does NOT word-split an unquoted `$JOPT`, so `-J <path>` would arrive as a single glued arg
    # ("-J /path") and Julia would read the value as " /path" (leading space → treated as relative → homedir
    # prepended → load failure). The `=`-joined long form has no space to split on, so it's shell-agnostic.
    sysreldir = _sysimage_dir(t.project)
    siresolve = t.sysimage ?
        "SI=\$(cat $sysreldir/current 2>/dev/null); JOPT=''; if [ -n \"\$SI\" ] && [ -f \"\$HOME/$sysreldir/\$SI.so\" ]; then JOPT=\"--sysimage=\$HOME/$sysreldir/\$SI.so\"; fi" :
        "JOPT=''"   # region didn't opt into a sysimage → always a plain boot
    jl = "julia \$JOPT --project=$proj --startup-file=no --threads=$nthreads $remote_script '$tag'"
    launch = "cd \$HOME && export PATH=\"\$HOME/.juliaup/bin:\$PATH\" && export KAIMONSLATE_WORKER='$tag' && $siresolve && if command -v setsid >/dev/null 2>&1; then setsid nohup $jl > $logf 2>&1 & else nohup $jl > $logf 2>&1 & fi"
    _rlog("spawn: launching $(warm ? "WARM " : "")worker on $host  (port=$port stream=$stream_port threads=$nthreads)$(isempty(region) ? "" : " region=$region")\n    remote log: $host:$logf")
    # Pass the whole launch line as ONE ssh arg → the remote login shell parses `&&`/`>`/`&`/`$HOME` intact.
    # (`sh -c $launch` would be re-flattened by ssh into separate tokens and mis-parsed.)
    _ssh_ok(host, `$launch`) ||
        _rlog("spawn: worker launch returned nonzero on $host (it may still be starting)")
    # Record who/what this worker serves so it's self-describing (list/reconnect/reap/adopt all read
    # this). `project` (the worker's --project env dir) is what pool adoption matches on.
    fields = ["notebook" => String(label), "parent" => String(parent), "hub" => gethostname(),
              "transport" => string(t.transport), "project" => t.project,
              "port" => string(port), "stream_port" => string(stream_port),
              "client_pubkey" => hubkey, "spawned" => Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS")]
    isempty(region) || push!(fields, "region" => String(region))   # the named region this worker serves (adoption key)
    _write_worker_manifest!(host, port, fields)
    _write_worker_state!(host, port, warm ? "idle" : "attached")
    return nothing
end

# The tail of a worker's LOG — local (read the file the spawn pump writes) or remote (ssh `tail` the
# worker log on its host). For the worker/region status popups. Best-effort: "" on any miss.
function worker_log_tail(k::GateKernel; lines::Int = 300)
    lines = clamp(lines, 1, 5000)
    if k.target isa RemoteTarget
        host = k.target.ssh_host
        rlog = "$_REMOTE_WORKER/worker-$(k.port).log"
        ok, out = try; _ssh_capture(host, `tail -n $lines $rlog`); catch; (false, ""); end
        return ok ? out : ""
    end
    p = try; k.logpath; catch; ""; end
    (isempty(p) || !isfile(p)) && return ""
    return try
        ls = readlines(p)
        join(@view(ls[max(1, length(ls) - lines + 1):end]), "\n")
    catch; ""; end
end
worker_log_tail(::Kernel; lines::Int = 300) = ""   # in-process kernel has no worker log

# Read a field off an `__slate_env_info` result — a Dict{String,Any} locally, a JSON3.Object (Symbol
# props) once it has ridden back over the gate. Returns `dv` on any miss.
_infofield(o, k::String, dv) = try
    o isa AbstractDict ? (haskey(o, k) ? o[k] : get(o, Symbol(k), dv)) :
    (hasproperty(o, Symbol(k)) ? getproperty(o, Symbol(k)) : dv)
catch
    dv
end

# Is the live worker `k` running the CURRENT worker payload? Compares its boot-baked stamp
# (`__slate_env_info().payload_sha`) to `_payload_sha()`. Stale — or an old worker that reports none —
# ⇒ false, and `attached!` reaps + cold-spawns it. A flaky env_info call ⇒ true (don't reap on a
# transient error; liveness is validated separately). Gated OFF by default — see the body.
function _payload_current(k)::Bool
    # Reprovision-on-drift is ON by default (skip with KAIMONSLATE_SKIP_PAYLOAD_CHECK=1). The worker SWAP
    # is now safe: `k.ns_gen` bumps on a fresh namespace (cold spawn / adopt) and the region dedups fold it
    # into their key, so the swapped worker's blank namespace is re-primed / re-resourced / re-synced; and
    # `_tool` errors cleanly (not a MethodError) if a best-effort caller hits the transient nil-conn window.
    get(ENV, "KAIMONSLATE_SKIP_PAYLOAD_CHECK", "") == "1" && return true
    want = _payload_sha()
    got = try
        String(_infofield(_tool(k, "__slate_env_info", Dict{String,Any}(); timeout = 6.0), "payload_sha", ""))
    catch
        return true
    end
    got == want && return true
    _rlog("payload: worker-$(k.port) for '$(k.label)' is stale " *
          "(sha $(isempty(got) ? "none" : first(got, 12)) ≠ current $(first(want, 12))) — reprovisioning")
    return false
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

    # Resolve connect coordinates + CURVE key, open the tunnel if needed, and dial. `deadline`
    # bounds the wait: a fresh spawn legitimately needs ~90s (remote Julia boot + KaimonGate
    # load), but an ALREADY-RUNNING worker answers in about a second — so the reattach dial
    # fails fast instead of hanging on a wedged process. The retry quantum is 0.25s (was 1s —
    # it sat directly on the reattach path, where try #1 usually races the tunnel coming up).
    # On failure the just-opened tunnel is CLOSED — its supervisor would otherwise respawn the
    # forward forever (a leak the old single-path flow had on its error exit).
    function dial(port, stream_port; deadline::Float64, server_key::String = "", remote_ip::String = "")
        if t.transport === :direct
            # CURVE key + routable IP: use the caller's cached values (the attachment record) when
            # given — each is otherwise an ssh exec, and both were learned at the original spawn.
            # The key is PINNED either way (pinning is a local trust-store write, not a fetch).
            ip = isempty(remote_ip) ? _remote_ip(host) : remote_ip
            if isempty(server_key)
                server_key = _fetch_and_pin_curve!(t, ip, port)
            else
                try; getfield(_kaimon(), :KaimonGate).pin_server!(ip, port, server_key); catch; end
            end
            connect_host, connect_port, connect_stream = ip, port, stream_port
            tunnel = nothing
        else
            ip = ""
            lport, lstream = _free_local_port(), _free_local_port()
            tunnel = open_tunnel(host, [(lport, port), (lstream, stream_port)])
            connect_host, connect_port, connect_stream = "127.0.0.1", lport, lstream
        end
        _rlog("connect: dialing $connect_host:$connect_port (stream $connect_stream, transport=$(t.transport), deadline=$(round(Int, deadline))s)")
        t0 = time(); last = ""; conn = nothing; tries = 0
        firewall_since = 0.0   # :direct — first time the port looked firewalled (SYN dropped) with no refuse/open since
        while time() - t0 < deadline
            tries += 1
            # :direct dials the worker's RAW ip:port. A closed/firewalled port DROPS the SYN, so a bare
            # connect_tcp! blocks ~75 s (the OS TCP timeout) — long enough to look like a hang and blow past
            # `deadline`. Probe first (bounded): dial only when the port is actually open; a booting worker
            # (refused) just retries; a port that stays unreachable is a firewall → fail fast with a clear
            # message instead of waiting out the whole deadline.
            if t.transport === :direct
                _pt = time()
                pr = _probe_tcp(connect_host, connect_port; timeout = _probe_timeout())
                _rlog("  dial try $tries: probe=$pr in $(round(time() - _pt; digits = 2))s (elapsed $(round(time() - t0; digits = 1))s)")
                if pr === :unreachable
                    firewall_since == 0.0 && (firewall_since = time())
                    last = "port $connect_port on $host is not reachable — open $(connect_port)-$(connect_port + 2) in the host's firewall, or use transport=:tunnel"
                    (time() - firewall_since > _firewall_giveup()) && break   # sustained DROP ⇒ firewall, not a slow boot — stop early
                    sleep(0.5); continue
                end
                firewall_since = 0.0                                  # refused/open ⇒ host reachable; normal boot/ready path
                if pr === :refused
                    last = "worker not listening on $connect_port yet (booting)"
                    sleep(0.5); continue
                end
            end
            try
                conn = K.connect_tcp!(_manager(), connect_host, connect_port;
                                      name = "slate-$(host)-$(port)", stream_port = connect_stream,
                                      server_key = server_key, label = k.label)
                _rlog("connect: TCP+CURVE up after $tries tries, $(round(time() - t0; digits = 1))s of dialing (post-connect setup follows before 'connect OK')")
                break
            catch e
                last = sprint(showerror, e)
                # A stale live-status ConnectionManager entry for this endpoint makes connect_tcp!
                # refuse with "Already connected" on EVERY retry (it won't replace a live corpse) —
                # so evict it and let the next iteration build fresh, instead of burning the whole
                # deadline re-dialing into the same corpse. Same eviction the reap path does.
                occursin("Already connected", last) && _evict_worker_conn!(host, port)
                sleep(0.25)
            end
        end
        if conn === nothing
            _rlog("connect FAILED: could not reach worker on $host:$port after $tries tries ($last)")
            tunnel === nothing || (try; close_tunnel(tunnel); catch; end)
        end
        # resolved key/ip ride back so a successful caller can stamp them into the attachment record
        return (conn = conn, tunnel = tunnel, err = last, server_key = server_key, remote_ip = ip)
    end

    t0 = time()
    # After a successful (re)attach, everything that isn't the dial moves OFF the hot path: the
    # state-sidecar write is an ssh exec and catch-up provisioning is ~10s of rsync — neither
    # changes anything about the live session (a running worker never re-includes its payload),
    # so they run in the background while the notebook is already usable. The attachment record
    # gets the dial's resolved key/ip so the NEXT reattach needs zero ssh before its dial.
    # Cold spawn: provision (idempotent) + launch a fresh worker + dial it. Both the last resort (no
    # reusable worker) AND the redirect target when a reused worker is running a stale payload.
    function fresh_spawn()
        provision_remote!(t, parent_project)
        start_sync!(t, parent_project)
        # Remote ports (loopback for :tunnel, 0.0.0.0 for :direct). Pinned when the target names them
        # (needed for :direct behind a firewall); else auto from _next_ports (9100+), floored above the roster.
        port, stream_port =
            (t.transport === :direct && t.port != 0) ?
                # :direct region: t.port is the base_port HINT — take a FREE slot in its stride (roster-aware)
                # so we land in the firewall-opened range, never colliding with warm workers / another notebook.
                (let sl = _direct_port_slots(t.port, 1; roster = (try; list_remote_workers(host); catch; Any[]; end), label = "region cold-spawn on $host")
                     isempty(sl) ? _next_ports(floor = try; _port_floor(host); catch; 0; end) : sl[1]
                 end) :
            t.port != 0 ? (t.port, t.stream_port != 0 ? t.stream_port : t.port + 1) :
                          _next_ports(floor = try; _port_floor(host); catch; 0; end)
        k.port = port; k.stream_port = stream_port
        _launch_worker!(t, port, stream_port; label = k.label, parent = k.parent, threads = k.threads, region = t.region)
        r = dial(port, stream_port; deadline = _dial_deadline_cold())   # covers remote Julia boot + KaimonGate load (~90s)
        r.conn === nothing && error("slate remote: could not reach worker on $host:$port ($(r.err))")
        k.ns_gen += 1   # fresh process ⇒ blank namespace: region dedups keyed on ns_gen re-establish it
        _attach_record!(host, k.label; port = port, stream_port = stream_port,
                        transport = t.transport, server_key = r.server_key, remote_ip = r.remote_ip)
        _rlog("connect OK: attached to worker on $host:$port → notebook now runs on $host")
        return (r.conn, r.tunnel)
    end

    function attached!(r, via::String)
        k.conn = r.conn; k.tunnel = r.tunnel        # so the payload probe can gate-call this worker
        # A reused worker (park/record/probe/adopt) may be running an OLDER payload than the hub — a
        # live worker never re-includes its code, and `tools()` is fixed at boot, so a newly added
        # gate tool can't appear on it. If its boot stamp is behind, reap it and cold-spawn fresh.
        if !_payload_current(k)
            try; reap_remote_worker(host, k.port); catch; end
            try; K.disconnect!(r.conn); catch; end
            r.tunnel === nothing || (try; close_tunnel(r.tunnel); catch; end)
            k.conn = nothing; k.tunnel = nothing
            return fresh_spawn()
        end
        _attach_record!(host, k.label; port = k.port, stream_port = k.stream_port,
                        transport = t.transport, server_key = r.server_key, remote_ip = r.remote_ip)
        start_sync!(t, parent_project)          # non-blocking watcher; heals /src drift from the detached period
        Threads.@spawn begin
            try
                _write_worker_state!(host, k.port, "attached")
                provision_remote!(t, parent_project)   # idempotent; on-disk freshness for the NEXT spawn
            catch e
                _rlog("background catch-up (post-reattach) failed: $(sprint(showerror, e))")
            end
        end
        _rlog("connect OK: reattached via $via to worker-$(k.port) on $host in $(round(Int, (time() - t0) * 1000))ms → notebook now runs on $host")
        return (r.conn, r.tunnel)
    end

    # 0. Parked wire: the live conn + tunnel we deliberately kept across the last close (detach
    #    parks instead of disconnecting — see `park_remote!`). One cheap gate call validates it;
    #    a live answer means reattach touches the network ZERO times before the first eval (a
    #    fresh dial is ~5 RTTs ≈ 370ms on a WAN link, measured). Dead → close, demote to record.
    parked = unpark_remote!(host, k.label)
    if parked !== nothing
        k.port = parked.port; k.stream_port = parked.stream_port
        k.conn = parked.conn; k.tunnel = parked.tunnel
        alive = try
            _tool(k, "__slate_env_info", Dict{String,Any}(); timeout = 5.0)
            true
        catch e
            _rlog("park: parked wire for '$(k.label)' on $host is dead ($(first(sprint(showerror, e), 120))) — demoting to record")
            k.conn = nothing; k.tunnel = nothing
            _close_parked!(parked)
            false
        end
        if alive
            # keep the record's CURVE key/ip (learned at spawn) — attached! rewrites the record,
            # and blanking them would put ssh back on the NEXT cold reattach's path.
            old = _attach_lookup(host, k.label)
            r = (conn = parked.conn, tunnel = parked.tunnel, err = "",
                 server_key = old === nothing ? "" : String(old.server_key),
                 remote_ip = old === nothing ? "" : String(old.remote_ip))
            return attached!(r, "park")
        end
    end

    # 1. Record-first: the hub's own memory of where it left this notebook's worker — no probe,
    #    no ssh at all before the dial itself, whose success IS the validation. Short deadline:
    #    a live worker answers in well under a second; anything else is stale → demote.
    rec = _attach_lookup(host, k.label)
    if rec !== nothing
        k.port = rec.port; k.stream_port = rec.stream_port
        r = dial(rec.port, rec.stream_port; deadline = _dial_deadline_record(),
                 server_key = String(rec.server_key), remote_ip = String(rec.remote_ip))
        r.conn !== nothing && return attached!(r, "record")
        _attach_clear!(host, k.label)
        _rlog("reconnect: attachment record for worker-$(rec.port) was stale — demoting to probe")
    end

    # 2. Probe (reattach-first, provision-second): a LIVE worker for this notebook — detached-
    #    warm, or left by an extension restart / network blip before the record existed — is by
    #    definition already provisioned, so ask the host BEFORE paying the provision pass (~12s
    #    of rsync + env replication even warm, measured). A dead-but-listed worker fails the
    #    dial and falls through to a fresh spawn on new ports (the stale one stays visible in
    #    the roster for manual reap).
    reattach = nothing
    try; reattach = _find_live_worker(host, k.label, k.parent); catch; end
    if reattach !== nothing
        k.port = reattach.port; k.stream_port = reattach.stream_port
        _rlog("reconnect: probe found live worker-$(k.port) on $host (notebook=$(k.label)) — skipping spawn + provision")
        r = dial(k.port, k.stream_port; deadline = _dial_deadline_probe())
        r.conn !== nothing && return attached!(r, "probe")
        # It answered the probe but not a 15s dial: wedged/half-dead (a merely-busy worker answers on its
        # interactive thread). We're about to redo its work on a fresh worker, so REAP the superseded one
        # now rather than leaving it for manual cleanup — a worker that went unresponsive once tends to
        # repeat it, and a lingering ghost only eats the host's memory (and could resurface to fight its
        # replacement). Synchronous + best-effort so no port/file race with the fresh spawn that follows;
        # the kill lands at once if reachable, else when the process thaws.
        _rlog("reconnect: live worker-$(k.port) didn't answer the 15s dial — reaping the superseded worker and cold-spawning fresh")
        try; reap_remote_worker(host, k.port)
        catch e; _rlog("reconnect: reap of superseded worker-$(k.port) failed: $(first(sprint(showerror, e), 100))"); end
    end

    # 2.5 Adoption: no worker of OURS is serving this notebook — but a warm POOL worker with the
    #     right env + transport can become ours: dial it, have it swap in a fresh namespace
    #     (loaded packages + memo store survive — the warmth the pool exists to hold), rewrite
    #     its manifest to this notebook. Any failure falls through to a fresh spawn. The claim
    #     set stops two notebooks opening concurrently from adopting the same worker.
    pool = nothing
    try; pool = _claim_region_worker!(t.region, host); catch e; _rlog("adopt: region scan failed ($(sprint(showerror, e)))"); end
    if pool !== nothing
        k.port = pool.port; k.stream_port = pool.stream_port
        _rlog("adopt: warm worker-$(pool.port) on $host for region '$(t.region)' — adopting for '$(k.label)'")
        r = dial(pool.port, pool.stream_port; deadline = _dial_deadline_probe())
        adopted = false
        if r.conn !== nothing
            adopted = try
                k.conn = r.conn                     # _tool needs the conn on the kernel
                # Stamp the region's data root as we tie this generic pool worker to us — same handoff
                # that re-points PARENT_PROJECT. Empty datadir clears any prior region's root (set-or-clear).
                _tool(k, "__slate_adopt", Dict{String,Any}("parent" => t.project, "datadir" => t.datadir); timeout = 15.0)
                k.ns_gen += 1   # adopt swaps in a fresh namespace ⇒ region dedups must re-establish it
                true
            catch e
                _rlog("adopt: worker-$(pool.port) refused adoption ($(sprint(showerror, e))) — falling back to fresh spawn")
                k.conn = nothing
                try; _kaimon().disconnect!(r.conn); catch; end
                r.tunnel === nothing || (try; close_tunnel(r.tunnel); catch; end)
                false
            end
        else
            _rlog("adopt: pool worker-$(pool.port) didn't answer the 15s dial — falling back to fresh spawn")
        end
        if adopted
            port = k.port; sp = k.stream_port
            Threads.@spawn begin   # identity rewrite + replenish — neither belongs on the hot path
                try
                    _write_worker_manifest!(host, port, [
                        "notebook" => k.label, "parent" => k.parent, "hub" => gethostname(),
                        "transport" => string(t.transport), "project" => t.project,
                        "port" => string(port), "stream_port" => string(sp),
                        "client_pubkey" => _hub_client_pubkey(), "region" => t.region,
                        "spawned" => Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"), "adopted" => "1",
                    ])
                    _write_worker_state!(host, port, "attached")   # no longer warm — exclude from the region's warm count
                catch e
                    _rlog("adopt: manifest rewrite failed ($(sprint(showerror, e)))")
                end
                # claim held until the worker is marked attached — else a concurrent open could rescan
                # the roster mid-rewrite and adopt this worker a second time
                _release_region_claim!(host, port)
                try; region_reconcile!(t.region); catch e; _rlog("region: replenish after adopt failed ($(sprint(showerror, e)))"); end
            end
            return attached!(r, "adopt")
        end
        _release_region_claim!(host, pool.port)
        k.conn = nothing
    end

    # No reusable worker (or every reattach fell through) — spawn a fresh one on new ports.
    return fresh_spawn()
end

# The routable address of `host` for a :direct dial. An ssh alias (~/.ssh/config Host) may not
# resolve as a plain hostname (and ZMQ can't dial it), so ask the remote — over the already-
# authenticated ssh channel — for the address it saw US arrive on: SSH_CONNECTION field 3 (the
# server IP), which is exactly what the hub can dial back. We read it with `printenv` (NOT
# `echo $VAR`): ssh flattens argv and the remote login shell re-parses it, so `${VAR%% *}` there
# both mis-globs and — as seen live — comes back empty; `printenv SSH_CONNECTION` needs no remote-
# shell expansion and survives the flattening. Loopback (ssh over ::1 or 127.*) is forced to IPv4
# 127.0.0.1 because the worker binds 0.0.0.0 (IPv4-only). Falls back to the host string on failure.
function _remote_ip(host::AbstractString)
    h = lowercase(strip(String(host)))
    (h in ("localhost", "127.0.0.1", "::1")) && return "127.0.0.1"
    ok, out = _ssh_capture(host, `printenv SSH_CONNECTION`)
    if ok
        # SSH_CONNECTION = "<client_ip> <client_port> <server_ip> <server_port>"
        parts = split(strip(out))
        if length(parts) >= 3
            ip = String(parts[3])
            (ip == "::1" || startswith(ip, "127.")) && return "127.0.0.1"
            return ip
        end
    end
    return String(host)
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

# Tear down a remote kernel's off-machine resources: close the supervised tunnel and stop the
# /src sync — then either DETACH (default) or KILL the worker itself. Detach keeps the process
# running warm (namespace + loaded packages + memo store survive) and flips its state sidecar to
# `idle`, so a later open of the same notebook REATTACHES instantly (`_find_live_worker`) instead
# of re-paying the ~90s boot; this is what makes "close the notebook / stop the hub" cheap to
# undo. Kill (an explicit restart, the preflight probe, `reap_remote_worker`) is the full
# cleanup: pkill + drop the script/manifest/state so nothing lingers in the registry (the .log
# is kept for post-mortem). Called from `_kill_worker!`.
function teardown_remote!(k; kill::Bool = false)
    if k.tunnel !== nothing
        try; close_tunnel(k.tunnel); catch; end
        k.tunnel = nothing
    end
    t = k.target
    if t isa RemoteTarget
        try; stop_sync!(t); catch; end
        if k.port == 0                # nothing was spawned — only local resources to release
            _rlog("teardown: closing tunnel + sync on $(t.ssh_host) (no worker was spawned)")
        elseif kill
            # Only kill a worker we actually spawned (port assigned). pkill exits nonzero when nothing
            # matches — a normal outcome, not a failure — so route it through the quiet predicate, not _ssh_ok.
            _rlog("teardown: closing tunnel + sync, killing remote worker-$(k.port).jl on $(t.ssh_host)")
            try; _ssh_test(t.ssh_host, `pkill -f $("worker-" * string(k.port) * ".jl")`); catch; end
            try; _ssh_test(t.ssh_host, `rm -f $("$_REMOTE_WORKER/worker-$(k.port).jl") $("$_REMOTE_WORKER/worker-$(k.port).json") $("$_REMOTE_WORKER/worker-$(k.port).state") $("$_REMOTE_WORKER/worker-$(k.port).stats")`); catch; end
            try; _attach_clear!(t.ssh_host, k.label); catch; end   # a killed worker must not be re-dialed from the record
            try; _evict_parked!(t.ssh_host; label = k.label, port = k.port); catch; end   # …nor via a parked wire
            try; _evict_data_tunnels!(t.ssh_host; port = k.port + 2); catch; end
        else
            _rlog("teardown: detaching from worker-$(k.port) on $(t.ssh_host) — worker stays warm (state=idle)")
            _write_worker_state!(t.ssh_host, k.port, "idle")
        end
    end
    return nothing
end

# ── Preflight: test + prime a remote host ─────────────────────────────────────────
# An explicit, reported dry-run of the ENTIRE remote path — so you can validate (and warm) a host
# before pinning a notebook to it. Runs the REAL machinery (provision → spawn → tunnel/CURVE →
# connect → round-trip eval) then tears it down, recording every step (timed, pass/fail, captured
# detail) to remote.log and returning a structured checklist for the UI's "Test connection".
struct PreflightStep
    name::String
    status::String    # "ok" | "fail" | "skip"
    detail::String
    ms::Int
end
_pfdict(s::PreflightStep) = Dict{String,Any}("name" => s.name, "status" => s.status, "detail" => s.detail, "ms" => s.ms)

# Run one step: time it, catch throws as failures, log + collect, and (if given) stream it via `on_step`
# the moment it completes — so a caller can report progress live instead of waiting for the whole run.
# `f` is first so the `do`-block call form `_pfstep!(steps, name, on_step) do … end` binds it correctly.
function _pfstep!(f, steps::Vector{PreflightStep}, name::AbstractString, on_step = nothing)
    on_step === nothing || on_step(PreflightStep(String(name), "run", "", 0))   # announce "in progress"
    t0 = time()
    status = "fail"; detail = ""
    try
        (status, detail) = f()
    catch e
        status = "fail"; detail = sprint(showerror, e)
    end
    step = PreflightStep(String(name), String(status), String(detail), round(Int, (time() - t0) * 1000))
    push!(steps, step)
    _rlog("preflight [$(step.status)] $(step.name) ($(step.ms)ms)" * (isempty(step.detail) ? "" : " — " * first(step.detail, 300)))
    on_step === nothing || on_step(step)
    return step
end

function _pfresult(host, transport, steps::Vector{PreflightStep})
    ok = all(s -> s.status != "fail", steps)
    _rlog("preflight DONE $host → $(ok ? "ALL OK" : "FAILED")")
    return Dict{String,Any}("host" => String(host), "transport" => String(transport),
                            "ok" => ok, "steps" => [_pfdict(s) for s in steps])
end

"""
    preflight_remote(host; transport=:tunnel, on_step=nothing) -> Dict

Test + prime `host`: ssh reachability, Julia presence (+version), env provisioning, KaimonGate load,
CURVE key (for `:direct`), then a real spawn → connect → round-trip eval → clean teardown. Returns
`Dict("host","transport","ok",steps=>[{name,status,detail,ms}…])`. Idempotent and self-cleaning: it
leaves the primed env behind (so the first real run is fast) but no worker or tunnel running.
`on_step(::PreflightStep)`, if given, is called as each step STARTS (status "run") and COMPLETES — so
the SSE endpoint can stream progress live instead of blocking for the whole (minutes-long) run.
"""
function preflight_remote(host::AbstractString; transport::Symbol = :tunnel, on_step = nothing)
    host = String(host)
    t = RemoteTarget(host; transport = transport, project = "~/.cache/kaimonslate/remote/__preflight__")
    steps = PreflightStep[]
    _rlog("═══ PREFLIGHT: $host (transport=$transport) ═══")

    s = _pfstep!(steps, "SSH reachable", on_step) do
        _ssh_test(host, `true`) ? ("ok", "key-based ssh to '$host' works") :
            ("fail", "cannot ssh to '$host' in BatchMode — check ~/.ssh/config Host + key auth (try `ssh $host` in a terminal)")
    end
    s.status == "ok" || return _pfresult(host, transport, steps)

    s = _pfstep!(steps, "Julia present", on_step) do
        _ensure_julia!(host) ||
            return ("fail", "no usable `julia` on '$host' and auto-install skipped/failed (Windows, or juliaup error) — install Julia (juliaup) manually")
        okj, out = _ssh_capture(host, `$(_julia_sh("julia --version"))`)
        okj ? ("ok", strip(out)) : ("fail", "`julia` resolved but `julia --version` failed on '$host'")
    end
    s.status == "ok" || return _pfresult(host, transport, steps)

    s = _pfstep!(steps, "Provision env", on_step) do
        provision_remote!(t, "")   # detached: ships worker payload + builds/primes the KaimonGate env
        ("ok", "worker payload + KaimonGate env ready under ~/.cache/kaimonslate")
    end
    s.status == "ok" || return _pfresult(host, transport, steps)

    _pfstep!(steps, "KaimonGate loads", on_step) do
        okk, out = _ssh_julia!(host, """
        insert!(LOAD_PATH, 1, joinpath(homedir(), raw"$_REMOTE_KGATE_ENV"))
        import KaimonGate
        print("KaimonGate v", pkgversion(KaimonGate))
        """, "probe KaimonGate on $host")
        okk ? ("ok", strip(out)) : ("fail", "KaimonGate failed to load in the remote env (see remote.log)")
    end

    if transport === :direct
        _pfstep!(steps, "CURVE server key", on_step) do
            okc, out = _ssh_capture(host, `head -n1 $_REMOTE_KEY_PATH`)
            (okc && !isempty(strip(out))) ? ("ok", "server pubkey present ($(first(strip(out), 12))…)") :
                ("fail", "no CURVE server key at $_REMOTE_KEY_PATH — run a KaimonGate serve once on '$host' to generate it, or use transport=tunnel")
        end
    else
        _pfstep!(steps, "CURVE server key", on_step) do
            ("skip", "n/a for :tunnel — SSH provides the encryption")
        end
    end

    # Capstone — a real spawn → connect (tunnel/CURVE) → round-trip eval → teardown. Proves the whole
    # transport + connection + eval loop end-to-end, then leaves nothing running.
    _pfstep!(steps, "Spawn + connect + eval", on_step) do
        k = GateKernel("~/.cache/kaimonslate/remote/__preflight__";
                       parent = "", threads = "", target = t, label = "preflight")
        rep = parse_report("# preflight"; id = "__preflight__", title = "preflight")
        try
            out = eval_capture(k, rep,
                "string(gethostname(), \" · \", Sys.KERNEL, \" · julia \", VERSION, \" · pid \", getpid())",
                "preflight")
            out.exception !== nothing ? ("fail", "remote eval errored: " * out.exception) :
                ("ok", "round-trip OK → " * strip(replace(out.value_repr, "\"" => "")))
        finally
            try; shutdown!(k; kill_remote = true); catch; end   # probe worker is disposable — kill, don't idle
        end
    end

    return _pfresult(host, transport, steps)
end

# ── Remote-worker registry: self-describing workers + lifecycle ───────────────────────────────────
# Every spawned worker leaves a manifest on the host (`worker-<port>.json`) recording WHO spawned it and
# for WHAT — so a worker can answer "am I still wanted?" and a human can see, list, reconnect to, or
# reap workers without guessing. "Last computation" is read cheaply from the worker LOG's mtime (the
# worker writes to it on every eval), so no worker-side bookkeeping is needed. Nothing is ever killed
# automatically: `reap_remote_worker` is explicit, so a worker holding useful results is safe.

# Write the manifest for a just-launched worker (flat JSON, built by hand → no JSON dep here; fed over
# ssh stdin so the braces/quotes never touch argv). Best-effort.
function _write_worker_manifest!(host, port::Int, fields)
    esc(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => " ", "\r" => " ")
    body = "{" * join(["\"$(esc(k))\":\"$(esc(v))\"" for (k, v) in fields], ",") * "}"
    path = "$_REMOTE_WORKER/worker-$port.json"
    try
        run(pipeline(_ssh(host, `$("cat > " * path)`); stdin = IOBuffer(body), stdout = devnull, stderr = devnull))
    catch e
        _rlog("manifest: could not write $host:$path ($(sprint(showerror, e)))")
    end
    return nothing
end

# Lifecycle-state sidecar (`worker-<port>.state`): `attached`/`idle` + a unix timestamp. Kept
# SEPARATE from the manifest so flipping state on attach/detach is one tiny write, and the
# manifest stays immutable identity (who spawned it, for what) after spawn. Advisory: a hub crash
# leaves a stale `attached`, so consumers must treat it as a hint, never a lock. Best-effort.
function _write_worker_state!(host, port::Int, state::AbstractString)
    body = string(state, " ", round(Int, time()))
    path = "$_REMOTE_WORKER/worker-$port.state"
    try
        run(pipeline(_ssh(host, `$("cat > " * path)`); stdin = IOBuffer(body), stdout = devnull, stderr = devnull))
    catch e
        _rlog("state: could not write $host:$path ($(sprint(showerror, e)))")
    end
    return nothing
end

# ── Memo push over the blob data channel (worker gate port + 2) ─────────────────────────────
# "Your session follows you": ship the LOCAL memo entries for the given server memo-keys to a
# remote worker's CAS, so its cells RESTORE instead of recomputing. Manifest-first dedup ('H'
# query → only missing blobs move), chunked puts with worker-side sha verify, manifests sent
# LAST (never referencing blobs that aren't there). Local store scanned with the same regex
# discipline as the worker manifests (no TOML dep hub-side); fullkeys transfer verbatim —
# host-portable digests (see worker.jl `_src_digest`) are what make them match over there.
# v2 wire: a 'V' probe picks the framing — a v2 server gets multipart 'p' puts whose payload
# frame is a ZERO-COPY message over an mmap of the blob (zmq_msg_init_data: libzmq reads pages
# straight from the page cache — no read()/vcat copies hub-side); a v1 server keeps getting the
# single-frame copy-chunk 'P'. `server_key` (Z85, the gate's pinned CURVE key — the data socket
# serves with the SAME key) encrypts the channel on :direct; tunnel passes "" (SSH encrypts).
# ── Transfer tuning (Settings panel / slate.json / env) ─────────────────────────────────────
# Bytes per REQ/REP round-trip. NOTE the blob channel is its own socket (own ssh proc under
# :tunnel), so chunk size does NOT protect cell results — that isolation is structural — and
# TCP interleaves competing flows per-packet either way. What it actually governs is the
# round-trip granularity: the per-chunk recv timeout (a huge chunk on a slow link can outlive
# rcvtimeo and fail a push that was making progress), how promptly an abort can land, and the
# worker's per-frame buffer. Bigger chunks amortize RTT (throughput on fat links); smaller
# ones bound per-chunk exposure on thin ones. Panel setting (the Ref, persisted to
# slate.json) wins; KAIMONSLATE_BLOB_CHUNK_MB env next; default 8 MiB; min 64 KB.
const BLOB_CHUNK_MB = Ref{Float64}(0.0)   # 0 = unset (env / default applies)
_blob_chunk() = max(65_536, round(Int, 2^20 *
    (BLOB_CHUNK_MB[] > 0 ? BLOB_CHUNK_MB[] :
     something(tryparse(Float64, get(ENV, "KAIMONSLATE_BLOB_CHUNK_MB", "")), 8.0))))

# Hard per-entry ceiling (seconds) for the BOOT-window memo carry — the "never stall a notebook
# open" bound the cost gate enforces regardless of how expensive an entry claims to be to
# recompute. Same precedence: panel Ref → KAIMONSLATE_CARRY_MAX_S env → 30s default.
const CARRY_MAX_S = Ref{Float64}(0.0)     # 0 = unset (env / default applies)
_carry_ceiling_s() = CARRY_MAX_S[] > 0 ? CARRY_MAX_S[] :
    something(tryparse(Float64, get(ENV, "KAIMONSLATE_CARRY_MAX_S", "")), 30.0)

# Region-boundary transfer preview threshold (seconds): a cell whose pending boundary transfer
# is estimated to take longer than this ERRORS with the preview (what/size/ETA) on its first
# run; running the cell again proceeds — approve-by-rerun. 60s default; 0 disables previews.
# Same precedence tiers as the other transfer knobs.
const XFER_CONFIRM_S = Ref{Float64}(-1.0)  # <0 = unset (env / default applies); 0 = disabled
_xfer_confirm_s() = XFER_CONFIRM_S[] >= 0 ? XFER_CONFIRM_S[] :
    something(tryparse(Float64, get(ENV, "KAIMONSLATE_XFER_CONFIRM_S", "")), 60.0)

# ── Per-host upstream-bandwidth memory (the transfer-vs-recompute input) ─────────────────────
# Every push measures its own rate over 8 MiB chunks and stamps it here (EMA so one anomalous
# push doesn't own the estimate). Host-level, not per-worker — the link is the physics. The
# carry's cost gate reads it; unknown hosts assume a conservative 1 MB/s (biases the FIRST
# carry toward recompute — a boot window must never stall on an unmeasured link).
_bw_path(host_ip) = joinpath(_slate_cache_dir(), "bw", replace(String(host_ip), r"[^A-Za-z0-9._-]" => "_") * ".json")
function _bw_get(host_ip)
    p = _bw_path(host_ip)
    isfile(p) || return 0.0
    v = tryparse(Float64, _manifest_get(try; read(p, String); catch; return 0.0; end, "up_bps"))
    something(v, 0.0)
end
function _bw_note!(host_ip, bps::Float64)
    bps > 0 || return nothing
    old = _bw_get(host_ip)
    ema = old > 0 ? 0.7 * old + 0.3 * bps : bps
    try
        mkpath(dirname(_bw_path(host_ip)))
        write(_bw_path(host_ip), "{\"up_bps\":\"$(round(ema; digits = 1))\",\"ts\":\"$(round(Int, time()))\"}")
    catch
    end
    return nothing
end

# ── Per-PAIR peer bandwidth — the DIRECT (worker→worker) transfer rate ────────────────────────
# Distinct from the hub uplink (`_bw_get`): a direct pull never touches the hub's link, so pricing
# it at the uplink (often a laptop's slow SSH) trips a spurious "run the cell again" on a move that's
# actually seconds. Recorded from completed direct pulls, keyed per (src_host → dst_host); co-located
# peers share the same host (loopback rate). Unmeasured ⇒ a FAST default: direct is fast, so bias
# AWAY from a needless confirm (the opposite of the uplink's conservative 1 MB/s recompute-bias).
# The unmeasured default is `_peer_bw_default()` (slate.json `peer_bw_mbps` / KAIMONSLATE_PEER_BW_MBPS; 30 MB/s).
_peer_bw_path(a, b) = joinpath(_slate_cache_dir(), "bw", "peer",
    replace("$(a)__$(b)", r"[^A-Za-z0-9._-]" => "_") * ".json")
function _peer_bw_get(a, b)
    p = _peer_bw_path(a, b); isfile(p) || return 0.0
    something(tryparse(Float64, _manifest_get(try; read(p, String); catch; return 0.0; end, "bps")), 0.0)
end
function _peer_bw_note!(a, b, bps::Float64)
    bps > 0 || return nothing
    old = _peer_bw_get(a, b)
    ema = old > 0 ? 0.7 * old + 0.3 * bps : bps
    try
        mkpath(dirname(_peer_bw_path(a, b)))
        write(_peer_bw_path(a, b), "{\"bps\":\"$(round(ema; digits = 1))\",\"ts\":\"$(round(Int, time()))\"}")
    catch
    end
    return nothing
end

# The bandwidth the confirm gate should price a transfer at: the measured PEER rate when it will actually
# go direct (ask the SAME resolver the transfer will use — its probe verdict is cached, so this is the
# real path, not the `_direct_viable` proxy that mis-priced a :tunnel source's reachable peer as a slow
# hub relay), else the hub uplink to the remote side.
function _plan_rate(src_k, dst_k, mode::Symbol)
    if (mode === :direct || mode === :auto) && _resolve_peer_route(src_k, dst_k).kind === :direct
        pb = _peer_bw_get(src_k.target.ssh_host, dst_k.target.ssh_host)
        return pb > 0 ? pb : _peer_bw_default()
    end
    host = dst_k.target isa RemoteTarget ? dst_k.target.ssh_host :
           (src_k.target isa RemoteTarget ? src_k.target.ssh_host : "")
    return _bw_get(host)                        # 0 ⇒ the gate applies its own conservative floor
end

function push_memo_blobs!(host_ip::AbstractString, data_port::Int, srckeys::Vector{String};
                          timeout_ms::Int = _blob_chunk_timeout_ms(), server_key::AbstractString = "",
                          max_transfer_s::Float64 = 0.0, bw_key::AbstractString = host_ip)
    kg = getfield(_kaimon(), :KaimonGate)
    Z = kg.ZMQ
    root = joinpath(_slate_cache_dir(), "memo")   # mirrors worker.jl _memo_dir
    mdir = joinpath(root, "manifests")
    isdir(mdir) || return "no local memo store"
    keyset = Set(srckeys)
    picked = Tuple{String,String}[]                    # (fullkey, manifest toml)
    for f in readdir(mdir; join = true)
        endswith(f, ".toml") || continue
        s = try; read(f, String); catch; continue; end
        m = match(r"srckey\s*=\s*\"([0-9a-f]+)\"", s)
        (m !== nothing && String(m.captures[1]) in keyset) || continue
        push!(picked, (replace(basename(f), ".toml" => ""), s))
    end
    isempty(picked) && return "no matching local entries"
    # ── Cost gate (the boot carry sets max_transfer_s > 0; the explicit sync_memo tool doesn't):
    # an entry ships only when moving its bytes is cheaper than recomputing it — est. transfer
    # (entry bytes / measured host bandwidth, 1 MB/s floor when unmeasured) vs the manifest's
    # recorded compute cost `ms` (×2 slack, 0.5s floor so trivial entries always ship), capped
    # by max_transfer_s so no single entry can stall a notebook open. Skipping is SAFE: the cell
    # recomputes remotely and re-stores under the same key — correctness never depends on the
    # carry, only warm-start time does. `sync_memo` remains the unconditional escape hatch.
    skipped = String[]
    if max_transfer_s > 0
        bw = max(_bw_get(bw_key), 1.0e6)
        keep = Tuple{String,String}[]
        for (k, s) in picked
            bytes = sum(parse(Int, m.captures[1]) for m in eachmatch(r"bytes\s*=\s*(\d+)", s); init = 0)
            msm = match(r"(?m)^ms\s*=\s*([0-9.]+)", s)
            ms = msm === nothing ? 0.0 : something(tryparse(Float64, msm.captures[1]), 0.0)
            if !_carry_should_ship(bytes, ms, bw, max_transfer_s)
                push!(skipped, "$(first(k, 8))… ($(round(Int, bytes / 2^20))MB ≈ $(round(bytes / bw; digits = 1))s transfer vs $(round(ms; digits = 0))ms recompute)")
                continue
            end
            push!(keep, (k, s))
        end
        picked = keep
        isempty(skipped) || _rlog("memo push: cost gate skipped $(length(skipped)) entr$(length(skipped) == 1 ? "y" : "ies") — recompute is cheaper (bw $(round(bw / 1e6; digits = 1)) MB/s): " * join(skipped, "; "))
        isempty(picked) && return "all $(length(skipped)) entries cheaper to recompute (skipped)"
    end
    hashes = String[]
    for (_, s) in picked, m in eachmatch(r"blob\s*=\s*\"([0-9a-f]{64})\"", s)
        push!(hashes, String(m.captures[1]))
    end
    unique!(hashes)
    sock = Z.Socket(Z.REQ)
    try
        # Bounded I/O: this also runs on the notebook-boot path (memo carry), where an unbound
        # REQ recv against a dead blob channel would hang the open forever. On expiry recv
        # throws (EAGAIN) → the caller's catch downgrades to "cells recompute instead".
        sock.rcvtimeo = timeout_ms
        sock.sndtimeo = timeout_ms
        if !isempty(server_key)
            cpub, csec = kg._load_or_create_client_keypair()   # the key the worker allow-lists
            kg.make_curve_client!(sock, String(server_key), cpub, csec)
        end
        Z.connect(sock, "tcp://$host_ip:$data_port")
        req(frame) = (Z.send(sock, frame); String(copy(Z.recv(sock))))
        # Framing probe: v2 servers answer "2" and take multipart zero-copy 'p'; a v1 server
        # answers "err: unknown cmd" (single-frame command — safe) and keeps the copy path.
        # This matters for WARM workers: a reattached worker may still RUN v1 code even though
        # its on-disk payload was re-provisioned.
        v2 = req(UInt8['V']) == "2"
        t0 = time()
        want = want_hashes(req, hashes)
        sent = 0; nbytes = 0
        for h in want
            p = joinpath(root, "blobs", "sha256", h[1:2], String(h))
            isfile(p) || (_rlog("memo push: missing local blob $h — skipped"); continue)
            nbytes += _send_blob!(Z, sock, req, p, String(h), v2)
            sent += 1
        end
        for (k, s) in picked
            r = req(vcat(UInt8['M'], Vector{UInt8}(codeunits(k * "\n" * s))))
            startswith(r, "err") && error("memo push manifest $k: $r")
        end
        deduped = length(hashes) - length(want)
        elapsed = time() - t0
        rate = (nbytes > 0 && elapsed > 0) ? " @ $(round(nbytes / elapsed / 2^20; digits = 1)) MB/s" : ""
        # Feed the cost gate: remember this host's measured upstream rate (only from pushes big
        # enough that chunk round-trips, not RTT, dominated the clock).
        nbytes > 4 << 20 && elapsed > 0 && _bw_note!(bw_key, nbytes / elapsed)
        msg = "pushed $(sent) blobs ($(nbytes) bytes in $(round(elapsed; digits = 1))s$rate, $(v2 ? "v2 zero-copy" : "v1 copy")) + $(length(picked)) manifests, $(deduped) blobs deduped" *
              (isempty(skipped) ? "" : "; $(length(skipped)) skipped (recompute cheaper)")
        _rlog("memo push → $host_ip:$data_port ($(isempty(server_key) ? "plaintext" : "CURVE")) — $msg")
        return msg
    finally
        try; Z.close(sock); catch; end
    end
end

# The dedup query, extracted so the put loop reads clean: ask the server which of `hashes`
# it lacks. (Empty reply string → nothing to send.)
want_hashes(req, hashes) =
    split(req(vcat(UInt8['H'], Vector{UInt8}(codeunits(join(hashes, ","))))), ","; keepempty = false)

# Ship ONE blob file over an already-connected data-channel REQ socket — v2 = multipart 'p'
# with a zero-copy payload frame over an mmap (libzmq sends straight out of the page cache;
# the Message's origin keeps the mmap alive until the frame is out — REQ/REP: by the reply);
# v1 = single-frame copy-chunk 'P'. Returns the bytes sent. Shared by the memo push and the
# region runner's single-binding transfers.
function _send_blob!(Z, sock, req, path::AbstractString, h::String, v2::Bool; on_progress = nothing)
    sz = filesize(path)
    nbytes = 0
    tick() = on_progress === nothing || on_progress(nbytes, sz)
    if v2 && sz > 0
        mm = Mmap.mmap(path, Vector{UInt8}, sz)
        off = 0
        chunk = _blob_chunk()
        while off < sz
            n = min(chunk, sz - off)
            last = off + n >= sz
            hdr = vcat(UInt8['p'], Vector{UInt8}(codeunits(h)), UInt8[last ? 0x01 : 0x00])
            Z.send(sock, hdr; more = true)
            Z.send(sock, Z.Message(mm, pointer(mm) + off, n))
            r = String(copy(Z.recv(sock)))
            startswith(r, "err") && error("blob push $h: $r")
            nbytes += n; off += n
            tick()
        end
    else
        open(path, "r") do io
            while true
                chunk = read(io, 1 << 20)
                last = eof(io)
                r = req(vcat(UInt8['P'], Vector{UInt8}(codeunits(h)), UInt8[last ? 0x01 : 0x00], chunk))
                startswith(r, "err") && error("blob push $h: $r")
                nbytes += length(chunk)
                tick()
                last && break
            end
        end
    end
    return nbytes
end

"""
    push_blob!(host_ip, data_port, hash; server_key="", timeout_ms=20_000) -> Int

Ship ONE blob from the LOCAL CAS to a worker's store over its data channel (dedup-aware: the
'H' query makes an already-present blob cost one round-trip). The region runner's local→remote
half; `pull_blob!` is the reverse. Returns bytes actually sent (0 = deduped).
"""
function push_blob!(host_ip::AbstractString, data_port::Int, hash::AbstractString;
                    server_key::AbstractString = "", timeout_ms::Int = _blob_chunk_timeout_ms(),
                    on_plan = nothing, meta = nothing, on_progress = nothing)
    root = joinpath(_slate_cache_dir(), "memo")
    p = joinpath(root, "blobs", "sha256", hash[1:2], String(hash))
    isfile(p) || error("push_blob!: no local blob $hash")
    kg = getfield(_kaimon(), :KaimonGate)
    Z = kg.ZMQ
    sock = Z.Socket(Z.REQ)
    try
        sock.rcvtimeo = timeout_ms; sock.sndtimeo = timeout_ms
        if !isempty(server_key)
            cpub, csec = kg._load_or_create_client_keypair()
            kg.make_curve_client!(sock, String(server_key), cpub, csec)
        end
        Z.connect(sock, "tcp://$host_ip:$data_port")
        req(frame) = (Z.send(sock, frame); String(copy(Z.recv(sock))))
        v2 = req(UInt8['V']) == "2"
        want = want_hashes(req, [String(hash)])
        if isempty(want)                                   # already there
            on_plan === nothing || on_plan(0, meta)
            return 0
        end
        on_plan === nothing || on_plan(Int(filesize(p)), meta)   # exact bytes; may throw (preview gate)
        return _send_blob!(Z, sock, req, p, String(hash), v2; on_progress = on_progress)
    finally
        try; Z.close(sock); catch; end
    end
end

"""
    pull_blob!(host_ip, data_port, hash; server_key="", timeout_ms=20_000) -> Int

PULL one content-addressed blob from a worker's store over the data channel ('G' chunks) into
the LOCAL memo CAS — the reverse of `push_memo_blobs!`; how remote results flow back (region
runner: a remote cell's writes that local cells read). Streams into a tmp file, sha-verifies
against the address, atomic-renames — a truncated/corrupt transfer never lands. Dedup first:
an already-present blob costs nothing. Returns bytes moved over the network (0 = deduped).
"""
function pull_blob!(host_ip::AbstractString, data_port::Int, hash::AbstractString;
                    server_key::AbstractString = "", timeout_ms::Int = _blob_chunk_timeout_ms(), on_progress = nothing)
    root = joinpath(_slate_cache_dir(), "memo")
    dest = joinpath(root, "blobs", "sha256", hash[1:2], String(hash))
    isfile(dest) && return 0                              # dedup: already here — nothing moved
    kg = getfield(_kaimon(), :KaimonGate)
    Z = kg.ZMQ
    sock = Z.Socket(Z.REQ)
    try
        sock.rcvtimeo = timeout_ms; sock.sndtimeo = timeout_ms
        if !isempty(server_key)
            cpub, csec = kg._load_or_create_client_keypair()
            kg.make_curve_client!(sock, String(server_key), cpub, csec)
        end
        Z.connect(sock, "tcp://$host_ip:$data_port")
        chunk = _blob_chunk()
        mkpath(dirname(dest))
        tmp = tempname(dirname(dest))
        total = -1; off = 0
        open(tmp, "w") do io
            while total < 0 || off < total
                Z.send(sock, "G$(hash):$(off):$(chunk)")
                frames = Z.recv_multipart(sock)
                meta = String(copy(frames[1]))
                startswith(meta, "err") && error("pull $hash: $meta")
                total = parse(Int, split(meta)[2])
                total == 0 && break
                payload = frames[2]
                GC.@preserve payload unsafe_write(io, pointer(payload), length(payload))
                off += length(payload)
                on_progress === nothing || on_progress(off, total)
                length(payload) == 0 && off < total && error("pull $hash: empty chunk at $off/$total")
            end
        end
        got = bytes2hex(open(_SHA.sha256, tmp))
        got == String(hash) || (rm(tmp; force = true); error("pull $hash: hash mismatch (got $got)"))
        mv(tmp, dest; force = true)
        return total
    finally
        try; Z.close(sock); catch; end
    end
end

# ── Transfer-control plane client (TRANSFER_CONTROL_PLAN Mode A) ───────────────────────────────────────
# One REQ/REP round-trip to a worker's blob channel carrying a NON-data control verb (`X` transfer request
# / `S` status) — reuses the exact CURVE+REQ setup as pull_blob!, so it rides the same reachability + auth
# the relay already has (no new port/socket). Returns the reply string.
function _xfer_ctl_call(host_ip::AbstractString, data_port::Int, msg::AbstractString;
                        server_key::AbstractString = "", timeout_ms::Int = 15_000)
    kg = getfield(_kaimon(), :KaimonGate); Z = kg.ZMQ
    sock = Z.Socket(Z.REQ)
    try
        sock.rcvtimeo = timeout_ms; sock.sndtimeo = timeout_ms
        if !isempty(server_key)
            cpub, csec = kg._load_or_create_client_keypair()
            kg.make_curve_client!(sock, String(server_key), cpub, csec)
        end
        Z.connect(sock, "tcp://$host_ip:$data_port")
        Z.send(sock, String(msg))
        return String(Z.recv(sock))
    finally
        try; Z.close(sock); catch; end
    end
end

# Hub-side view of the transfers it's orchestrating (Mode A), for the `transfers` introspection tool: a
# live row per pull with dst←src, size, bytes-so-far, throughput, route. Finished rows linger briefly.
mutable struct XferView
    dst::String; src::String; name::String; via::String
    done::Int; total::Int; started::Float64; finished::Float64; err::String
end
const _XFER_VIEWS = Dict{Int,XferView}()
const _XFER_VIEW_LOCK = ReentrantLock()
const _XFER_VIEW_SEQ  = Threads.Atomic{Int}(0)
_xfer_view_prune!() = lock(_XFER_VIEW_LOCK) do
    for (k, v) in collect(_XFER_VIEWS)
        (v.finished > 0 && time() - v.finished > 60) && delete!(_XFER_VIEWS, k)
    end
end
# Every transfer the hub is running or recently ran (active first, then recent), for the tool.
function xfer_views()
    lock(_XFER_VIEW_LOCK) do
        sort(collect(values(_XFER_VIEWS)); by = v -> (v.finished > 0, -v.started))
    end
end

# Retained progress TRACE of a recent transfer for the summary dashboard: metadata + a (t, cumulative-
# bytes) series sampled at each control poll (~5 Hz), from which instantaneous throughput is derived. Kept
# in a capped ring (NOT the 60 s-pruned live view) so the dashboard's timelines/distributions have history.
struct XferTrace
    src::String; dst::String; name::String; via::String
    started::Float64; finished::Float64; total::Int; err::String
    ts::Vector{Float64}     # sample wall-times
    bs::Vector{Int}         # cumulative bytes at each ts
end
const _XFER_TRACES = XferTrace[]
# Ring depth — GLOBAL across every notebook's transfers (the dashboard filters to its own regions), so a
# busy notebook shouldn't evict another's history. Env-tunable for long observation runs; loops on pop so
# a lowered cap trims immediately.
_xfer_trace_cap() = max(1, something(tryparse(Int, get(ENV, "KAIMONSLATE_XFER_TRACE_CAP", "")), 4000))
const _XFER_TRACE_LOCK = ReentrantLock()
function _xfer_trace_push!(meta, started, total, ts, bs, err)
    meta === nothing && return
    lock(_XFER_TRACE_LOCK) do
        push!(_XFER_TRACES, XferTrace(String(meta.src), String(meta.dst), String(meta.name), String(meta.via),
                                      started, time(), total, String(err), copy(ts), copy(bs)))
        cap = _xfer_trace_cap()
        while length(_XFER_TRACES) > cap; popfirst!(_XFER_TRACES); end
    end
end
xfer_traces() = lock(_XFER_TRACE_LOCK) do; copy(_XFER_TRACES); end

# Drive a peer pull on `dst_k` OVER ITS BLOB CHANNEL (not the gate): send the `X` request to the dst's
# blob endpoint (hub-vantage — reuses the relay reach), then poll `S` to completion. The actual pull runs
# on the dst's dedicated executor task, so the gate loop never blocks. `spec` is the newline-framed body
# after the verb (see `_xfer_control`); `meta` (dst/src/name/via) drives the `transfers` view. Returns
# (bytes, via). THROWS on failure (caller decides fallback).
function _xfer_ctl_pull(dst_k, spec::AbstractString; timeout::Float64 = _blob_xfer_timeout(), meta = nothing)
    vid = Threads.atomic_add!(_XFER_VIEW_SEQ, 1)
    t0 = time()
    trT = Float64[]; trB = Int[]; total = -1; traced = false   # per-poll progress series → dashboard trace
    fin = err -> (traced || (traced = true; _xfer_trace_push!(meta, t0, total, trT, trB, err)))
    if meta !== nothing
        _xfer_view_prune!()
        lock(_XFER_VIEW_LOCK) do
            _XFER_VIEWS[vid] = XferView(String(meta.dst), String(meta.src), String(meta.name),
                                        String(meta.via), 0, -1, t0, 0.0, "")
        end
    end
    _upd!(f) = meta === nothing || lock(_XFER_VIEW_LOCK) do; v = get(_XFER_VIEWS, vid, nothing); v === nothing || f(v); end
    try
        ep = _data_endpoint!(dst_k.target, dst_k)          # the DST's blob channel, reachable from the hub
        jid = _xfer_ctl_call(ep.ip, ep.port, "X" * spec; server_key = ep.server_key)
        (isempty(jid) || startswith(jid, "err")) && error("xfer request rejected: $jid")
        deadline = time() + timeout; polls = 0
        while time() < deadline
            st = _xfer_ctl_call(ep.ip, ep.port, "S" * jid; server_key = ep.server_key)
            if startswith(st, "running")
                p = split(st)
                if length(p) >= 3
                    d = something(tryparse(Int, p[2]), 0); total = something(tryparse(Int, p[3]), total)
                    _upd!(v -> (v.done = d; v.total = total))
                    push!(trT, time()); push!(trB, d)      # granular sample for the throughput trace
                end
            elseif startswith(st, "done ")
                p = split(st); b = something(tryparse(Int, p[2]), 0); total = b
                push!(trT, time()); push!(trB, b)
                _upd!(v -> (v.done = b; v.total = b; v.finished = time()))
                fin("")
                return (b, length(p) >= 3 ? String(p[3]) : "direct")
            elseif startswith(st, "err")
                _upd!(v -> (v.finished = time(); v.err = String(st)))
                fin(String(st))
                error("xfer $jid: $st")
            end
            polls += 1                                      # adaptive: quick early polls catch small/fast
            sleep(polls < 8 ? 0.025 : polls < 20 ? 0.08 : 0.2)   # transfers; back off for long ones
        end
        _upd!(v -> (v.finished = time(); v.err = "timeout"))
        fin("timeout")
        error("xfer $jid: timed out after $(round(Int, timeout))s")
    catch e
        _upd!(v -> v.finished == 0.0 && (v.finished = time(); v.err = first(sprint(showerror, e), 100)))
        fin(first(sprint(showerror, e), 100))
        rethrow()
    end
end

# The carry's transfer-vs-recompute decision: ship an entry only when moving its bytes beats
# recomputing it. Estimated transfer = bytes/bw; ship when that stays under BOTH 2× the entry's
# recorded compute cost (0.5s floor — trivial entries always ship, so a warm reattach isn't
# nickel-and-dimed) and the hard per-entry ceiling (a notebook open must never stall on one
# giant entry, however expensive its recompute claims to be — `sync_memo` covers that case).
_carry_should_ship(bytes::Integer, ms::Real, bw_bps::Real, cap_s::Real) =
    (est = bytes / max(bw_bps, 1.0); est <= max(2 * ms / 1000, 0.5) && est <= cap_s)

# ── Data-channel endpoint (transport-aware) ─────────────────────────────────────────────────
# Where the hub dials a worker's blob channel (gate port + 2). :direct → the routable IP + the
# gate's pinned CURVE key (the data socket serves with the SAME key), both cached in the
# attachment record so no ssh rides this path. :tunnel → a lazily-opened `ssh -L` forward on
# its OWN ssh process — a multi-GB shipment on the gate forward's ssh channel would head-of-
# line-block cell results (the whole reason the data socket exists). Forwards are cached per
# (host, remote data port), supervised like the gate tunnel, and evicted on reap/kill.
const _DATA_TUNNELS = Dict{Tuple{String,Int},Tuple{Tunnel,Int}}()   # (host, data_port) → (tunnel, local_port)
const _DATA_TUNNEL_LOCK = ReentrantLock()

# Bench toggle: the blob channel is CURVE-encrypted by default; set KAIMONSLATE_BLOB_CURVE=0 to run it
# PLAINTEXT on both ends for an encryption-cost A/B (PEER_TUNNEL_PLAN §7). Read on the HUB and baked
# into each worker at spawn (boot script) so both ends agree — flip it, then COLD-RESPAWN workers to
# take effect. Off exposes a plaintext blob port on :direct workers (0.0.0.0) — bench use only.
_blob_curve_on() = get(ENV, "KAIMONSLATE_BLOB_CURVE", "1") != "0"

# Effective per-region decision: CURVE unless the region opted out (its `curve=false` — the
# worker-specific bench knob, set via `region(...; curve=false)`) OR the global kill-switch
# (KAIMONSLATE_BLOB_CURVE=0) forces plaintext everywhere. Used at BOTH ends — the boot script (the
# worker's blob server) and `_data_endpoint!` (whether the hub supplies a key) — so they always agree.
_blob_curve(t::RemoteTarget) = t.curve && _blob_curve_on()

# The blob channel is CURVE on EVERY worker by default (PEER_TUNNEL_PLAN §2), so a :tunnel worker's
# data endpoint needs that worker's CURVE server public key to connect as a client. Learn it once over
# the (already-authenticated) control gate via `__slate_server_key` and cache per (host, data_port);
# evicted alongside the data tunnel on reap. (`:direct` workers get their key from the attach record
# at spawn, so they never hit this path.)
const _BLOB_SERVER_KEY = Dict{Tuple{String,Int},String}()
const _BLOB_SERVER_KEY_LOCK = ReentrantLock()

function _blob_server_key!(t::RemoteTarget, k, dport::Int)
    ck = (t.ssh_host, dport)
    hit = lock(_BLOB_SERVER_KEY_LOCK) do
        get(_BLOB_SERVER_KEY, ck, nothing)
    end
    hit === nothing || return hit
    key = try
        r = _tool(k, "__slate_server_key", Dict{String,Any}(); timeout = 30.0)
        e = try; getproperty(r, :error); catch; nothing; end
        e === nothing ? String(r.key) : ""
    catch
        ""
    end
    if isempty(key)
        _rlog("data channel: no CURVE server key from $(t.ssh_host) worker (data port $dport) — the worker " *
              "may predate the always-CURVE blob channel; cold-respawn it (plaintext connect will fail).")
    else
        lock(_BLOB_SERVER_KEY_LOCK) do
            _BLOB_SERVER_KEY[ck] = key
        end
    end
    return key
end

function _data_endpoint!(t::RemoteTarget, k)
    dport = k.port + 2
    if t.transport === :direct
        rec = _attach_lookup(t.ssh_host, k.label)   # ip + CURVE key were learned at spawn — no ssh here
        ip = rec !== nothing && !isempty(rec.remote_ip) ? String(rec.remote_ip) : _remote_ip(t.ssh_host)
        key = (_blob_curve(t) && rec !== nothing) ? String(rec.server_key) : ""   # "" when this region runs plaintext (bench)
        return (ip = ip, port = dport, server_key = key)
    end
    # :tunnel — the blob channel is CURVE (encryption-only) behind the SSH forward, so pin the
    # worker's server key. Fetch it OUTSIDE the tunnel lock so a control RPC never blocks other
    # endpoint resolutions waiting on the lock. ("" under the plaintext bench toggle.)
    key = _blob_curve(t) ? _blob_server_key!(t, k, dport) : ""
    lport = lock(_DATA_TUNNEL_LOCK) do
        cached = get(_DATA_TUNNELS, (t.ssh_host, dport), nothing)
        cached !== nothing && cached[1].running && return cached[2]
        lp = _free_local_port()
        tun = open_tunnel(t.ssh_host, [(lp, dport)])
        _DATA_TUNNELS[(t.ssh_host, dport)] = (tun, lp)
        _rlog("data channel: opened dedicated tunnel $(t.ssh_host):$dport ← 127.0.0.1:$lp (own ssh proc, CURVE)")
        return lp
    end
    return (ip = "127.0.0.1", port = lport, server_key = key)
end

# Close the cached data forward for `host` (a specific worker's data port, or all when port=0).
function _evict_data_tunnels!(host; port::Int = 0)
    lock(_DATA_TUNNEL_LOCK) do
        for key in collect(keys(_DATA_TUNNELS))
            key[1] == String(host) || continue
            (port == 0 || key[2] == port) || continue
            tun, _ = pop!(_DATA_TUNNELS, key)
            try; close_tunnel(tun); catch; end
        end
    end
    lock(_BLOB_SERVER_KEY_LOCK) do
        for ck in collect(keys(_BLOB_SERVER_KEY))
            ck[1] == String(host) || continue
            (port == 0 || ck[2] == port) || continue
            delete!(_BLOB_SERVER_KEY, ck)
        end
    end
    return nothing
end

# Push THIS notebook's memo entries to the kernel's remote worker over the data channel —
# the shared engine of the boot-window carry and the mid-session `sync_memo` tool. `boot=true`
# arms the cost gate (per-entry transfer-vs-recompute + a hard per-entry ceiling, so a big
# store on a slow link can't stall the notebook open); the explicit tool pushes everything.
function push_notebook_memo!(k, report; boot::Bool = false)
    t = k.target
    t isa RemoteTarget || return "not on a remote worker"
    k.port == 0 && return "remote worker not up yet"
    keys = String[_memo_key(report, c) for c in report.cells]
    filter!(!isempty, keys)
    isempty(keys) && return "no memoizable cells"
    ep = _data_endpoint!(t, k)
    return push_memo_blobs!(ep.ip, ep.port, keys; server_key = ep.server_key,
                            max_transfer_s = boot ? _carry_ceiling_s() : 0.0,
                            bw_key = t.ssh_host)   # bandwidth is per HOST — a tunnel dials 127.0.0.1
end

# ── Cross-kernel value transport (the region runner's boundary) ─────────────────────────────
# Move the namespace global `name` from kernel `src_k` to kernel `dst_k`: the source worker
# encodes it into its CAS (`__slate_blob_of` — codec-picked, so a DataFrame crosses as Arrow
# IPC), the blob moves through the LOCAL CAS as the interchange point (pull from a remote
# source / push to a remote destination, both over the data channel; a local worker shares the
# hub's store, so its leg is free), and the destination binds it (`__slate_bind_blob`). Content
# addressing gives dedup at every hop — re-shipping an unchanged value costs one round-trip.
# Returns (; bytes, codec) — bytes MOVED over a network (0 = deduped / local↔local).
# `on_plan(bytes_to_move, meta)` — called once per WIRE leg after the encode and the dedup
# check, with the EXACT bytes that will cross (0 = content already on the other side). May
# throw to abort before anything moves: the transfer-preview gate lives there, so its numbers
# are the encoded blob's, not a summarysize guess — mmap-backed arrow frames price correctly
# and dedup'd content never triggers a preview.
# Transfer MODE (see WORKER_CHANNEL_SPIKE.md):
#   :relay  — the star (default): A→hub-CAS→B. Always correct, and free when a side is the local
#             worker (it shares the hub's store). This is the code documented above.
#   :direct — the mesh: the hub BROKERS a single B←A pull over the workers' own blob channels (one
#             leg, no hub relay). Viable only between two DISTINCT :direct remote workers.
#   :auto   — try :direct when viable, transparently fall back to :relay on any failure.
# :direct is STRICT (errors if not viable / the pull fails) — for tests + observability; :auto is the
# forgiving mode the region runner uses. Return gains `mode` (the path actually taken).
_direct_viable(src_k, dst_k) =
    src_k.target isa RemoteTarget && dst_k.target isa RemoteTarget &&
    getfield(src_k.target, :transport) === :direct && src_k !== dst_k

# ── Peer route resolution (PEER_TUNNEL_PLAN §3) ───────────────────────────────────────────────
# How should dst (B) pull the boundary blob from src (A)? Only B can test B→A reachability, so the hub
# asks B to probe A's blob endpoint (`__slate_probe_peer`) and picks: :direct (CURVE straight to A) when
# the probe answers, else :relay (A→hub→B) — the :ssh arm (worker-local SSH forward over the friend-group
# mesh) arrives next. `ip`/`port` is A's blob port in B's OWN vantage (co-located ⇒ loopback), NOT the
# hub-local `_data_endpoint!` forward. This same probe is the coalesce "gap check" run on
# `set_notebook_regions!`. Verdict is cached per ORDERED host-pair (a probe is a ~RTT+handshake) and
# dropped when either worker is reaped (topology changed) — see `_peer_route_forget!`.
struct PeerRoute
    kind::Symbol       # :direct | :ssh | :relay
    ip::String
    port::Int
    server_key::String
end

# Peer-route verdicts are cached per ordered (src_host, dst_host) as (kind, chosen A-address, ts) — a
# probe is ~RTT+handshake, so we pay it once and reuse. PERSISTED to disk (mirrors the peer-bw cache) so it
# survives a hub restart AND doubles as a human-readable topology map (which pair resolved to what, when).
# TTL'd: a verdict older than `_peer_route_ttl()` is re-probed, so a path UPGRADES toward optimal over time
# (relay→direct once a firewall opens). And self-healing DOWNWARD in real time: a cached direct/ssh pull
# that FAILS (topology changed under us) invalidates its entry (`_peer_route_forget_pair!`) and relays now.
const _PEER_ROUTE_CACHE = Dict{Tuple{String,String},Tuple{Symbol,String,Float64}}()   # → (kind, A-addr, ts)
const _PEER_ROUTE_LOCK  = ReentrantLock()
const PEER_ROUTE_TTL = Ref{Float64}(-1.0)   # <0 = unset (env / default applies)
_peer_route_ttl() = PEER_ROUTE_TTL[] >= 0 ? PEER_ROUTE_TTL[] :
    something(tryparse(Float64, get(ENV, "KAIMONSLATE_PEER_ROUTE_TTL", "")), 600.0)   # 10 min default

_route_sanitize(x) = replace(String(x), r"[^A-Za-z0-9._-]" => "_")
_route_cache_path(sh, dh) = joinpath(_slate_cache_dir(), "route", "$(_route_sanitize(sh))__$(_route_sanitize(dh)).json")
function _peer_route_load(sh, dh)
    p = _route_cache_path(sh, dh); isfile(p) || return nothing
    s = try; read(p, String); catch; return nothing; end
    k = _manifest_get(s, "kind"); ip = _manifest_get(s, "ip"); ts = tryparse(Float64, _manifest_get(s, "ts"))
    (isempty(k) || ts === nothing) && return nothing
    return (Symbol(k), String(ip), ts)
end
function _peer_route_save(sh, dh, kind, ip, ts)
    try
        mkpath(dirname(_route_cache_path(sh, dh)))
        write(_route_cache_path(sh, dh), "{\"kind\":\"$(kind)\",\"ip\":\"$(ip)\",\"ts\":\"$(round(Int, ts))\"}")
    catch
    end
    return nothing
end
# Fresh (kind, ip) for a pair, or nothing if absent/expired (→ caller re-probes). Load-through from disk.
function _peer_route_lookup(sh, dh)
    hit = lock(_PEER_ROUTE_LOCK) do; get(_PEER_ROUTE_CACHE, (sh, dh), nothing); end
    if hit === nothing
        hit = _peer_route_load(sh, dh)
        hit !== nothing && lock(_PEER_ROUTE_LOCK) do; _PEER_ROUTE_CACHE[(sh, dh)] = hit; end
    end
    (hit === nothing || (time() - hit[3]) > _peer_route_ttl()) && return nothing
    return (hit[1], hit[2])
end
function _peer_route_store!(sh, dh, kind, ip)
    t = time()
    lock(_PEER_ROUTE_LOCK) do; _PEER_ROUTE_CACHE[(sh, dh)] = (kind, ip, t); end
    _peer_route_save(sh, dh, kind, ip, t)
    return nothing
end
# Drop one pair's verdict (in-memory + disk) — the real-time downgrade on a failed direct/ssh pull.
function _peer_route_forget_pair!(sh, dh)
    lock(_PEER_ROUTE_LOCK) do; delete!(_PEER_ROUTE_CACHE, (String(sh), String(dh))); end
    try; rm(_route_cache_path(sh, dh); force = true); catch; end
    return nothing
end
# Drop every verdict touching `host` (in-memory + disk) — topology changed (reap).
function _peer_route_forget!(host)
    h = String(host); hs = _route_sanitize(h)
    lock(_PEER_ROUTE_LOCK) do
        for k in collect(keys(_PEER_ROUTE_CACHE))
            (k[1] == h || k[2] == h) && delete!(_PEER_ROUTE_CACHE, k)
        end
    end
    d = joinpath(_slate_cache_dir(), "route")
    isdir(d) && for f in readdir(d)
        endswith(f, ".json") || continue
        parts = split(chopsuffix(f, ".json"), "__")
        (length(parts) == 2 && hs in parts) && try; rm(joinpath(d, f); force = true); catch; end
    end
    return nothing
end

# A worker's blob CURVE server key (its own identity — vantage-independent). On :direct it's in the
# attach record (learned at spawn); else fetched via `__slate_server_key` (cached). "" when the region
# runs the blob channel plaintext.
function _peer_server_key(k)
    t = k.target
    _blob_curve(t) || return ""
    if t.transport === :direct
        rec = _attach_lookup(t.ssh_host, k.label)
        rec !== nothing && !isempty(String(rec.server_key)) && return String(rec.server_key)
    end
    return _blob_server_key!(t, k, k.port + 2)
end

# A host's PEER-reachable IP — the address a co-located / same-subnet peer dials (NOT the hub's route).
# `_remote_ip` (SSH_CONNECTION field 3) is the box's own interface address, which IS the peer address on
# a shared subnet and the public IP for a directly-public box. Cached (an ssh round-trip). §5.6
# (cross-network NAT — a hub reaching a box by a public IP that NATs to a private one) will need an
# explicit region `peer` override; not required for the same-subnet case.
const _HOST_IP_CACHE = Dict{String,String}()
const _HOST_IP_LOCK  = ReentrantLock()
function _peer_host_ip(host)
    h = String(host)
    hit = lock(_HOST_IP_LOCK) do; get(_HOST_IP_CACHE, h, ""); end
    isempty(hit) || return hit
    ip = try; _remote_ip(h); catch; h; end
    lock(_HOST_IP_LOCK) do; _HOST_IP_CACHE[h] = ip; end
    return ip
end

# The address a PEER dials to reach `region`'s blob port. Prefer the region's explicit `peer` advertise
# address — its PUBLIC IP when peers live on a different network than the hub (§5.6: the hub-facing IP is
# then wrong, e.g. a private-subnet address the hub shares but a cross-cloud peer can't route). Fall back
# to the hub-facing interface IP, which is correct only when the hub shares a network with the peer
# (same subnet / directly-public box). A region with no inbound path leaves `peer` "" and its transfers
# relay (the probe simply fails). `host` is the ssh alias used for the fallback lookup.
function _region_peer_addr(region, host)
    r = region_get(region)
    (r !== nothing && !isempty(r.peer)) && return String(r.peer)
    return _peer_host_ip(host)
end

function _resolve_peer_route(src_k, dst_k)
    (src_k.target isa RemoteTarget && dst_k.target isa RemoteTarget && src_k !== dst_k) ||
        return PeerRoute(:relay, "", 0, "")
    # A's PEER-vantage endpoint: its RAW blob port (gate+2) at its PEER-reachable IP — NOT `_data_endpoint!`,
    # which is hub-vantage (a :tunnel worker's would be the hub-local `ssh -L` forward, meaningless to a
    # peer, and calling it would open a tunnel as a side effect). Co-located ⇒ loopback (§3).
    port = src_k.port + 2
    colocated = src_k.target.ssh_host == dst_k.target.ssh_host
    skey = _peer_server_key(src_k)
    sh, dh = String(src_k.target.ssh_host), String(dst_k.target.ssh_host)
    # Candidate A-addresses B might reach, in PREFERENCE order (probing picks the first that answers, so B's
    # own vantage decides — no static "which network are they on?" guess): co-located ⇒ loopback; else the
    # hub-facing interface IP first (the fast path when B shares A's network — e.g. a private subnet the hub
    # is also on), then A's explicit `peer` advertise addr (its PUBLIC IP, for a cross-network B). A region
    # with neither reachable (localhost/NAT source) yields no working candidate ⇒ relay.
    adv = (r = region_get(src_k.target.region); r === nothing ? "" : String(r.peer))
    cands = colocated ? ["127.0.0.1"] : unique(filter(!isempty, [_peer_host_ip(sh), adv]))
    # B probes A (only B can test its own B→A reachability).
    _probe(pip, pport) = (r = try; _tool(dst_k, "__slate_probe_peer",
            Dict{String,Any}("ip" => pip, "port" => pport); timeout = 15.0); catch; nothing; end;
        r !== nothing && (try; r.reachable === true; catch; false; end))
    cached = _peer_route_lookup(sh, dh)              # in-memory → disk → nothing if absent/expired (TTL)
    if cached === nothing
        kind = :relay; ip = isempty(cands) ? "" : cands[1]
        for c in cands                               # prefer a DIRECT blob dial on any candidate
            _probe(c, port) && (kind = :direct; ip = c; break)
        end
        if kind === :relay                           # else the SSH bridge over any candidate reachable on :22
            for c in cands
                _probe(c, 22) && (kind = :ssh; ip = c; break)
            end
        end
        cached = (kind, ip)
        _peer_route_store!(sh, dh, kind, ip)         # persist (survives restart; a topology map + TTL'd)
        candstr = join(cands, "/")
        _rlog(kind === :direct ? "peer route $sh→$dh: blob $ip:$port reachable ⇒ direct" :
              kind === :ssh    ? "peer route $sh→$dh: blob firewalled; ssh $ip:22 reachable ⇒ ssh-bridge (§4)" :
                                 "peer route $sh→$dh: no candidate $candstr reachable on blob/:22 ⇒ relay")
    end
    return PeerRoute(cached[1], cached[2], port, skey)
end

# ── Standing mesh authorization (PEER_TUNNEL_PLAN Part 4) ──────────────────────────────────────────
# A dest's blob CLIENT KEY must sit on the source's blob allow-list before the dest can pull. Authorizing
# it PER TRANSFER (authorize → pull → revoke) cost TWO gate round-trips on every move — a dominant overhead
# for small/rapid transfers. Instead authorize ONCE per (source kernel, dest key) and cache it; never
# revoke (the allow-list persists). Keyed by the source kernel's objectid, so a worker SWAP (fresh
# GateKernel, possibly a reset allow-list) re-authorizes; a transfer FAILURE also forgets the entry so the
# retry re-authorizes — self-healing if the allow-list ever drifts out from under us.
const _AUTHED = Set{Tuple{UInt,String}}()
const _AUTHED_LOCK = ReentrantLock()
_authed_key(src_k, bpub) = (objectid(src_k), String(bpub))
function _ensure_authed!(src_k, bpub)
    key = _authed_key(src_k, bpub)
    lock(_AUTHED_LOCK) do; key in _AUTHED; end && return nothing
    ak = _tool(src_k, "__slate_authorize_client", Dict{String,Any}("pubkey" => String(bpub)); timeout = 60.0)
    akerr = try; getproperty(ak, :error); catch; nothing; end
    akerr === nothing || error("authorise on source failed: $akerr")
    lock(_AUTHED_LOCK) do; push!(_AUTHED, key); end
    return nothing
end
_forget_authed!(src_k, bpub) = lock(_AUTHED_LOCK) do; delete!(_AUTHED, _authed_key(src_k, bpub)); end

# A dest's blob CLIENT pubkey is stable for the worker's lifetime — the keypair is persisted to disk, so
# it survives even a respawn — yet `_pull_*!` fetched it over the gate on EVERY pull. Cache it per dest
# kernel (keyed by objectid, like the standing-auth cache: a worker SWAP → fresh GateKernel → refetch),
# and drop it on a pull failure so a genuinely-swapped worker re-fetches. One fewer gate round-trip per move.
const _DEST_CKEY = Dict{UInt,String}()
const _DEST_CKEY_LOCK = ReentrantLock()
function _dest_client_key(dst_k)
    oid = objectid(dst_k)
    hit = lock(_DEST_CKEY_LOCK) do; get(_DEST_CKEY, oid, nothing); end
    hit === nothing || return hit
    bk = _tool(dst_k, "__slate_client_key", Dict{String,Any}(); timeout = 60.0)
    bkerr = try; getproperty(bk, :error); catch; nothing; end
    bkerr === nothing || error("dest client key unavailable: $bkerr")
    bpub = String(bk.key)
    lock(_DEST_CKEY_LOCK) do; _DEST_CKEY[oid] = bpub; end
    return bpub
end
_forget_dest_client_key!(dst_k) = lock(_DEST_CKEY_LOCK) do; delete!(_DEST_CKEY, objectid(dst_k)); end

# Broker one direct B←A pull over the RESOLVED route (`route.{ip,port,server_key}` = A's blob endpoint in
# B's OWN vantage — co-located loopback already applied by `_resolve_peer_route`): ensure B's client key is
# on A's blob allow-list (standing auth — authorized once, cached), then have B pull straight into its CAS.
# Returns bytes moved (0 = deduped). THROWS on any failure — the caller (`:auto`) decides whether to relay.
function _pull_direct!(src_k, dst_k, name, h::String, meta, route::PeerRoute)
    bpub = _dest_client_key(dst_k)                         # cached per dest kernel — no gate round-trip on reuse
    authed = !isempty(route.server_key)                    # allow-list gate only exists under CURVE
    authed && _ensure_authed!(src_k, bpub)                 # standing auth: authorize once, cached (no revoke)
    try
        # Drive the pull over the DST's BLOB CHANNEL (transfer-control plane), NOT a gate :tool_call — so it
        # runs on the dst's executor task and never starves gate liveness (TRANSFER_CONTROL_PLAN Mode A).
        bytes, _ = _xfer_ctl_pull(dst_k, "$(h)\ndirect\n$(route.ip)\n$(route.port)\n$(route.server_key)";
            meta = (dst = String(dst_k.target.region), src = String(src_k.target.region), name = String(name), via = "direct"))
        return bytes
    catch
        authed && _forget_authed!(src_k, bpub)             # failure → drop the caches so a retry re-authorizes
        _forget_dest_client_key!(dst_k)                    # (a swapped worker gets both refreshed)
        rethrow()
    end
end

# A host's SSH user, resolved from the hub's OWN ssh config (`ssh -G` prints the resolved config without
# connecting) so B ssh's in as the right user. Cached. Empty ⇒ let ssh pick its default.
const _SSH_USER_CACHE = Dict{String,String}()
const _SSH_USER_LOCK  = ReentrantLock()
function _ssh_user(host)
    h = String(host)
    hit = lock(_SSH_USER_LOCK) do; get(_SSH_USER_CACHE, h, nothing); end
    hit === nothing || return hit
    u = try
        m = match(r"(?m)^user (.+)$", read(`ssh -G $h`, String))
        m === nothing ? "" : String(strip(m.captures[1]))
    catch; ""; end
    lock(_SSH_USER_LOCK) do; _SSH_USER_CACHE[h] = u; end
    return u
end

# Friend-group mesh artifact naming (§5). Every peer-mesh artifact for a region derives from ONE
# basename `slate-<foldedname>-<uuid8>` — the private key file on its host, the comment tag on an
# authorized_keys line it authors, the tag on a host-key pin. Single-sourced here (folds the name and
# self-heals the uuid) so the key path `_pull_ssh!` dials and the artifacts `peer_mesh.jl` installs can
# never drift apart. `~` is expanded on the worker.
function _mesh_basename(region)
    r = region_get(region)
    r === nothing && return "slate-$(_fold_region(region))-unknown"
    "slate-$(r.name)-$(first(region_uuid(r.name), 8))"
end
_mesh_key_path(region) = "~/.ssh/" * _mesh_basename(region)   # a region's OWN private key (it ssh's OUT with this)
_mesh_known_hosts()    = "~/.ssh/slate_known_hosts"           # slate-OWNED known_hosts (never the user's)

# Broker one SSH-BRIDGED B←A pull (§4): authorise B on A's blob channel, have B open a worker-local
# `ssh -N -L` forward to A (using B's own mesh key) and CURVE-pull through it, then revoke. `route.ip` is
# A's peer SSH address, `route.port` its blob port. Needs the friend-group keys (§5) present on B — else
# B's ssh forward fails and the caller (`:auto`) relays. THROWS on failure.
function _pull_ssh!(src_k, dst_k, name, h::String, meta, route::PeerRoute)
    # A tunnel source's grant was installed with an inert placeholder permitopen; rewrite it to the LIVE
    # blob port (route.port) before dialing, so the forward isn't administratively refused (§2). No-op for
    # a :direct source (already the real port) or an un-introduced pair (nothing to touch).
    try; _mesh_finalize_port!(String(src_k.target.region), String(dst_k.target.region), route.port); catch e
        _rlog("mesh: permitopen finalize $(dst_k.target.region)←$(src_k.target.region) failed — $(first(sprint(showerror, e), 120))")
    end
    bpub = _dest_client_key(dst_k)                         # cached per dest kernel — no gate round-trip on reuse
    authed = !isempty(route.server_key)
    authed && _ensure_authed!(src_k, bpub)                 # standing auth: authorize once, cached (no revoke)
    a_user = _ssh_user(src_k.target.ssh_host)
    ssh_target = isempty(a_user) ? route.ip : "$(a_user)@$(route.ip)"
    try
        # Over the DST's blob channel (transfer-control plane), off the gate — the ssh forward + CURVE pull
        # run on the dst's executor task (TRANSFER_CONTROL_PLAN Mode A).
        spec = "$(h)\nssh\n$(ssh_target)\n$(_mesh_key_path(String(dst_k.target.region)))\n" *
               "$(_mesh_known_hosts())\n$(route.port)\n$(route.server_key)"
        bytes, _ = _xfer_ctl_pull(dst_k, spec;
            meta = (dst = String(dst_k.target.region), src = String(src_k.target.region), name = String(name), via = "ssh"))
        return bytes
    catch
        authed && _forget_authed!(src_k, bpub)             # failure → drop the caches so a retry re-authorizes
        _forget_dest_client_key!(dst_k)                    # (a swapped worker gets both refreshed)
        rethrow()
    end
end

# ── On-demand transfer probe (DAG "recalculate") ───────────────────────────────────────────────────
# Measure the live peer route + throughput between two region workers WITHOUT a notebook value driving it:
# resolve the route (caching the verdict), mint a THROWAWAY random blob on the source CAS (no manifest → it
# is never a memo value), pull it to the dest over the SAME peer path a real transfer uses (feeding the
# peer-rate memory + the live `transfers` view), then drop the blob on BOTH ends. Returns
# (; kind, bytes, seconds, mbps); kind = :direct | :ssh | :relay | :local.
_probe_bytes() = round(Int, 1e6 * something(tryparse(Float64, get(ENV, "KAIMONSLATE_PROBE_MB", "")), 8.0))
function probe_transfer!(src_k, dst_k; bytes::Int = _probe_bytes())
    (src_k.target isa RemoteTarget && dst_k.target isa RemoteTarget && src_k !== dst_k) ||
        return (; kind = :local, bytes = 0, seconds = 0.0, mbps = 0.0)
    route = _resolve_peer_route(src_k, dst_k)               # probe B→A + cache the verdict
    route.kind in (:direct, :ssh) || return (; kind = route.kind, bytes = 0, seconds = 0.0, mbps = 0.0)
    mk = _tool(src_k, "__slate_make_probe_blob", Dict{String,Any}("bytes" => bytes); timeout = 60.0)
    mkerr = try; getproperty(mk, :error); catch; nothing; end
    mkerr === nothing || error("probe: source blob failed: $mkerr")
    h = String(mk.hash)
    try
        t0 = time()
        moved = route.kind === :direct ? _pull_direct!(src_k, dst_k, "·probe", h, mk, route) :
                                         _pull_ssh!(src_k, dst_k, "·probe", h, mk, route)
        el = time() - t0
        (moved > 0 && el > 0) && _peer_bw_note!(String(src_k.target.ssh_host), String(dst_k.target.ssh_host), moved / el)
        return (; kind = route.kind, bytes = moved, seconds = el, mbps = el > 0 ? moved / el / 1e6 : 0.0)
    finally
        try; _tool(src_k, "__slate_drop_blob", Dict{String,Any}("hash" => h); timeout = 20.0); catch; end
        try; _tool(dst_k, "__slate_drop_blob", Dict{String,Any}("hash" => h); timeout = 20.0); catch; end
    end
end

function transfer_binding!(src_k, dst_k, name::AbstractString; zc::Bool = false, mode::Symbol = :relay,
                           on_plan = nothing, on_progress = nothing, cellkey::AbstractString = "")
    # `cellkey` (the producing cell's memo key) lets the source memo-RESTORE the value if its live global
    # is gone (a swapped worker) instead of failing "no global named" — the source persists the memo store
    # across the swap even though its namespace was reset. Empty ⇒ no fallback (caller can't name the cell).
    meta = _tool(src_k, "__slate_blob_of", Dict{String,Any}("name" => String(name), "cellkey" => String(cellkey)); timeout = _blob_xfer_timeout())
    err = try; getproperty(meta, :error); catch; nothing; end
    err === nothing || error("transfer '$name': $err")
    h = String(meta.hash); codec = String(meta.codec)

    # Transfer-preview / confirmation gate: it's about the transfer SIZE, not the path taken, so fire it
    # ONCE, up front. A big-transfer "confirm by rerun" then PROPAGATES to the cell (approve-by-rerun)
    # rather than being caught by the :auto fallback and mistaken for a direct-transport failure — the
    # bug that silently dropped a large co-located transfer onto the slow, tunnel-bound hub relay. Only
    # gate a move that actually crosses a wire (a remote endpoint); a fully-local move (shared hub CAS)
    # costs nothing and needs no confirmation.
    if on_plan !== nothing && (src_k.target isa RemoteTarget || dst_k.target isa RemoteTarget)
        on_plan(Int(meta.bytes), meta, _plan_rate(src_k, dst_k, mode))   # price at the PATH's rate (peer vs uplink)
    end

    moved = 0
    used = :relay
    if mode === :direct || mode === :auto
        route = _resolve_peer_route(src_k, dst_k)           # probe B→A: :direct / :ssh (bridge) / :relay
        if route.kind === :direct || route.kind === :ssh
            try
                _t0 = time()
                moved = route.kind === :direct ? _pull_direct!(src_k, dst_k, name, h, meta, route) :
                                                 _pull_ssh!(src_k, dst_k, name, h, meta, route)
                used = route.kind
                _el = time() - _t0                          # feed the peer-rate memory (skip dedup/tiny moves)
                (moved > (4 << 20) && _el > 0) &&
                    _peer_bw_note!(src_k.target.ssh_host, dst_k.target.ssh_host, moved / _el)
            catch e
                mode === :direct && rethrow()               # strict: surface the failure
                # Real-time DOWNGRADE: the cached path broke (topology likely changed under us) — forget this
                # pair's verdict so the next transfer re-probes, and relay right now.
                _peer_route_forget_pair!(String(src_k.target.ssh_host), String(dst_k.target.ssh_host))
                _rlog("region transfer '$name': $(route.kind) failed, forgetting route + falling back to relay — " *
                      first(sprint(showerror, e), 160))
            end
        elseif mode === :direct
            error("transfer '$name': direct not viable — peer route resolved to :relay (source and dest " *
                  "must be reachable peers, directly or via the SSH bridge)")
        end
    end

    if used === :relay                                      # neither direct nor ssh took it
        root = joinpath(_slate_cache_dir(), "memo")
        if src_k.target isa RemoteTarget                   # remote source → land the blob locally
            ep = _data_endpoint!(src_k.target, src_k)
            moved += pull_blob!(ep.ip, ep.port, h; server_key = ep.server_key, on_progress = on_progress)
        end
        if dst_k.target isa RemoteTarget                   # remote destination → ship it there
            ep = _data_endpoint!(dst_k.target, dst_k)
            moved += push_blob!(ep.ip, ep.port, h; server_key = ep.server_key,
                                on_plan = nothing, meta = meta, on_progress = on_progress)
        end
    end

    r = _tool(dst_k, "__slate_bind_blob", Dict{String,Any}(
        "name" => String(name), "hash" => h, "codec" => codec, "zc" => zc); timeout = _blob_xfer_timeout())
    rerr = try; getproperty(r, :error); catch; nothing; end
    rerr === nothing || error("transfer '$name' (bind): $rerr")
    return (; bytes = moved, codec = codec, mode = used)
end

# Boot-window memo carry — "your session follows you", automatically. Called from `prepare!`
# right after the remote connection is up and BEFORE the first cell dispatch: a push at any
# later point RACES hydration — the recompute stores under the same key and clobbers the
# pushed entry (seen live; rand-token producer proved the ordering). Here the worker's blob
# channel is already bound (at spawn) and nothing has evaluated yet, so pushed entries are
# exactly what hydration then restores. Failure is never fatal: the cells just recompute.
function _sync_memo_boot!(k, report)
    k.target isa RemoteTarget || return nothing
    try
        r = push_notebook_memo!(k, report; boot = true)
        _rlog("memo carry (boot window) → $(k.target.ssh_host):$(k.port + 2) — $r")
    catch e
        _rlog("memo carry failed — cells recompute remotely instead ($(first(sprint(showerror, e), 200)))")
    end
    return nothing
end

# ── Attachment record (the hub's local memory of where it left each worker) ─────────────────
# Written at spawn/reattach, consulted FIRST on the next connect: (host, label) → ports,
# transport, CURVE server key, routable IP. Every field was learned during the original spawn,
# so re-deriving any of them over ssh on the reattach path (the probe asking the host what we
# already knew; re-fetching a key that is by definition PINNED; asking the remote its own IP)
# was pure waste — with the record, reattach touches the network exactly once: the dial itself,
# whose success IS the validation. A dead record fails the short dial and demotes to probe →
# spawn. One flat hand-written JSON file per attachment (regex-read like the worker manifests —
# ReportEngine deliberately has no JSON dep), keyed by hash(host, label).
const _ATTACH_DIR = joinpath(_slate_cache_dir(), "attach")

_attach_path(host, label) =
    joinpath(_ATTACH_DIR, string(hash((String(host), String(label))); base = 16) * ".json")

function _attach_record!(host, label; port::Int, stream_port::Int, transport::Symbol,
                         server_key::AbstractString = "", remote_ip::AbstractString = "")
    esc(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => " ", "\r" => " ")
    fields = ["host" => String(host), "label" => String(label), "port" => string(port),
              "stream_port" => string(stream_port), "transport" => string(transport),
              "server_key" => String(server_key), "remote_ip" => String(remote_ip),
              "ts" => string(round(Int, time()))]
    body = "{" * join(["\"$(esc(k))\":\"$(esc(v))\"" for (k, v) in fields], ",") * "}"
    try
        mkpath(_ATTACH_DIR)
        p = _attach_path(host, label); tmp = p * ".tmp"
        write(tmp, body); mv(tmp, p; force = true)
    catch e
        _rlog("attach-record: could not write for $host/$label ($(sprint(showerror, e)))")
    end
    return nothing
end

function _attach_lookup(host, label)
    p = _attach_path(host, label)
    isfile(p) || return nothing
    s = try; read(p, String); catch; return nothing; end
    g(k) = _manifest_get(s, k)
    port = tryparse(Int, g("port")); sp = tryparse(Int, g("stream_port"))
    (port === nothing || sp === nothing || port == 0) && return nothing
    tr = g("transport")
    return (port = port, stream_port = sp, transport = Symbol(isempty(tr) ? "tunnel" : tr),
            server_key = g("server_key"), remote_ip = g("remote_ip"))
end

_attach_clear!(host, label) = (try; rm(_attach_path(host, label); force = true); catch; end; nothing)

# ── Warm worker pool (Phase B) ───────────────────────────────────────────────────────────────
# `warm_pool!(host; n, preload)` keeps `n` notebook-less workers running warm on the host —
# process up, gate serving, eval path prewarmed, and (with `preload`) the env's packages already
# imported — so opening a notebook there ADOPTS one (~1s: dial + namespace swap) instead of
# paying the ~90s boot. Desired state persists hub-side (one flat JSON per host, same no-dep
# regex discipline as the manifests); replenishment is hub-driven — every adoption triggers a
# background `_pool_reconcile!`, so the pool refills while the user is already working.

# ── Region registry (global, named compute definitions) ───────────────────────────────────────────────
# A REGION is the unit of remote-compute config: a user-named definition pointing at a host with its own
# transport, data root, and warm-worker count. Many regions may target the SAME host with different config.
# Persisted GLOBALLY (not per-notebook) as a single JSON list in the config home — alongside slate.json —
# so a notebook references regions by NAME only. This supersedes the old per-host warm-pool store (`warm`
# folds in the pool count: warm>0 ⇒ keep that many workers ready to adopt).
#
# Config-home resolution mirrors SlateHome.config_file(); ReportEngine loads before SlateHome so it can't
# call it directly (same reason `_slate_cache_dir` is inlined here). KEEP IN SYNC with slate_home.jl.
function _slate_config_dir()
    h = get(ENV, "KAIMONSLATE_CONFIG_HOME", "");  isempty(h) || return h
    kh = get(ENV, "KAIMONSLATE_HOME", "");        isempty(kh) || return joinpath(kh, "config")
    joinpath(get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config")), "kaimonslate")
end
_regions_path() = joinpath(_slate_config_dir(), "regions.json")

struct Region
    name::String        # unique global identity — the cell-tag target AND the adoption key (user-chosen)
    host::String        # ssh target (later: cluster ref)
    transport::Symbol   # :tunnel | :direct
    base_port::Int      # :direct port pinning (0 = auto)
    preload::String     # LOCAL project dir replicated for env/warm-deps parity ("" = none)
    data_root::String   # REMOTE KAIMONSLATE_DATADIR ("" = worker default)
    cache_root::String  # REMOTE KAIMONSLATE_CACHE_HOME — a separate CAS per region ("" = shared ~/.cache)
    warm::Int           # warm workers kept ready (0 = cold spin on demand)
    threads::String     # worker "<compute>,<interactive>" ("" = global default)
    sysimage::Bool      # bake a PackageCompiler worker sysimage for this region's env (opt-in; default false)
    curve::Bool         # CURVE-encrypt this region's data channel (default true; false = plaintext, for the §7 bench)
    uuid::String        # stable per-region id (minted at setup) — every peer-mesh artifact is named slate-<name>-<uuid8> (§5.5)
    peer::String        # peer-reachable address OTHER regions dial to reach this one — its PUBLIC IP when cross-network (§5.6). "" = derive from the hub-facing IP (only valid when the hub shares a network with the peers). A region with no inbound reachability (localhost/NAT, outbound-only) leaves this "" and simply relays inbound transfers.
end

const _REGIONS_LOCK = ReentrantLock()   # serialize read-modify-write; reads are lock-free (writes are atomic mv)
_asint(x) = x isa Integer ? Int(x) : x isa AbstractFloat ? round(Int, x) : something(tryparse(Int, String(x)), 0)
_asbool(x) = x === true || x == 1 || (x isa AbstractString && lowercase(strip(x)) in ("1", "true", "yes", "on"))
# Fold a region name to a tag-safe identifier — a cell's `region=<name>` tag folds non-word chars to
# `_`, so region_set!/region_get/region_delete! MUST fold identically or a stored region can never be
# looked up again ("slate-remote" stored as "slate_remote"; a get on "slate-remote" would miss).
_fold_region(name) = replace(strip(String(name)), r"[^A-Za-z0-9_]+" => "_")
_region_from_dict(d::AbstractDict) = Region(
    String(get(d, "name", "")), String(get(d, "host", "")),
    Symbol(let t = String(get(d, "transport", "tunnel")); isempty(t) ? "tunnel" : t end),
    _asint(get(d, "base_port", 0)), String(get(d, "preload", "")), String(get(d, "data_root", "")),
    String(get(d, "cache_root", "")), _asint(get(d, "warm", 0)), String(get(d, "threads", "")),
    _asbool(get(d, "sysimage", false)), _asbool(get(d, "curve", true)), String(get(d, "uuid", "")),
    String(get(d, "peer", "")))
_region_to_dict(r::Region) = Dict("name" => r.name, "host" => r.host, "transport" => String(r.transport),
    "base_port" => r.base_port, "preload" => r.preload, "data_root" => r.data_root,
    "cache_root" => r.cache_root, "warm" => r.warm, "threads" => r.threads, "sysimage" => r.sysimage,
    "curve" => r.curve, "uuid" => r.uuid, "peer" => r.peer)

# ── Per-region UUID (mesh-artifact naming; PEER_TUNNEL_PLAN §5.5) ──────────────────────────────
# A stable 128-bit id minted once at region setup and persisted in the region record. Every
# peer-mesh artifact (ssh keypair, authorized_keys line, slate_known_hosts pin) is named
# `slate-<region>-<uuid8>`, so teardown can enumerate + prove ownership of exactly ours and nothing
# a human added. Random hex — no UUIDs dep, and a name no human would ever type.
_mint_region_uuid() = bytes2hex(rand(UInt8, 16))
region_uuid8(r::Region) = first(r.uuid, 8)
region_artifact_name(r::Region) = "slate-$(r.name)-$(region_uuid8(r))"

# Every configured region (sorted by name). Lock-free: a concurrent writer swaps the file atomically, so a
# reader sees either the old or the new complete file, never a torn one.
function regions()
    p = _regions_path(); isfile(p) || return Region[]
    data = try; JSON.parse(read(p, String)); catch; return Region[]; end
    data isa AbstractVector || return Region[]
    out = Region[]
    for d in data
        d isa AbstractDict || continue
        r = _region_from_dict(d); isempty(r.name) && continue
        push!(out, r)
    end
    sort!(out; by = r -> r.name)
    return out
end
region_get(name) = (n = _fold_region(name); for r in regions(); r.name == n && return r; end; nothing)

# The region's stable UUID, self-healing an older record that predates the field by minting +
# persisting one on first request (a no-op once set). Returns "" for an unknown region. Peer-mesh
# code calls this — never `region_get(...).uuid` directly — so a pre-UUID region can't slip through
# with a blank id.
function region_uuid(name)
    r = region_get(name); r === nothing && return ""
    isempty(r.uuid) || return r.uuid
    region_set!(r.name; host = r.host, transport = r.transport, base_port = r.base_port,
                preload = r.preload, data_root = r.data_root, cache_root = r.cache_root,
                warm = r.warm, threads = r.threads, sysimage = r.sysimage, curve = r.curve,
                peer = r.peer).uuid
end

function _write_regions!(list::AbstractVector{Region})
    mkpath(_slate_config_dir())
    p = _regions_path(); tmp = p * ".tmp"
    write(tmp, JSON.json([_region_to_dict(r) for r in list], 2)); mv(tmp, p; force = true)
    return nothing
end

# Create or update a region by name (upsert). Returns the stored Region.
function region_set!(name; host, transport = :tunnel, base_port = 0, preload = "",
                     data_root = "", cache_root = "", warm = 0, threads = "", sysimage = false,
                     curve = true, uuid = "", peer = "")
    n = _fold_region(name)   # tag-safe id — MUST match region_get/region_delete! + a cell's `region=` tag
    isempty(n) && error("region name required")
    return lock(_REGIONS_LOCK) do
        list = regions()
        i = findfirst(x -> x.name == n, list)
        # The UUID is STABLE across upserts: an explicit arg wins, else keep the existing region's,
        # else mint one. Editing a region (warm count, ports, …) must never rotate it — every mesh
        # artifact keyed on `slate-<region>-<uuid8>` would orphan (PEER_TUNNEL_PLAN §5.5).
        u = !isempty(String(uuid)) ? String(uuid) :
            (i === nothing || isempty(list[i].uuid)) ? _mint_region_uuid() : list[i].uuid
        # `peer` (§5.6 advertise addr) is likewise sticky across upserts: explicit arg wins, else keep
        # the existing value, else "" (derive from the hub-facing IP).
        pe = !isempty(String(peer)) ? String(peer) : (i === nothing ? "" : list[i].peer)
        r = Region(String(n), String(host), Symbol(transport), Int(base_port), String(preload),
                   String(data_root), String(cache_root), Int(warm), String(threads),
                   _asbool(sysimage), _asbool(curve), u, pe)
        i === nothing ? push!(list, r) : (list[i] = r)
        _write_regions!(list)
        r
    end
end

function region_delete!(name)
    n = _fold_region(name)
    lock(_REGIONS_LOCK) do
        _write_regions!(filter(x -> x.name != n, regions()))
    end
    return nothing
end

# Delete a region AND reap its warm workers (best-effort) so none linger orphaned. Defined here as a
# thin wrapper; the reap machinery lives further down (forward-referenced, resolved at call time).
function region_remove!(name)
    r = region_get(name)
    if r !== nothing && !isempty(r.host)
        try
            for w in list_remote_workers(r.host)
                _region_warm_worker(w, r.name) && reap_remote_worker(r.host, w["port"])
            end
        catch e
            _rlog("region[$(r.name)]: drain-on-delete failed ($(sprint(showerror, e)))")
        end
    end
    # Remove this region's peer-mesh artifacts (keypair, authorized_keys grants, host-key pins) BEFORE the
    # record is dropped — teardown needs the host + uuid to enumerate them by tag (§5.5). Best-effort.
    try; teardown_region_mesh!(name); catch e
        _rlog("region[$(_fold_region(name))]: mesh teardown failed ($(first(sprint(showerror, e), 120)))")
    end
    region_delete!(name)
    delete!(_REGION_STATUS, _fold_region(name))   # status is keyed by the folded region name
    return nothing
end

# Warm workers are now driven by the global Region registry (above) — the per-host pool store is gone.

# Snapshot of the parked wires (host, label, port, idle seconds) — for the query surface.
function parked_wires()
    lock(_PARK_LOCK) do
        [(host = k[1], label = k[2], port = p.port, idle_s = round(Int, time() - p.since))
         for (k, p) in _PARKED]
    end
end

# Free (main, stream) port slots inside a :direct region's base_port stride (worker i → base+3i..+2),
# skipping any 3-port block a live worker already holds. Returns up to `n` tuples; fewer (with a log)
# when the open range is too narrow. Shared by the warm reconcile AND a region kernel's own cold spawn
# so both land inside the base range you opened in the firewall — never the monotonic auto counter,
# which marches past the range and never rewinds.
function _direct_port_slots(base_port::Int, n::Int; roster, label::AbstractString = "")
    occupied = Set{Int}()
    for w in roster
        w["alive"] === true || continue
        p = w["port"]; push!(occupied, p, p + 1, p + 2)
    end
    ports = Tuple{Int,Int}[]
    k = 0
    while length(ports) < n && k < 256
        p = base_port + 3k; k += 1
        (p + 2) <= 65535 || break
        (p in occupied || (p + 1) in occupied || (p + 2) in occupied) && continue
        push!(ports, (p, p + 1))
    end
    length(ports) < n &&
        _rlog("$(isempty(label) ? "" : label * ": ")only $(length(ports)) free :direct slot(s) from base $base_port — open a wider range for $n worker(s)")
    return ports
end

# Isolate the per-project remote env dir: key it by the FULL project/env path (a hash), NOT just the
# basename — so two unrelated notebooks (or a stale/failed provision) can never share and poison one
# mutable env. Readable prefix + a path hash: the SAME path → the SAME key, so a region's preload and a
# notebook's parent pointing at one project still share the env (--project parity preserved); only the
# collision/pollution goes away. Empty path ⇒ the infra-only shared "detached" — nothing is replicated
# there, so there's nothing to pollute.
function _proj_key(p)
    s = String(p); isempty(s) && return "detached"
    ap = abspath(expanduser(s))
    replace(basename(rstrip(ap, '/')), r"[^A-Za-z0-9._-]" => "_") * "-" * bytes2hex(_SHA.sha1(codeunits(ap)))[1:8]
end
# A notebook's remote env dir: keyed by the content it REPLICATES (origin_env) when it has one, else its
# parent project — never the shared mutable dir when there's content to isolate.
_remote_env_key(origin_env, parent) = _proj_key(isempty(String(origin_env)) ? parent : origin_env)

# A region's RemoteTarget. Env dir keyed (isolated) by the preload PATH; `region` tags the worker so its
# OWN region reclaims it on adoption. For a :direct region, `port` carries base_port as the range HINT —
# fresh_spawn allocates a free slot from it (see _direct_port_slots) so the kernel lands in the
# firewall-opened range, not the growing auto counter.
_region_target(r::Region) = RemoteTarget(r.host; transport = r.transport,
    project = "~/.cache/kaimonslate/remote/" * _proj_key(r.preload),
    port = (r.transport === :direct ? r.base_port : 0),
    origin_env = r.preload, datadir = r.data_root, cache_root = r.cache_root, region = r.name,
    sysimage = r.sysimage, curve = r.curve)

# In-flight adoption claims (hub-local). Without a claim two notebooks opening at once could both scan
# the roster, see the same idle worker, and both adopt it.
const _REGION_CLAIMS = Set{Tuple{String,Int}}()
const _REGION_CLAIM_LOCK = ReentrantLock()
_region_claimed(host, port::Int) =
    lock(_REGION_CLAIM_LOCK) do; (String(host), port) in _REGION_CLAIMS; end
_release_region_claim!(host, port::Int) =
    (lock(_REGION_CLAIM_LOCK) do; delete!(_REGION_CLAIMS, (String(host), port)); end; nothing)

# A roster entry this hub can adopt for region `name`: alive, idle, ours, tagged with this region.
_region_warm_worker(w, name::AbstractString) =
    w["alive"] === true && get(w, "state", "") == "idle" &&
    _manifest_get(w["manifest"], "region") == String(name) &&
    _manifest_get(w["manifest"], "hub") == gethostname()

# Find + claim a warm worker for region `name` on `host`. First unclaimed wins — a region's warm
# workers are interchangeable. Returns (port, stream_port) | nothing.
function _claim_region_worker!(name::AbstractString, host)
    isempty(String(name)) && return nothing
    for w in list_remote_workers(host)
        _region_warm_worker(w, name) || continue
        sp = tryparse(Int, _manifest_get(w["manifest"], "stream_port")); sp === nothing && continue
        port = w["port"]
        claimed = lock(_REGION_CLAIM_LOCK) do
            (String(host), port) in _REGION_CLAIMS && return false
            push!(_REGION_CLAIMS, (String(host), port)); true
        end
        claimed || continue
        return (port = port, stream_port = sp)
    end
    return nothing
end

# region name → last reconcile outcome (ok?, message, when). A BACKGROUND reconcile that throws (host
# down / ssh banner timeout / provision error) would die silently in its @async task; the outcome lands
# here so the Regions UI can surface it.
const _REGION_STATUS = Dict{String,Any}()
_set_region_status!(name, ok::Bool, msg::AbstractString) =
    (_REGION_STATUS[String(name)] = (ok = ok, msg = String(msg), ts = time()); nothing)
region_status(name) = get(_REGION_STATUS, String(name), nothing)

# Drive a region's host toward its `warm` count (0 drains), recording the outcome for the UI. Safe to
# re-run — reconciles toward `warm`, re-reading the region definition from the registry each call.
function region_reconcile!(name)
    r = region_get(name)
    r === nothing && return "no region '$name'"
    isempty(r.host) && return "region '$(r.name)' has no host"
    try
        msg = _region_reconcile_impl!(r)
        _set_region_status!(r.name, true, msg)
        return msg
    catch e
        emsg = "reconcile failed — " * first(sprint(showerror, e), 140)
        _set_region_status!(r.name, false, emsg)
        _rlog("region[$(r.name)]: $emsg")
        rethrow()
    end
end

# Reconcile every region that keeps warm workers — the hub's desired-state driver.
reconcile_all_regions!() = for r in regions()
    r.warm > 0 && (try; region_reconcile!(r.name); catch; end)
end

# Reap this region's dead workers + idlers of an old preload env/transport, launch the deficit (one
# provision pass covers them all), trim excess idlers. Never touches an attached worker, a claimed
# worker, or another region's workers. Wrapped by `region_reconcile!`, which records the outcome.
function _region_reconcile_impl!(r::Region)
    host = r.host
    t = _region_target(r)
    roster = list_remote_workers(host)
    mine = [w for w in roster
            if _manifest_get(w["manifest"], "region") == r.name &&
               _manifest_get(w["manifest"], "hub") == gethostname()]
    # A region's def can change (new preload/transport) — its old idle workers still carry the region tag
    # but the wrong env dir/transport, so they can't serve it. `fits` distinguishes usable warm from stale.
    fits(w) = _manifest_get(w["manifest"], "project") == t.project &&
              _manifest_get(w["manifest"], "transport") == string(r.transport)
    dead  = [w for w in mine if w["alive"] !== true]
    stale = [w for w in mine if _region_warm_worker(w, r.name) && !fits(w) && !_region_claimed(host, w["port"])]
    for w in vcat(dead, stale)
        reap_remote_worker(host, w["port"])
    end
    warm = [w for w in mine if _region_warm_worker(w, r.name) && fits(w) && !_region_claimed(host, w["port"])]
    deficit = r.warm - length(warm)
    cleaned = isempty(dead) && isempty(stale) ? "" : " (cleaned $(length(dead)) dead, $(length(stale)) stale-env)"
    if deficit > 0
        provision_remote!(t, r.preload)              # idempotent; one pass covers every launch below
        # Ports for the new workers. A :direct region with a pinned base marches up from it in strides of
        # 3 (each worker owns port..port+2) so you know exactly which range to open in the firewall.
        # Otherwise (tunnel, or no base) auto-assign from _next_ports, floored above the live roster.
        ports = (r.transport === :direct && r.base_port > 0) ?
            _direct_port_slots(r.base_port, deficit; roster = roster, label = "region[$(r.name)]") :
            begin
                floor = _port_floor(host; workers = roster)   # never deal a live worker's ports (see _port_floor)
                [_next_ports(; floor) for _ in 1:deficit]
            end
        for (port, sp) in ports
            _launch_worker!(t, port, sp; label = "", parent = "", threads = r.threads,
                            warm = true, region = r.name, warm_deps = !isempty(r.preload))
        end
        return "region[$(r.name)]: launched $(length(ports)) worker(s) → $(r.warm) warm on $host$cleaned"
    elseif deficit < 0
        for w in warm[1:(-deficit)]
            reap_remote_worker(host, w["port"])
        end
        return "region[$(r.name)]: reaped $(-deficit) excess idle worker(s) → $(r.warm) warm$cleaned"
    end
    return "region[$(r.name)]: $(length(warm)) warm — nothing to do$cleaned"
end

# ── Parked connections (detach keeps the wire) ───────────────────────────────────────────────
# Closing a notebook DETACHES its remote worker (stays warm); parking ALSO keeps the hub side of
# the wire — the live ZMQ conn + supervised tunnel, keyed (host, label) — so the next open of
# that notebook skips tunnel setup AND the CURVE/dial handshake entirely (~5 RTTs ≈ 370ms on a
# measured WAN link → ~0). TTL-swept: a parked tunnel is a live ssh process, so idle parks close
# after KAIMONSLATE_PARK_TTL seconds (default 30min); the worker itself stays warm either way —
# expiry just demotes the next reattach to the record path.
mutable struct ParkedRemote
    conn::Any
    tunnel::Any
    port::Int
    stream_port::Int
    since::Float64
end

const _PARKED = Dict{Tuple{String,String},ParkedRemote}()
const _PARK_LOCK = ReentrantLock()
const _PARK_SWEEPER = Ref{Any}(nothing)

_park_ttl() = something(tryparse(Float64, get(ENV, "KAIMONSLATE_PARK_TTL", "")), 1800.0)

# Take ownership of the kernel's conn + tunnel at detach time. Returns true when parked (the
# caller must then NOT disconnect the conn or close the tunnel — the park owns them now).
function park_remote!(k)
    t = k.target
    (t isa RemoteTarget && k.conn !== nothing && k.port != 0) || return false
    lock(_PARK_LOCK) do
        old = pop!(_PARKED, (t.ssh_host, k.label), nothing)   # shouldn't exist — close is serialized
        old === nothing || _close_parked!(old)
        _PARKED[(t.ssh_host, k.label)] = ParkedRemote(k.conn, k.tunnel, k.port, k.stream_port, time())
    end
    _ensure_park_sweeper!()
    _rlog("park: keeping the wire to worker-$(k.port) on $(t.ssh_host) warm for '$(k.label)' (ttl $(round(Int, _park_ttl()))s)")
    return true
end

unpark_remote!(host, label) =
    lock(_PARK_LOCK) do; pop!(_PARKED, (String(host), String(label)), nothing); end

function _close_parked!(p::ParkedRemote)
    try; _kaimon().disconnect!(p.conn); catch; end
    p.tunnel === nothing || (try; close_tunnel(p.tunnel); catch; end)
    return nothing
end

# Kill-path hygiene: a parked wire to a worker that is being killed/reaped must not linger —
# match by label (teardown kill) or by port (reap from the roster).
function _evict_parked!(host; port::Int = 0, label::AbstractString = "")
    lock(_PARK_LOCK) do
        for key in collect(keys(_PARKED))
            key[1] == String(host) || continue
            p = _PARKED[key]
            ((!isempty(label) && key[2] == String(label)) || (port != 0 && p.port == port)) || continue
            delete!(_PARKED, key)
            _close_parked!(p)
            _rlog("park: evicted wire to worker-$(p.port) on $host ('$(key[2])')")
        end
    end
    return nothing
end

function _ensure_park_sweeper!()
    _PARK_SWEEPER[] === nothing || return nothing
    _PARK_SWEEPER[] = Timer(60.0; interval = 60.0) do _
        try
            ttl = _park_ttl()
            lock(_PARK_LOCK) do
                for key in collect(keys(_PARKED))
                    p = _PARKED[key]
                    time() - p.since > ttl || continue
                    delete!(_PARKED, key)
                    _close_parked!(p)
                    _rlog("park: TTL expired — wire to worker-$(p.port) on $(key[1]) closed (worker stays warm; next open uses the record)")
                end
            end
        catch
        end
    end
    return nothing
end

# The probe (one POSIX-sh command string, sent as a SINGLE ssh argv token like the launch line)
# that enumerates workers: for each `worker-<port>.json` it emits port, liveness (pgrep), the
# log's mtime (last activity) and size, the state sidecar, and the raw manifest — delimited with
# control chars (printf octal escapes) and wrapped in sentinels so incidental login-shell stdout
# can't corrupt it. This USED to ship a Julia script and boot `julia` on the host per call — ~3s,
# measured, sitting directly on the reattach path; sh answers in one round-trip. Portability:
# `stat -c` (GNU/Linux) with a `-f` (BSD/macOS) fallback; `setopt nonomatch` disarms zsh's
# error-on-unmatched-glob for the empty-dir case (harmless no-op elsewhere).
const _WORKERS_PROBE_SH = raw"""
setopt nonomatch 2>/dev/null || true
cd "$HOME/REMOTE_WORKER_DIR" 2>/dev/null || { printf '\002\003'; exit 0; }
printf '\002'
for f in worker-*.json; do
  [ -f "$f" ] || continue
  port="${f#worker-}"; port="${port%.json}"
  alive=0; pgrep -f "worker-$port.jl" >/dev/null 2>&1 && alive=1
  sz=0; mt=0
  if [ -f "worker-$port.log" ]; then
    sz=$(wc -c < "worker-$port.log" | awk '{print $1+0}')
    mt=$(stat -c %Y "worker-$port.log" 2>/dev/null || stat -f %m "worker-$port.log" 2>/dev/null || echo 0)
  fi
  st=""; [ -f "worker-$port.state" ] && st=$(cat "worker-$port.state" 2>/dev/null)
  body=$(tr -d '\n\r' < "$f" 2>/dev/null); [ -n "$body" ] || body='{}'
  tj=""; [ -f "worker-$port.stats" ] && tj=$(tr -d '\n\r' < "worker-$port.stats" 2>/dev/null)
  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\036' "$port" "$alive" "$mt" "$sz" "$st" "$body" "$tj"
done
printf '\003'
"""

"""
    list_remote_workers(host) -> Vector{Dict}

Enumerate the workers Slate has spawned on `host`, each: `port`, `alive` (process running), `lastActivity`
(unix mtime of its log = last computation), `logBytes`, `state`/`stateSince` (lifecycle sidecar:
"attached"/"idle" + unix ts; "" for a pre-sidecar worker — advisory, a hub crash leaves a stale
"attached"), `manifest` (raw JSON string — the browser parses it for who/what/when), and `stats`
(the worker's latest 2s telemetry sample: cpu/rss/gc_ms/evals/memo_bytes/ts as raw JSON; "" for a
pre-telemetry worker). Reads the on-host manifests over one ssh call. `[]` if unreachable/none.
"""
function list_remote_workers(host)
    sh = replace(_WORKERS_PROBE_SH, "REMOTE_WORKER_DIR" => _REMOTE_WORKER)
    ok, out = _ssh_capture(host, `$sh`)   # one token → the remote login shell runs the script verbatim
    ok || return Any[]
    i = findfirst('\x02', out); j = findlast('\x03', out)
    (i === nothing || j === nothing || j <= i) && return Any[]
    payload = out[nextind(out, i):prevind(out, j)]
    workers = Any[]
    for rec in split(payload, '\x1e'; keepempty = false)
        parts = split(rec, '\x1f')
        length(parts) >= 6 || continue
        port = tryparse(Int, strip(parts[1])); port === nothing && continue
        # state sidecar: "attached 1783659480" / "idle 1783659480" / "" (pre-sidecar worker)
        sw = split(strip(parts[5]))
        push!(workers, Dict{String,Any}(
            "port" => port,
            "alive" => strip(parts[2]) == "1",
            "lastActivity" => something(tryparse(Int, strip(parts[3])), 0),
            "logBytes" => something(tryparse(Int, strip(parts[4])), 0),
            "state" => isempty(sw) ? "" : String(sw[1]),
            "stateSince" => length(sw) > 1 ? something(tryparse(Int, sw[2]), 0) : 0,
            "manifest" => String(strip(parts[6])),
            # latest telemetry sample (raw JSON from the worker's 2s sampler; "" pre-telemetry)
            "stats" => length(parts) >= 7 ? String(strip(parts[7])) : "",
        ))
    end
    return workers
end

# Pull one value out of a flat manifest JSON string (no JSON dep — the manifest is a flat "k":"v" object
# we wrote ourselves; a regex is enough and avoids a parser on this path).
function _manifest_get(json::AbstractString, key::AbstractString)
    m = match(Regex("\"" * key * "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""), json)
    m === nothing ? "" : replace(replace(m.captures[1], "\\\"" => "\""), "\\\\" => "\\")
end

# The first auto-assign port safely ABOVE everything the host's roster occupies (each worker owns
# port..port+2). Warm workers survive an extension restart — which resets the local port counter —
# so a fresh spawn must not trust the counter alone: without this floor it re-deals a live worker's
# ports and the new worker dies at boot on ZMQ bind. `workers` = a roster already in hand (avoid a
# second ssh probe), else it's fetched.
function _port_floor(host; workers = nothing)
    ws = workers === nothing ? list_remote_workers(host) : workers
    top = 0
    for w in ws
        w["alive"] === true || continue        # a dead worker's ports are free
        top = max(top, Int(w["port"]) + 2)
    end
    return top == 0 ? 0 : top + 1
end

# Find a LIVE worker on `host` already serving this exact notebook (same label + parent) spawned by THIS
# hub — the reconnect target. Returns (port, stream_port) or nothing. Conservative: only a single,
# unambiguous, alive, same-hub match reattaches; anything else spawns fresh.
function _find_live_worker(host, label, parent)
    matches = Tuple{Int,Int}[]
    for w in list_remote_workers(host)
        w["alive"] === true || continue
        mf = w["manifest"]
        (_manifest_get(mf, "notebook") == String(label) &&
         _manifest_get(mf, "parent") == String(parent) &&
         _manifest_get(mf, "hub") == gethostname()) || continue
        sp = tryparse(Int, _manifest_get(mf, "stream_port")); sp === nothing && continue
        push!(matches, (w["port"], sp))
    end
    length(matches) == 1 || return nothing
    return (port = matches[1][1], stream_port = matches[1][2])
end

# Evict any ConnectionManager entry the hub still holds for worker `host:port`. A superseded or
# reaped worker whose wire lingers in a live status (:connected/:stalled) makes `connect_tcp!` refuse
# every reconnect with "Already connected" — it won't replace a live-status corpse, so the reconnect
# path re-probes, finds the worker live, re-dials, and loops forever (the recurring "duplicate dial"
# in the logs). `disconnect!` marks the entry :disconnected; `connect_tcp!` then reaps the corpse and
# builds fresh. Matched by the name `spawn_and_connect_remote!` assigns each worker wire
# ("slate-<host>-<port>") — exact per worker, never a same-port worker on another host. Called BOTH on
# reap (mark it dead everywhere) and self-healingly in the dial loop when "Already connected" is hit.
function _evict_worker_conn!(host, port::Int)
    nm = "slate-$(host)-$(port)"
    mgr = try; _manager(); catch; return 0; end
    K = _kaimon()
    stale = try
        lock(mgr.lock) do; [c for c in mgr.connections if getfield(c, :name) == nm]; end
    catch
        return 0
    end
    for c in stale
        st = try; getfield(c, :status); catch; "?"; end
        try; K.disconnect!(c); catch; end
        _rlog("evicted stale hub connection '$nm' (was $st) — worker superseded/reaped")
    end
    return length(stale)
end

"""
    reap_remote_worker(host, port) -> Bool

Explicitly kill the worker on `host:port` and remove its script/log/manifest. Manual only — Slate
never auto-reaps (a worker may hold results worth keeping). Returns true if the kill+cleanup ran.
"""
function reap_remote_worker(host, port::Int)
    _rlog("reap: killing worker-$port on $host (manual)")
    try; _evict_parked!(host; port = port); catch; end        # a parked wire to it must die too
    try; _evict_worker_conn!(host, port); catch; end          # …and any non-parked hub wire (warm/reconnect) — else a respawn on this port hits "Already connected"
    try; _peer_route_forget!(host); catch; end                # …and any cached peer-route verdict touching this host (topology changed)
    # NOTE: the mesh-grant permitopen cache is deliberately NOT cleared here — `_mesh_finalize_port!`
    # self-corrects (re-installs when the live blob port differs from the cached one), so a respawn on a
    # new port is caught on the next transfer; clearing it would drop the "introduced" signal and skip the
    # finalize. It's cleared only on region teardown.
    try; _evict_data_tunnels!(host; port = port + 2); catch; end
    try; _release_pool_claim!(host, port); catch; end
    # SIGTERM (graceful) then SIGKILL after a short grace. A FROZEN or wedged worker — exactly the kind a
    # supersede-reap targets — never processes SIGTERM (a stopped process queues it; a signal-ignoring one
    # drops it), so the SIGKILL escalation is what actually frees its LISTEN port and RAM. Synchronous, so
    # by the time a cold spawn reuses this port the old holder is gone (no "address already in use").
    let pat = "worker-$(port).jl"
        try; _ssh_test(host, `sh -c $("pkill -TERM -f '$pat'; sleep 1; pkill -KILL -f '$pat'; true")`); catch; end
    end
    try; _ssh_ok(host, `rm -f $("$_REMOTE_WORKER/worker-$port.jl") $("$_REMOTE_WORKER/worker-$port.log") $("$_REMOTE_WORKER/worker-$port.json") $("$_REMOTE_WORKER/worker-$port.state") $("$_REMOTE_WORKER/worker-$port.stats")`); catch; end
    return true
end
