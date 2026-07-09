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
    _ssh_ok(host, `mkdir -p $_REMOTE_ROOT`) || return (false, "")
    tmp = tempname()
    write(tmp, code)
    remote = "$_REMOTE_ROOT/$(basename(tmp)).jl"
    scp_ok = try
        run(pipeline(`scp -q $tmp $(string(host, ":", remote))`; stdout = devnull, stderr = devnull)); true
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
    # In every case the worker's env (t.project) ends up with KaimonGate — plus Revise IF the user uses it
    # locally — resolved TOGETHER with whatever else is there (one env, no stacked-env skew).
    rel = startswith(t.project, "~/") ? t.project[3:end] : t.project
    infra = _local_has_revise() ? "[Pkg.PackageSpec(name=\"KaimonGate\"), Pkg.PackageSpec(name=\"Revise\")]" :
                                  "[Pkg.PackageSpec(name=\"KaimonGate\")]"
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
    infra = add_revise ? "[Pkg.PackageSpec(name=\"KaimonGate\"), Pkg.PackageSpec(name=\"Revise\")]" :
                         "[Pkg.PackageSpec(name=\"KaimonGate\")]"
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
    # versions (no stacked-env skew). KaimonGate is always needed (the gate); Revise only if the user
    # uses it locally (see `_local_has_revise` at the call site) — mirror their setup, don't force it.
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
                               client_pub::String)
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

    # Reconnect-first: if a LIVE worker for this same notebook already exists on the host (e.g. after an
    # extension restart or a network blip), REATTACH to it — preserving its warm namespace + results and
    # skipping a costly re-spawn/re-precompile — rather than spawning a new one (which would orphan the old).
    reattach = nothing
    try; reattach = _find_live_worker(host, k.label, k.parent); catch; end
    if reattach !== nothing
        port, stream_port = reattach.port, reattach.stream_port
        k.port = port; k.stream_port = stream_port
        _rlog("reconnect: reattaching to live worker-$port on $host (notebook=$(k.label)) — skipping spawn")
    else
        # Remote ports for this worker (loopback-bound for :tunnel, 0.0.0.0 for :direct). Pinned when the
        # target names them (needed for :direct behind a firewall — you must know which ports to open);
        # otherwise auto-assigned from _next_ports (9100+).
        port, stream_port = t.port != 0 ? (t.port, t.stream_port != 0 ? t.stream_port : t.port + 1) : _next_ports()
        k.port = port; k.stream_port = stream_port
        script = _remote_worker_script(t, port, stream_port, t.project, _hub_client_pubkey())

        # Ship the worker script as a FILE (verified: `-e` + nested-ssh quoting mangles it) and launch it
        # detached so it outlives the ssh exec. `setsid` gives a clean new session but is Linux-only
        # (absent on macOS), so we fall back to plain `nohup … &`, which — with stdio redirected to the
        # log file — also survives the ssh channel closing. Paths are $HOME-relative (ssh login cwd).
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
        jl = "julia --project=$proj --startup-file=no --threads=$threads $remote_script"
        launch = "cd \$HOME && if command -v setsid >/dev/null 2>&1; then setsid nohup $jl > $logf 2>&1 & else nohup $jl > $logf 2>&1 & fi"
        _rlog("spawn: launching worker on $host  (port=$port stream=$stream_port threads=$threads)\n    remote log: $host:$logf")
        # Pass the whole launch line as ONE ssh arg → the remote login shell parses `&&`/`>`/`&`/`$HOME` intact.
        # (`sh -c $launch` would be re-flattened by ssh into separate tokens and mis-parsed.)
        _ssh_ok(host, `$launch`) ||
            _rlog("spawn: worker launch returned nonzero on $host (it may still be starting)")
        # Record who/what this worker serves so it's self-describing (list/reconnect/reap all read this).
        _write_worker_manifest!(host, port, [
            "notebook" => k.label, "parent" => k.parent, "hub" => gethostname(),
            "transport" => string(t.transport), "port" => string(port), "stream_port" => string(stream_port),
            "client_pubkey" => _hub_client_pubkey(), "spawned" => Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"),
        ])
    end

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
            # Drop the manifest + script so a deliberately-closed worker doesn't linger in the registry
            # list (keep the .log for post-mortem). Full removal is the explicit `reap_remote_worker`.
            try; _ssh_test(t.ssh_host, `rm -f $("$_REMOTE_WORKER/worker-$(k.port).jl") $("$_REMOTE_WORKER/worker-$(k.port).json")`); catch; end
        else
            _rlog("teardown: closing tunnel + sync on $(t.ssh_host) (no worker was spawned)")
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
            try; shutdown!(k); catch; end   # closes tunnel, kills probe worker, stops sync
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

# The probe (shipped as a file, run on the host) that enumerates workers: for each `worker-<port>.json`
# it emits port, liveness (pgrep), the log's mtime (last activity) and size, and the raw manifest —
# delimited with control chars and wrapped in sentinels so incidental stdout noise can't corrupt it.
const _WORKERS_PROBE = raw"""
    dir = joinpath(homedir(), "REMOTE_WORKER_DIR")
    print("\x02")
    if isdir(dir)
        for f in sort(readdir(dir))
            (startswith(f, "worker-") && endswith(f, ".json")) || continue
            port = replace(replace(f, "worker-" => ""), ".json" => "")
            body = try; replace(read(joinpath(dir, f), String), r"[\r\n]" => " "); catch; "{}"; end
            logf = joinpath(dir, "worker-" * port * ".log")
            lastact = isfile(logf) ? round(Int, mtime(logf)) : 0
            logsz = isfile(logf) ? filesize(logf) : 0
            alive = try; success(pipeline(`pgrep -f $("worker-" * port * ".jl")`; stdout = devnull, stderr = devnull)); catch; false; end
            print(port, "\x1f", alive ? "1" : "0", "\x1f", lastact, "\x1f", logsz, "\x1f", body, "\x1e")
        end
    end
    print("\x03")
    """

"""
    list_remote_workers(host) -> Vector{Dict}

Enumerate the workers Slate has spawned on `host`, each: `port`, `alive` (process running), `lastActivity`
(unix mtime of its log = last computation), `logBytes`, and `manifest` (raw JSON string — the browser
parses it for who/what/when). Reads the on-host manifests over one ssh call. `[]` if unreachable/none.
"""
function list_remote_workers(host)
    code = replace(_WORKERS_PROBE, "REMOTE_WORKER_DIR" => _REMOTE_WORKER)
    ok, out = _ssh_julia!(host, code, "list workers on $host")
    ok || return Any[]
    i = findfirst('\x02', out); j = findlast('\x03', out)
    (i === nothing || j === nothing || j <= i) && return Any[]
    payload = out[nextind(out, i):prevind(out, j)]
    workers = Any[]
    for rec in split(payload, '\x1e'; keepempty = false)
        parts = split(rec, '\x1f')
        length(parts) >= 5 || continue
        port = tryparse(Int, strip(parts[1])); port === nothing && continue
        push!(workers, Dict{String,Any}(
            "port" => port,
            "alive" => strip(parts[2]) == "1",
            "lastActivity" => something(tryparse(Int, strip(parts[3])), 0),
            "logBytes" => something(tryparse(Int, strip(parts[4])), 0),
            "manifest" => String(strip(parts[5])),
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
    try; _ssh_test(host, `pkill -f $("worker-" * string(port) * ".jl")`); catch; end
    try; _ssh_ok(host, `rm -f $("$_REMOTE_WORKER/worker-$port.jl") $("$_REMOTE_WORKER/worker-$port.log") $("$_REMOTE_WORKER/worker-$port.json")`); catch; end
    return true
end
