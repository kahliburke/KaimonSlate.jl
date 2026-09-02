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
    m = joinpath(SlateHome.cache_home(), "stores", tag)
    for d in META_DIRS; mkpath(joinpath(m, d)); end
    return RemoteStore(String(host), String(root), m)
end

# ── One connection, reused ───────────────────────────────────────────────────────────────────
# `SshTransport` holds one authenticated session per host and opens a channel per command. SSH
# multiplexes channels itself, so a burst of polls and slices shares one authenticated connection
# with no socket file, and a cluster that costs a second factor costs it once.

# What a server prompt costs: a dialog in the notebook. Returning `nothing` cancels the connection.
_ask(host, prompt, echo) = SshAuth.ask(host, prompt, echo)

"True if there is an authenticated session for `host`."
connected(host::AbstractString) = isempty(host) || SshTransport.connected(String(host))

const _CONNECT_BACKOFF = 20.0
const _CONNECT_FAILED = Dict{String,Float64}()
const _CONNECT_LOCK = ReentrantLock()

"""
    connect!(host) -> Bool

Ensure a session exists, authenticating through the notebook if the server asks. A host is left
alone for a while after a failure: the pollers here would otherwise retry continuously, and on a
gated host every retry is a failed authentication.
"""
function connect!(host::AbstractString)
    isempty(host) && return true
    SshTransport.connected(String(host)) && return true
    lock(_CONNECT_LOCK) do
        time() - get(_CONNECT_FAILED, String(host), 0.0) < _CONNECT_BACKOFF
    end && return false
    ok = try
        SshTransport.session(String(host); ask = _ask)
        SshTransport.connected(String(host))
    catch
        false
    end
    lock(_CONNECT_LOCK) do
        ok ? delete!(_CONNECT_FAILED, String(host)) : (_CONNECT_FAILED[String(host)] = time())
    end
    return ok
end

"""
    run_there(host, script) -> (ok, output)

Run `script` on the host. An empty host runs it here — that is what makes this testable, and what
makes a `SlurmTarget` with no host behave as documented.
"""
function run_there(host::AbstractString, script::AbstractString)
    if isempty(host)
        buf = IOBuffer()
        ok = try; run(pipeline(`sh -c $script`; stdout = buf, stderr = buf)); true; catch; false; end
        return (ok, String(take!(buf)))
    end
    connect!(host) || return (false, "no connection to $host")
    return SshTransport.exec(String(host), String(script); ask = _ask)
end

"""
    shq(s) -> String

One shell word, whatever `s` contains. Everything sent to a host is a SCRIPT — the remote shell
splits it — so a path with a space in it is two words unless it is quoted, and cluster paths are not
always tidy. Single quotes with the standard `'\\''` escape: inside them the shell expands nothing,
so a store root is a store root and never a glob or a variable.
"""
shq(s) = "'" * replace(String(s), "'" => "'\\''") * "'"

"""
    run_io(host, script, input) -> (ok, stdout::Vector{UInt8})

`run_there` with bytes on stdin and bytes back — how files and archives cross without a second
authenticated transport.
"""
function run_io(host::AbstractString, script::AbstractString, input::Union{Vector{UInt8},Nothing})
    if isempty(host)
        out = IOBuffer()
        ok = try
            open(pipeline(`sh -c $script`; stderr = devnull), "r+") do io
                input === nothing || write(io, input)
                close(io.in); write(out, read(io))
            end
            true
        catch; false; end
        return (ok, take!(out))
    end
    connect!(host) || return (false, UInt8[])
    ok, data, _ = SshTransport.exec_io(String(host), String(script), input; ask = _ask)
    return (ok, data)
end

"Write `data` to `path` on the host, creating its directory."
function put_file(host::AbstractString, data::Vector{UInt8}, path::AbstractString)
    script = "mkdir -p " * shq(dirname(String(path))) * " && cat > " * shq(String(path))
    return first(run_io(host, script, data))
end

"Copy a local directory's contents to `dest` on the host."
function put_dir(host::AbstractString, localdir::AbstractString, dest::AbstractString;
                 delete::Bool = false, excludes::Vector{String} = String[])
    isdir(localdir) || return false
    args = String["cf", "-", "-C", String(localdir)]
    for e in excludes; insert!(args, 1, "--exclude=" * e); end
    out = IOBuffer()
    try; run(pipeline(`tar $args .`; stdout = out, stderr = devnull)); catch; return false; end
    script = (delete ? "rm -rf " * shq(String(dest)) * "; " : "") *
             "mkdir -p " * shq(String(dest)) * " && cd " * shq(String(dest)) * " && tar xf -"
    return first(run_io(host, script, take!(out)))
end

"End the session for `host`. The next call authenticates again — this is what logging out means."
function disconnect!(host::AbstractString)
    isempty(host) && return false
    SshAuth.cancel_host!(String(host))
    lock(_CONNECT_LOCK) do; delete!(_CONNECT_FAILED, String(host)); end
    return SshTransport.disconnect!(String(host))
end

# ── Syncing the metadata ─────────────────────────────────────────────────────────────────────
# `tar` over the session rather than rsync: rsync execs its own `ssh`, which on a gated host means
# authenticating a second time. Metadata is kilobytes of text, so moving all of it costs less than
# the round trips rsync would spend deciding what changed.

"""
    sync_flags(dir, direction) -> Bool

Whether a sync of `dir` in `direction` may DELETE what the far side no longer has. Decided by who
writes the directory, and it is the rule that goes wrong silently.

  `manifests/`, `status/`  written by the JOBS, so the store is authoritative. Delete on the way IN;
                           never on the way OUT, which would race a unit finishing between a pull
                           and a push and erase a result nobody has seen. Removing one deliberately
                           is `forget!`.

  `jobs/`                  written by the HUB — the submission index, the armed and cancelled
                           markers, the attempt counts. Delete on the way OUT, which is how
                           disarming and clearing attempts take effect; never on the way IN, or a
                           store copy that is merely older erases what the hub just wrote. The pull
                           exists only so a FRESH hub can recover a submission it did not make.

  `blobs/`                 content-addressed, so a blob the store already has is byte-identical.
"""
function sync_flags(dir::AbstractString, direction::Symbol)
    d = String(dir)
    direction === :in && return d != "jobs"
    direction === :out && return d == "jobs"
    error("sync_flags: direction is :in or :out, got :$direction")
end

_dirlist(dirs) = join((shq(String(d)) for d in dirs), " ")

"Bring the local mirror up to date with the store's metadata. One round trip."
function pull_meta!(s::RemoteStore; dirs = META_DIRS)
    isempty(s.host) && return true          # same machine: the mirror IS the store
    connect!(s.host) || return false
    names = _dirlist(dirs)
    script = "cd " * shq(s.root) * " 2>/dev/null || exit 0; mkdir -p " * names * "; tar cf - " * names
    ok, data, _ = SshTransport.exec_io(String(s.host), script, nothing; ask = _ask)
    ok || return false
    for d in dirs
        sync_flags(d, :in) && rm(joinpath(s.mirror, String(d)); force = true, recursive = true)
        mkpath(joinpath(s.mirror, String(d)))
    end
    return _untar(data, s.mirror)
end

"""
    push_meta!(s; dirs) -> Bool

Send what this hub has written — descriptors, the blobs they reference, and the markers — to the
store. What may be DELETED there is `sync_flags`' decision, not this function's.
"""
function push_meta!(s::RemoteStore; dirs = (META_DIRS..., "blobs"))
    isempty(s.host) && return true
    connect!(s.host) || return false
    present = String[String(d) for d in dirs if isdir(joinpath(s.mirror, String(d)))]
    isempty(present) && return true
    data = _tar(s.mirror, present)
    wipe = String[shq(joinpath(s.root, d)) for d in present if sync_flags(d, :out)]
    script = "mkdir -p " * shq(s.root) *
             (isempty(wipe) ? "" : "; rm -rf " * join(wipe, " ")) *
             "; cd " * shq(s.root) * " && tar xf -"
    ok, _, _ = SshTransport.exec_io(String(s.host), script, data; ask = _ask)
    return ok
end

# The system `tar`: on every cluster and every developer machine, and the archive here is a handful
# of kilobytes of text.
function _tar(root::AbstractString, dirs::Vector{String})
    out = IOBuffer()
    run(pipeline(`tar cf - -C $root $dirs`; stdout = out, stderr = devnull))
    return take!(out)
end

function _untar(data::Vector{UInt8}, dest::AbstractString)
    isempty(data) && return true
    mkpath(dest)
    return try
        open(pipeline(`tar xf - -C $dest`; stderr = devnull), "w") do io; write(io, data); end
        true
    catch
        false
    end
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
