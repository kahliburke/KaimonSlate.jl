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

_ctl_path(host) = joinpath(tempdir(), "slate-cm-" * string(hash(String(host)); base = 16))

ssh_opts(host) = String[
    "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
    "-o", "ControlMaster=auto", "-o", "ControlPath=" * _ctl_path(host),
    "-o", "ControlPersist=300",
]

"The `ssh …` prefix as one shell word, for tools that take a remote-shell string (rsync's `-e`)."
ssh_command(host) = "ssh " * join(ssh_opts(host), " ")

"Run `script` on the host, returning `(ok, output)`. An empty host runs it here — that is what makes
this testable, and what makes a `SlurmTarget` with no host behave as documented."
function run_there(host::AbstractString, script::AbstractString)
    cmd = isempty(host) ? `sh -c $script` : `ssh $(ssh_opts(host)) $host $script`
    buf = IOBuffer()
    ok = try; run(pipeline(cmd; stdout = buf, stderr = buf)); true; catch; false; end
    return (ok, String(take!(buf)))
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
        o, _ = run_there(s.host, "rm -f " * join(batch, " "))
        ok &= o
    end
    return ok
end

"Make sure the store's directories exist on the far side, before anything is pushed into them."
function ensure_root!(s::RemoteStore)
    isempty(s.host) && return true
    dirs = join((joinpath(s.root, d) for d in (META_DIRS..., "blobs")), " ")
    ok, _ = run_there(s.host, "mkdir -p " * dirs)
    return ok
end
