# ── A store the hub cannot see ───────────────────────────────────────────────────────────────
#
# The deployment this exists for: Slate on a laptop, work on a SLURM cluster, and no filesystem in
# common. That is not a variant of running on the cluster — it is the only arrangement in which a
# sweep can outlive the session that started it. A login node kills long-lived processes and a
# scheduled interactive session dies at its walltime, so a notebook that watches a three-day sweep
# has to be somewhere else.
#
# The store then has two populations with completely different economics:
#
#   metadata  manifests, chunk status, job markers. Kilobytes each, read CONSTANTLY — every
#             reconcile and every card poll wants one per unit. Mirrored WHOLESALE into a local
#             shadow with one rsync, so the hub's planning code goes on reading a local path and
#             a poll costs one round trip instead of one per unit.
#   data      the results. Terabytes, read RARELY and in slices. Never mirrored; read by byte
#             range against the real store (see `SshSource`).
#
# Descriptors travel the other way — they are small, and the job cannot start without them.
#
# Everything rides ONE multiplexed ssh connection. Without that, each of these is a fresh TCP
# handshake and key exchange, which on a normal link is 200-500 ms before a single useful byte
# moves — enough to make a poll feel broken and a slice feel worse.

# The directories that hold METADATA, relative to a store root. `blobs/` is deliberately absent:
# pulling it would mean pulling the results, which is the one thing this design exists to avoid.
const META_DIRS = ("manifests", "status", "jobs")

"""
    RemoteStore(host, root)

A store on `host` at `root` (the path AS THE HOST SEES IT), shadowed locally. `mirror` is a local
directory the rest of the fabric can treat as an ordinary store root — the metadata in it is a copy,
refreshed by `pull_meta!`, and the blobs in it are only the ones this hub WROTE.
"""
struct RemoteStore
    host::String
    root::String
    mirror::String
end

function RemoteStore(host::AbstractString, root::AbstractString)
    # Keyed by host AND path: one laptop may drive several clusters, and two of them may well use
    # the same conventional path (`/scratch/$USER/slate`) for entirely different stores.
    tag = string(hash((String(host), String(root))); base = 16)
    m = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")),
                 "kaimonslate", "stores", tag)
    for d in META_DIRS; mkpath(joinpath(m, d)); end
    return RemoteStore(String(host), String(root), m)
end

# ── One connection, reused ───────────────────────────────────────────────────────────────────
# `ControlMaster=auto` makes the first call open a master and every later one ride it; the socket
# outlives the call by `ControlPersist`, so a burst of polls and slices shares a single
# authenticated channel. The path is per host, and short — a control socket lives in the filesystem
# and long ones hit the sockaddr limit.

# The socket is SHARED with the regions and with anything else that reaches a host — see
# `SshAuth.control_path`. A cluster that costs a 2FA prompt must cost exactly one.
_ctl_path(host) = SshAuth.control_path(String(host))

function ssh_opts(host)
    # `ConnectTimeout` bounds only the TCP handshake, which is not where this hangs. The way a
    # cluster call actually stops coming back is a session that connected and then went silent —
    # the host rebooted, a container stopped, the laptop changed networks — and with multiplexing
    # the socket keeps answering, so the call has something to ride and waits on it forever. The
    # keepalives are what put a ceiling on that: ~60s, then the call fails and can be retried.
    o = String["-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
               "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"]
    p = _ctl_path(host)
    # No usable socket path ⇒ no multiplexing. Every call then authenticates on its own, which is
    # slower and, on a cluster that wants a second factor, prompts every time — but it is honest,
    # where passing ssh a path it cannot bind fails outright.
    isempty(p) && return o
    append!(o, ["-o", "ControlMaster=auto", "-o", "ControlPath=" * p,
                "-o", "ControlPersist=" * _control_persist()])
    return o
end

"The `ssh …` prefix as one shell word, for tools that take a remote-shell string (rsync's `-e`)."
ssh_command(host) = "ssh " * join(ssh_opts(host), " ")

# ── Getting the first connection open ────────────────────────────────────────────────────────
# Everything above assumes `BatchMode=yes` can connect, which holds only where a key works. On a
# cluster that wants a password and a second factor it fails before it starts — so ONE connection
# has to be interactive, and only when there isn't already a master to ride.
#
# `ssh -O check` is the question "is there one?", asked of ssh rather than of the filesystem: a
# control socket can outlive the connection it belonged to, and a stale one is indistinguishable
# from a live one by looking.

"True if a multiplexed master is already open for `host` — then nothing here needs to prompt."
function master_open(host::AbstractString)
    isempty(host) && return true
    return success(pipeline(`ssh -O check $(ssh_opts(host)) $host`;
                            stdout = devnull, stderr = devnull))
end

"""
    clear_stale_master!(host) -> Bool

Remove a control socket whose connection is gone, returning whether one was removed.

A socket FILE outlives the connection it belonged to — a killed ssh, a reboot, a hub that went away
mid-session — and ssh will not create a master over one that exists: it says
`ControlSocket … already exists, disabling multiplexing` and then every later call fails with
`Connection refused`. Left alone that is unrecoverable without a human deleting a file, on the one
host where reconnecting costs a 2FA prompt.

The concrete path comes from `ssh -G`, because `%C` is ssh's to expand, not ours.
"""
function clear_stale_master!(host::AbstractString)
    isempty(host) && return false
    master_open(host) && return false                  # live — leave it alone
    p = try
        m = match(r"^controlpath\s+(.+)$"m,
                  read(pipeline(`ssh -G $(ssh_opts(host)) $host`; stderr = devnull), String))
        m === nothing ? "" : strip(m.captures[1])
    catch; ""; end
    (isempty(p) || p == "none" || !ispath(p)) && return false
    try; rm(p; force = true); catch; return false; end
    return true
end

"""
    open_master!(host; timeout = 300) -> (ok, message)

Open the one interactive connection, answering prompts through `SshAuth` — which routes them to
whoever is watching (the notebook, or a terminal helper). `BatchMode=no` is the point: it lets ssh
attempt the keyboard-interactive methods that a 2FA cluster offers and `BatchMode=yes` refuses.

`NumberOfPasswordPrompts=1` because a wrong answer must FAIL rather than loop: a second attempt
re-prompts, and on a one-time code it also burns the code that was about to work.
"""
function open_master!(host::AbstractString; timeout::Real = 300)
    isempty(host) && return (true, "local")
    master_open(host) && return (true, "already open")
    helper = SshAuth.askpass_script()
    env = copy(ENV)
    env["SSH_ASKPASS"] = helper
    env["SSH_ASKPASS_REQUIRE"] = "force"     # ask the helper even when a TTY is present
    env["DISPLAY"] = get(env, "DISPLAY", ":0")   # ancient precondition for askpass; content unused
    env["SLATE_SSHAUTH_DIR"] = SshAuth.rendezvous_dir()
    env["SLATE_SSHAUTH_HOST"] = String(host)
    env["SLATE_SSHAUTH_TIMEOUT"] = string(Int(round(timeout)))
    ctl = _ctl_path(host)
    isempty(ctl) && return (false, "no usable ssh ControlPath — cannot hold a connection open")
    # A socket left behind by a dead connection would make ssh refuse to open a new master, and the
    # prompt below is the expensive thing here — do not spend it on a connection that cannot form.
    clear_stale_master!(host)
    # Keepalives are not an optimisation here. A master whose far end goes away — the cluster
    # rebooted, a container stopped, a laptop changed networks — leaves a socket that still ANSWERS
    # `ssh -O check`, so every later call looks like it has a connection to ride and then blocks
    # forever on a TCP session nobody is on the other end of. With these, ssh notices and the master
    # exits, and the next call opens a fresh one (a 2FA prompt, but a prompt beats a hang).
    cmd = `ssh -M -N -f -o BatchMode=no -o NumberOfPasswordPrompts=1
               -o ControlMaster=auto -o ControlPath=$ctl
               -o ServerAliveInterval=15 -o ServerAliveCountMax=4
               -o ControlPersist=$(_control_persist()) -o ConnectTimeout=30 $host`
    buf = IOBuffer()
    ok = try
        run(pipeline(setenv(cmd, env); stdout = buf, stderr = buf))
        true
    catch
        false
    end
    out = strip(String(take!(buf)))
    ok && master_open(host) && return (true, "authenticated")
    return (false, isempty(out) ? "ssh could not open a master to $host" : out)
end

# Long enough that a notebook left alone over lunch does not cost another 2FA prompt, and a session
# is bounded rather than forever.
_control_persist() = get(ENV, "KAIMONSLATE_SSH_PERSIST", "8h")

"""
    shq(s) -> String

One shell word, whatever `s` contains. Everything sent to a host is a SCRIPT — ssh concatenates its
arguments and hands the result to the remote shell — so a path with a space in it is two words
unless it is quoted, and cluster paths are not always tidy. Single quotes with the standard
`'\\''` escape: inside them the shell expands nothing at all, so a store root is a store root and
never a glob or a variable.
"""
shq(s) = "'" * replace(String(s), "'" => "'\\''") * "'"

# How long to leave a host alone after a failed attempt to reach it. Without this, every poll retried
# — and a sweep card polls about once a second. Each retry is a fresh TCP connection (multiplexing is
# exactly what is not working) plus a failed authentication, so an unreachable host does not fail
# quietly: it fills the ephemeral port range with TIME_WAIT until nothing on the machine can open a
# socket. Seen: ~15k sockets, both hubs unable to accept, ssh and docker's port mapping down with it.
const _CONNECT_BACKOFF = 20.0
const _CONNECT_FAILED = Dict{String,Float64}()
const _CONNECT_LOCK = ReentrantLock()

"""
    connect!(host) -> Bool

Make sure there is a connection to ride, authenticating if that takes a human. Called from the
handful of functions that actually touch the network — NOT from the ones that merely work out where
things live, which are pure and must stay answerable for a host nobody can reach.

Costs one `ssh -O check` when a master is already open, which is the common case by design. After a
failure the host is left alone for a while: a poll loop must not be able to turn "cannot reach it"
into a machine-wide resource problem.
"""
function connect!(host::AbstractString)
    isempty(host) && return true
    master_open(host) && return true
    lock(_CONNECT_LOCK) do
        time() - get(_CONNECT_FAILED, String(host), 0.0) < _CONNECT_BACKOFF
    end && return false
    ok, _ = open_master!(host)
    lock(_CONNECT_LOCK) do
        ok ? delete!(_CONNECT_FAILED, String(host)) : (_CONNECT_FAILED[String(host)] = time())
    end
    return ok
end

"Run `script` on the host, returning `(ok, output)`. An empty host runs it here — that is what makes
this testable, and what makes a `SlurmTarget` with no host behave as documented."
function run_there(host::AbstractString, script::AbstractString)
    # No connection ⇒ do not attempt the command. Running it anyway is what turned an unreachable
    # host into a machine-wide problem: without a master every attempt opens its OWN TCP connection,
    # and a card that polls once a second exhausts the ephemeral port range in minutes.
    connect!(host) || return (false, "no connection to $host")
    cmd = isempty(host) ? `sh -c $script` : `ssh $(ssh_opts(host)) $host $script`
    buf = IOBuffer()
    ok = try; run(pipeline(cmd; stdout = buf, stderr = buf)); true; catch; false; end
    return (ok, String(take!(buf)))
end

"""
    drop_master!(host) -> Bool

Tear down the multiplexed master for `host`, so the next call opens a fresh one.

The way back from the state where a socket answers `ssh -O check` but the session behind it is gone:
ssh's keepalives normally end that on their own, but a master opened by an older build (or by hand)
has none, and every call that rides it waits on a connection nobody is on the other end of. Also
what "log out" means — the master IS the authenticated session.
"""
function drop_master!(host::AbstractString)
    isempty(host) && return false
    return try
        success(pipeline(`ssh -O exit $(ssh_opts(host)) $host`; stdout = devnull, stderr = devnull))
    catch
        false
    end
end

# ── Syncing the metadata ─────────────────────────────────────────────────────────────────────
# rsync rather than tar or a bespoke protocol: it is on every cluster, it moves only what changed
# (so a poll after the first costs the new manifests and nothing else), and it already knows how to
# be interrupted safely.

"""
    sync_flags(dir, direction) -> Cmd

The extra rsync flags for one directory, decided by WHO WRITES IT. Pure, so the ownership rule is
testable without a host — and it is the rule that goes wrong silently.

  `manifests/`, `status/`  written by the JOBS, so the store is authoritative. Delete on the way IN
                           (the mirror must forget what the store no longer has), never on the way
                           OUT: that would race a unit finishing between our pull and our push and
                           erase a result nobody has seen. Removing one deliberately is `forget!`.

  `jobs/`                  written by the HUB — the submission index, the armed and cancelled
                           markers, the attempt counts. Delete on the way OUT, which is how
                           disarming and clearing attempts actually take effect; never on the way
                           IN, or a store copy that is merely OLDER erases state the hub has just
                           written and not yet pushed. That is what used to happen to the attempt
                           counts: bumped during a reconcile, after that run's push, so the next
                           pull removed each one before it could reach the budget — and a sweep
                           whose units the scheduler kills resubmitted forever, which is the one
                           thing the budget exists to prevent. The pull exists only so a FRESH hub
                           can recover a live submission it did not make itself.

  `blobs/`                 content-addressed, so a blob the store already has is byte-identical and
                           re-sending it is waste.
"""
function sync_flags(dir::AbstractString, direction::Symbol)
    d = String(dir)
    direction === :in && return d == "jobs" ? `` : `--delete`
    direction === :out && return d == "blobs" ? `--ignore-existing` : (d == "jobs" ? `--delete` : ``)
    error("sync_flags: direction is :in or :out, got :$direction")
end

"Bring the local mirror up to date with the store's metadata. One round trip."
function pull_meta!(s::RemoteStore; dirs = META_DIRS)
    isempty(s.host) && return true          # same machine: the mirror IS the store
    connect!(s.host) || return false        # never rsync without a master — see `run_there`
    for d in dirs
        mkpath(joinpath(s.mirror, d))
        extra = sync_flags(d, :in)
        spec = joinpath(s.root, d) * "/"
        c = `rsync -a $extra -e $(ssh_command(s.host)) $(s.host * ":" * spec) $(joinpath(s.mirror, d) * "/")`
        ok = try; run(pipeline(c; stdout = devnull, stderr = devnull)); true; catch; false; end
        ok || return false
    end
    return true
end

"""
    push_meta!(s; dirs) -> Bool

Send what this hub has written — descriptors, the blobs they reference, and the markers — to the
store. What may be DELETED there is `sync_flags`' decision, not this function's.
"""
function push_meta!(s::RemoteStore; dirs = (META_DIRS..., "blobs"))
    isempty(s.host) && return true
    connect!(s.host) || return false        # never rsync without a master — see `run_there`
    ok = true
    for d in dirs
        src = joinpath(s.mirror, d)
        isdir(src) || continue
        extra = sync_flags(d, :out)
        c = `rsync -a $extra -e $(ssh_command(s.host)) $(src * "/") $(s.host * ":" * joinpath(s.root, d) * "/")`
        ok &= try; run(pipeline(c; stdout = devnull, stderr = devnull)); true; catch; false; end
    end
    return ok
end

"""
    forget!(s, relpaths) -> Bool

Remove files from the store itself. The one deletion that crosses, because it is asked for: reset
and retry drop results on purpose, and dropping them only in the mirror means the next pull brings
them back. Batched so a sweep of thousands of units is one round trip, not thousands.
"""
function forget!(s::RemoteStore, relpaths)
    isempty(s.host) && return true
    ps = [joinpath(s.root, String(p)) for p in relpaths]
    isempty(ps) && return true
    ok = true
    for batch in Iterators.partition(ps, 400)     # keep the command under the shell's arg limit
        o, _ = run_there(s.host, "rm -f " * join(shq.(batch), " "))
        ok &= o
    end
    return ok
end

"Make sure the store's directories exist on the far side, before anything is pushed into them."
function ensure_root!(s::RemoteStore)
    isempty(s.host) && return true
    dirs = join((shq(joinpath(s.root, d)) for d in (META_DIRS..., "blobs")), " ")
    ok, _ = run_there(s.host, "mkdir -p " * dirs)
    return ok
end
