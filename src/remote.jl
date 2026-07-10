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

function _rlog(msg::AbstractString)
    try
        mkpath(dirname(_REMOTE_LOG))
        open(_REMOTE_LOG, "a") do io
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
end
RemoteTarget(ssh_host::AbstractString; transport::Symbol = :tunnel,
             project::AbstractString = "~/.cache/kaimonslate/remote",
             port::Int = 0, stream_port::Int = 0, origin_env::AbstractString = "") =
    RemoteTarget(String(ssh_host), transport, String(project), port, stream_port, String(origin_env))

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
    return ["-o", "ControlMaster=auto", "-o", "ControlPath=$d/%C", "-o", "ControlPersist=120"]
end

# rsync's `-e` value is whitespace-tokenized by rsync itself, so a mux path containing a space
# (an exotic $HOME) would mangle it — in that case rsync just runs unmuxed.
function _rsync_ssh_opt()
    opts = _ssh_mux_opts()
    (isempty(opts) || any(o -> occursin(' ', o), opts)) && return String[]
    return ["-e", "ssh -o BatchMode=yes " * join(opts, " ")]
end

_ssh(host, argv::Cmd) = `ssh -o BatchMode=yes -o ConnectTimeout=15 $(_ssh_mux_opts()) $host $argv`

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
    _ssh_ok(host, `mkdir -p $_REMOTE_ROOT`) || return (false, "")
    tmp = tempname()
    write(tmp, code)
    remote = "$_REMOTE_ROOT/$(basename(tmp)).jl"
    scp_ok = try
        run(pipeline(`scp -q $(_ssh_mux_opts()) $tmp $(string(host, ":", remote))`; stdout = devnull, stderr = devnull)); true
    catch; false; end
    rm(tmp; force = true)
    scp_ok || (_rlog("FAILED: scp provisioning script → $host ($what)"); return (false, ""))
    ok, out = _run_logged(_ssh(host, `julia --startup-file=no $remote`), what)
    try; run(pipeline(_ssh(host, `rm -f $remote`); stdout = devnull, stderr = devnull)); catch; end
    return (ok, out)
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
        "[Pkg.PackageSpec(name=\"KaimonGate\"), Pkg.PackageSpec(name=\"ExpressionExplorer\"), Pkg.PackageSpec(name=\"Revise\")]" :
        "[Pkg.PackageSpec(name=\"KaimonGate\"), Pkg.PackageSpec(name=\"ExpressionExplorer\")]"
    if !isempty(t.origin_env) && isfile(joinpath(t.origin_env, "Project.toml"))
        _replicate_env!(t)                                    # notebook env + worker infra
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
    _rlog("provision DONE host=$host")
    return nothing
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
the Manifest to point there, then instantiate. The Manifest makes registry versions exact and clones git
deps from their recorded urls; the dev-source rsync makes local checkouts resolve on the host.
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
    ok, out = _ssh_julia!(host, _env_instantiate_script(projrel, rewrites, _local_has_revise()), "instantiate replicated env on $host")
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
    return """
    _wk = joinpath(homedir(), raw"$_REMOTE_WORKER", "worker.jl")
    import KaimonGate
    try; @eval using Revise; catch; end
    include(_wk)
    SlateWorker.PARENT_PROJECT[] = raw"$parent"
    SlateWorker.start(; host="$bind", port=$port, stream_port=$stream_port,
                      curve=$curve, allowed_clients=$allow, data_port=$(port + 2),
                      warm_deps=$warm_deps,
                      stats_path=joinpath(homedir(), raw"$_REMOTE_WORKER", "worker-$port.stats"))
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
                         threads::AbstractString = "", pool::Bool = false,
                         warm_deps::Bool = false)
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
    jl = "julia --project=$proj --startup-file=no --threads=$nthreads $remote_script"
    launch = "cd \$HOME && if command -v setsid >/dev/null 2>&1; then setsid nohup $jl > $logf 2>&1 & else nohup $jl > $logf 2>&1 & fi"
    _rlog("spawn: launching $(pool ? "POOL " : "")worker on $host  (port=$port stream=$stream_port threads=$nthreads)\n    remote log: $host:$logf")
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
    pool && push!(fields, "pool" => "1")
    _write_worker_manifest!(host, port, fields)
    _write_worker_state!(host, port, pool ? "idle" : "attached")
    return nothing
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
        while time() - t0 < deadline
            tries += 1
            try
                conn = K.connect_tcp!(_manager(), connect_host, connect_port;
                                      name = "slate-$(host)-$(port)", stream_port = connect_stream,
                                      server_key = server_key, label = k.label)
                break
            catch e
                last = sprint(showerror, e); sleep(0.25)
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
    function attached!(r, via::String)
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
        r = dial(rec.port, rec.stream_port; deadline = 5.0,
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
        r = dial(k.port, k.stream_port; deadline = 15.0)
        r.conn !== nothing && return attached!(r, "probe")
        _rlog("reconnect: live worker-$(k.port) didn't answer the 15s dial — falling back to a fresh spawn")
    end

    # 2.5 Adoption: no worker of OURS is serving this notebook — but a warm POOL worker with the
    #     right env + transport can become ours: dial it, have it swap in a fresh namespace
    #     (loaded packages + memo store survive — the warmth the pool exists to hold), rewrite
    #     its manifest to this notebook. Any failure falls through to a fresh spawn. The claim
    #     set stops two notebooks opening concurrently from adopting the same worker.
    pool = nothing
    try; pool = _claim_pool_worker!(host, t.project, t.transport); catch e; _rlog("adopt: pool scan failed ($(sprint(showerror, e)))"); end
    if pool !== nothing
        k.port = pool.port; k.stream_port = pool.stream_port
        _rlog("adopt: pool worker-$(pool.port) on $host matches env $(t.project) — adopting for '$(k.label)'")
        r = dial(pool.port, pool.stream_port; deadline = 15.0)
        adopted = false
        if r.conn !== nothing
            adopted = try
                k.conn = r.conn                     # _tool needs the conn on the kernel
                _tool(k, "__slate_adopt", Dict{String,Any}("parent" => t.project); timeout = 15.0)
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
                        "client_pubkey" => _hub_client_pubkey(),
                        "spawned" => Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"), "adopted" => "1",
                    ])
                catch e
                    _rlog("adopt: manifest rewrite failed ($(sprint(showerror, e)))")
                end
                # claim held until the manifest no longer says pool=1 — else a concurrent open
                # could rescan the roster mid-rewrite and adopt this worker a second time
                _release_pool_claim!(host, port)
                try; _pool_reconcile!(host); catch e; _rlog("pool: replenish after adopt failed ($(sprint(showerror, e)))"); end
            end
            return attached!(r, "adopt")
        end
        _release_pool_claim!(host, pool.port)
        k.conn = nothing
    end

    provision_remote!(t, parent_project)
    start_sync!(t, parent_project)
    begin
        # Remote ports for this worker (loopback-bound for :tunnel, 0.0.0.0 for :direct). Pinned when the
        # target names them (needed for :direct behind a firewall — you must know which ports to open);
        # otherwise auto-assigned from _next_ports (9100+), floored above the host's live roster.
        port, stream_port = t.port != 0 ? (t.port, t.stream_port != 0 ? t.stream_port : t.port + 1) :
                            _next_ports(floor = try; _port_floor(host); catch; 0; end)
        k.port = port; k.stream_port = stream_port
        _launch_worker!(t, port, stream_port; label = k.label, parent = k.parent, threads = k.threads)

        # Cold spawn: the dial deadline covers remote Julia boot + KaimonGate load (~90s).
        r = dial(port, stream_port; deadline = 120.0)
        r.conn === nothing && error("slate remote: could not reach worker on $host:$port ($(r.err))")
        _attach_record!(host, k.label; port = port, stream_port = stream_port,
                        transport = t.transport, server_key = r.server_key, remote_ip = r.remote_ip)
        _rlog("connect OK: attached to worker on $host:$port → notebook now runs on $host")
        return (r.conn, r.tunnel)
    end
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
        okj, out = _ssh_capture(host, `julia --version`)
        okj ? ("ok", strip(out)) :
            ("fail", "`julia` not on PATH on '$host' — install juliaup (`curl -fsSL https://install.julialang.org | sh`) or add it to the login PATH")
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
# Bytes per REQ/REP round-trip. Bigger chunks amortize the RTT (throughput); smaller ones keep
# a slow uplink responsive — each chunk is the granularity at which the strict REQ/REP channel
# yields (and at which a timeout/cancel can cut in), so on a thin link small chunks stop one
# push from monopolizing the wire in long bursts. Panel setting (the Ref, persisted to
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

function push_memo_blobs!(host_ip::AbstractString, data_port::Int, srckeys::Vector{String};
                          timeout_ms::Int = 20_000, server_key::AbstractString = "",
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
            sz = filesize(p)
            if v2 && sz > 0
                mm = Mmap.mmap(p, Vector{UInt8}, sz)
                off = 0
                chunk = _blob_chunk()
                while off < sz
                    n = min(chunk, sz - off)
                    last = off + n >= sz
                    hdr = vcat(UInt8['p'], Vector{UInt8}(codeunits(String(h))), UInt8[last ? 0x01 : 0x00])
                    Z.send(sock, hdr; more = true)
                    # zero-copy payload frame: libzmq sends straight out of the mmap; `mm` is the
                    # origin object ZMQ protects until the frame is out (REQ/REP: by the reply).
                    Z.send(sock, Z.Message(mm, pointer(mm) + off, n))
                    r = String(copy(Z.recv(sock)))
                    startswith(r, "err") && error("memo push $h: $r")
                    nbytes += n; off += n
                end
            else
                open(p, "r") do io
                    while true
                        chunk = read(io, 1 << 20)
                        last = eof(io)
                        r = req(vcat(UInt8['P'], Vector{UInt8}(codeunits(String(h))), UInt8[last ? 0x01 : 0x00], chunk))
                        startswith(r, "err") && error("memo push $h: $r")
                        nbytes += length(chunk)
                        last && break
                    end
                end
            end
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

function _data_endpoint!(t::RemoteTarget, k)
    dport = k.port + 2
    if t.transport === :direct
        rec = _attach_lookup(t.ssh_host, k.label)   # ip + CURVE key were learned at spawn — no ssh here
        ip = rec !== nothing && !isempty(rec.remote_ip) ? String(rec.remote_ip) : _remote_ip(t.ssh_host)
        key = rec !== nothing ? String(rec.server_key) : ""
        return (ip = ip, port = dport, server_key = key)
    end
    lock(_DATA_TUNNEL_LOCK) do
        cached = get(_DATA_TUNNELS, (t.ssh_host, dport), nothing)
        cached !== nothing && cached[1].running &&
            return (ip = "127.0.0.1", port = cached[2], server_key = "")
        lport = _free_local_port()
        tun = open_tunnel(t.ssh_host, [(lport, dport)])
        _DATA_TUNNELS[(t.ssh_host, dport)] = (tun, lport)
        _rlog("data channel: opened dedicated tunnel $(t.ssh_host):$dport ← 127.0.0.1:$lport (own ssh proc)")
        return (ip = "127.0.0.1", port = lport, server_key = "")
    end
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

const _POOL_DIR = joinpath(_slate_cache_dir(), "pool")
_pool_path(host) = joinpath(_POOL_DIR, replace(String(host), r"[^A-Za-z0-9._-]" => "_") * ".json")

function _pool_config!(host; n::Int, preload::AbstractString, transport::Symbol)
    esc(s) = replace(String(s), "\\" => "\\\\", "\"" => "\\\"")
    body = "{\"host\":\"$(esc(host))\",\"n\":\"$n\",\"preload\":\"$(esc(preload))\",\"transport\":\"$transport\"}"
    mkpath(_POOL_DIR)
    p = _pool_path(host); tmp = p * ".tmp"
    write(tmp, body); mv(tmp, p; force = true)
    return nothing
end

function _pool_config(host)
    p = _pool_path(host)
    isfile(p) || return nothing
    s = try; read(p, String); catch; return nothing; end
    n = tryparse(Int, _manifest_get(s, "n")); n === nothing && return nothing
    tr = _manifest_get(s, "transport")
    return (n = n, preload = _manifest_get(s, "preload"),
            transport = Symbol(isempty(tr) ? "tunnel" : tr))
end

# Every configured pool, host included — the hub's desired state (what `warm_pool!` was told),
# NOT the live roster (ask `list_remote_workers` for that). Sorted by host for stable output.
function pool_configs()
    out = NamedTuple[]
    isdir(_POOL_DIR) || return out
    for f in sort!(readdir(_POOL_DIR; join = true))
        endswith(f, ".json") || continue
        s = try; read(f, String); catch; continue; end
        h = _manifest_get(s, "host"); isempty(h) && continue
        cfg = _pool_config(h); cfg === nothing && continue
        push!(out, (host = h, n = cfg.n, preload = cfg.preload, transport = cfg.transport))
    end
    return out
end

# Snapshot of the parked wires (host, label, port, idle seconds) — for the query surface.
function parked_wires()
    lock(_PARK_LOCK) do
        [(host = k[1], label = k[2], port = p.port, idle_s = round(Int, time() - p.since))
         for (k, p) in _PARKED]
    end
end

# The pool's RemoteTarget: env dir keyed by the preload project's basename — the SAME formula
# `_select_kernel` uses for a notebook's parent (server.jl), which is exactly what makes a pool
# worker adoptable: matching basename ⇒ matching remote env dir ⇒ matching --project.
_pool_target(host, cfg) = RemoteTarget(String(host); transport = cfg.transport,
    project = "~/.cache/kaimonslate/remote/" * (isempty(cfg.preload) ? "detached" : basename(rstrip(cfg.preload, '/'))),
    origin_env = cfg.preload)

# In-flight adoption claims (hub-local — only THIS hub adopts its own pool workers). The state
# sidecar flips to `attached` asynchronously after adoption, so without a claim two notebooks
# opening at once could both scan the roster, see the same idle worker, and both reset it.
const _POOL_CLAIMS = Set{Tuple{String,Int}}()
const _POOL_CLAIM_LOCK = ReentrantLock()

_pool_claimed(host, port::Int) =
    lock(_POOL_CLAIM_LOCK) do; (String(host), port) in _POOL_CLAIMS; end
_release_pool_claim!(host, port::Int) =
    (lock(_POOL_CLAIM_LOCK) do; delete!(_POOL_CLAIMS, (String(host), port)); end; nothing)

# Is this roster entry a pool worker THIS hub could adopt at all (alive, idle, ours)? The
# env/transport fit is `_adoptable` — split so the claim loop can log near-misses.
_pool_candidate(w) =
    w["alive"] === true && get(w, "state", "") == "idle" &&
    _manifest_get(w["manifest"], "pool") == "1" &&
    _manifest_get(w["manifest"], "hub") == gethostname()

# Does a candidate FIT this notebook: same env dir (--project is fixed at boot) and same
# transport (bind address/CURVE mode is fixed at boot)?
_adoptable(w, rproj, transport::Symbol) =
    _manifest_get(w["manifest"], "transport") == string(transport) &&
    _manifest_get(w["manifest"], "project") == String(rproj)

# Find + claim an adoptable pool worker. First unclaimed match wins — pool members are
# interchangeable. Returns (port, stream_port) | nothing.
function _claim_pool_worker!(host, rproj, transport::Symbol)
    seen = 0   # pool members that were alive+idle but didn't fit — logged so a mismatch isn't silent
    for w in list_remote_workers(host)
        _pool_candidate(w) || continue
        seen += 1
        _adoptable(w, rproj, transport) || continue
        sp = tryparse(Int, _manifest_get(w["manifest"], "stream_port")); sp === nothing && continue
        port = w["port"]
        claimed = lock(_POOL_CLAIM_LOCK) do
            (String(host), port) in _POOL_CLAIMS && return false
            push!(_POOL_CLAIMS, (String(host), port)); true
        end
        claimed || continue
        return (port = port, stream_port = sp)
    end
    seen > 0 && _rlog("adopt: $seen warm pool worker(s) on $host, but none match env=$rproj transport=$transport — check warm_pool!'s preload (its basename must equal the notebook's parent project's)")
    return nothing
end

"""
    warm_pool!(host; n = 1, preload = "", transport = :tunnel) -> String

Keep `n` warm Slate workers on `host`, ready for instant adoption: each is a running Julia
process with the gate serving and the eval path prewarmed; `preload` (a local project dir)
additionally replicates that env remotely and imports its packages while idle — so a notebook
whose parent is that project opens in ~a second instead of ~90. Adoption wipes only the
namespace; packages and the memo store survive. The pool refills itself after every adoption.
`n = 0` drains: idle pool workers are reaped (attached/adopted ones are never touched).
Blocking (provision + launch); safe to re-run — it reconciles toward `n`.
"""
function warm_pool!(host::AbstractString; n::Int = 1, preload::AbstractString = "",
                    transport::Symbol = :tunnel)
    h = String(strip(String(host)))
    isempty(h) && return "give an ssh host"
    n >= 0 || return "n must be ≥ 0"
    transport in (:tunnel, :direct) || return "transport must be :tunnel or :direct"
    pl = strip(String(preload))
    pl = isempty(pl) ? "" : abspath(expanduser(String(pl)))
    (isempty(pl) || isdir(pl)) || return "preload project dir not found: $pl"
    _pool_config!(h; n = n, preload = pl, transport = transport)
    _rlog("═══ WARM POOL: $h → n=$n preload=$(isempty(pl) ? "(none)" : pl) transport=$transport ═══")
    return _pool_reconcile!(h)
end

# Drive the host toward the configured pool size: reap dead pool litter and stale-env idlers,
# launch the deficit (one provision pass covers them all), trim any excess idlers. Never touches
# an attached worker, a claimed worker, or anything not pool-tagged by this hub.
function _pool_reconcile!(host)
    cfg = _pool_config(host)
    cfg === nothing && return "no pool configured for '$host' — call warm_pool!(host; n, preload)"
    t = _pool_target(host, cfg)
    roster = list_remote_workers(host)
    mine = [w for w in roster
            if _manifest_get(w["manifest"], "pool") == "1" &&
               _manifest_get(w["manifest"], "hub") == gethostname()]
    dead  = [w for w in mine if w["alive"] !== true]
    stale = [w for w in mine if _pool_candidate(w) && !_adoptable(w, t.project, cfg.transport) &&
                                !_pool_claimed(host, w["port"])]
    for w in vcat(dead, stale)                       # litter: dead members + idlers of an old preload env/transport
        reap_remote_worker(host, w["port"])
    end
    warm = [w for w in mine if _pool_candidate(w) && _adoptable(w, t.project, cfg.transport) &&
                               !_pool_claimed(host, w["port"])]
    deficit = cfg.n - length(warm)
    cleaned = isempty(dead) && isempty(stale) ? "" : " (cleaned $(length(dead)) dead, $(length(stale)) stale-env)"
    if deficit > 0
        provision_remote!(t, cfg.preload)            # idempotent; one pass covers every launch below
        floor = _port_floor(host; workers = roster)  # never deal a live worker's ports (see _port_floor)
        for _ in 1:deficit
            port, sp = _next_ports(; floor)
            _launch_worker!(t, port, sp; label = "", parent = "", pool = true,
                            warm_deps = !isempty(cfg.preload))
        end
        return "pool[$host]: launched $deficit worker(s) → $(cfg.n) warm, env $(t.project)$cleaned"
    elseif deficit < 0
        for w in warm[1:(-deficit)]
            reap_remote_worker(host, w["port"])
        end
        return "pool[$host]: reaped $(-deficit) excess idle worker(s) → $(cfg.n) warm$cleaned"
    end
    return "pool[$host]: $(length(warm)) warm — nothing to do$cleaned"
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

"""
    reap_remote_worker(host, port) -> Bool

Explicitly kill the worker on `host:port` and remove its script/log/manifest. Manual only — Slate
never auto-reaps (a worker may hold results worth keeping). Returns true if the kill+cleanup ran.
"""
function reap_remote_worker(host, port::Int)
    _rlog("reap: killing worker-$port on $host (manual)")
    try; _evict_parked!(host; port = port); catch; end        # a parked wire to it must die too
    try; _evict_data_tunnels!(host; port = port + 2); catch; end
    try; _release_pool_claim!(host, port); catch; end
    try; _ssh_test(host, `pkill -f $("worker-" * string(port) * ".jl")`); catch; end
    try; _ssh_ok(host, `rm -f $("$_REMOTE_WORKER/worker-$port.jl") $("$_REMOTE_WORKER/worker-$port.log") $("$_REMOTE_WORKER/worker-$port.json") $("$_REMOTE_WORKER/worker-$port.state") $("$_REMOTE_WORKER/worker-$port.stats")`); catch; end
    return true
end
