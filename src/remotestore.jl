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
#             shadow in one round trip, so the hub's planning code goes on reading a local path and
#             a poll costs one round trip instead of one per unit.
#   data      the results. Terabytes, read RARELY and in slices. Never mirrored; read by byte
#             range against the real store (see `SshSource`).
#
# Descriptors travel the other way — they are small, and the job cannot start without them.
#
# Everything rides ONE multiplexed ssh connection. Without that, each of these is a fresh TCP
# handshake and key exchange, which on a normal link is 200-500 ms before a single useful byte
# moves — enough to make a poll feel broken and a slice feel worse.

import Tar          # archiving is ours, not a shell's — see "Packing bytes for the wire" below

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

# A server prompt costs a dialog in the notebook, so only a DELIBERATE action may raise one. Polls,
# reconciles and background placement run with `_noask`: they use a session that already exists and
# fail quietly otherwise. Without that split the first dialog you see comes from whichever poller
# got there first, with nothing on screen to answer it.
_ask(host, prompt, echo) = SshAuth.ask(host, prompt, echo)
_noask(_host, _prompt, _echo) = nothing

# ── Who holds the session ────────────────────────────────────────────────────────────────────
# The HUB does. A worker asks it rather than opening its own, so a cluster costs ONE login per
# machine — shared by every notebook on it — instead of one per process. The two halves of cluster
# work run in different processes (a sweep in a worker, a region placed by the hub) and both must
# reach the same session: answering a second factor twice for one cluster is the wrong answer twice
# over.
#
# `nothing` means this process owns its sessions: that is the hub, and every test.
const _DELEGATE = Ref{Any}(nothing)

"Send cluster operations to the process that owns the sessions — `f(op::Symbol, args::NamedTuple)`."
set_delegate!(f) = (_DELEGATE[] = f; nothing)
has_delegate() = _DELEGATE[] !== nothing

"The channel a worker sends cluster operations on, and the tool the hub answers them with."
const OP_CHANNEL = "__slate_sshop"

# A delegated call is a round trip to another process, so the asking task parks here until the
# answer comes back. Generic in the value: a command returns text, a transfer returns bytes.
const _OPS = Dict{String,Channel{Any}}()
const _OPS_LOCK = ReentrantLock()

"""
    await_op(id; timeout) -> value

Park until `deliver!(id, value)`. `nothing` on timeout — the owner never answered, which for a
caller is the same as the operation failing.
"""
function await_op(id::AbstractString; timeout::Real = 180.0)
    ch = Channel{Any}(1)
    lock(_OPS_LOCK) do; _OPS[String(id)] = ch; end
    t = Timer(_ -> (isopen(ch) && put!(ch, nothing)), timeout)
    try
        return take!(ch)
    catch
        return nothing
    finally
        close(t)
        lock(_OPS_LOCK) do; delete!(_OPS, String(id)); end
    end
end

"Hand a delegated operation its result. False if nothing is waiting for it any more."
function deliver!(id::AbstractString, value)
    ch = lock(_OPS_LOCK) do; get(_OPS, String(id), nothing); end
    ch === nothing && return false
    try; put!(ch, value); catch; return false; end
    return true
end

# Ask the owner, or do it here when this process IS the owner.
function _via(here, op::Symbol, args::NamedTuple)
    f = _DELEGATE[]
    f === nothing && return here()
    return f(op, args)
end

"True if there is an authenticated session for `host`."
connected(host::AbstractString) = isempty(host) ||
    _via(() -> SshTransport.connected(String(host)), :connected, (; host = String(host))) === true

const _CONNECT_BACKOFF = 20.0
const _CONNECT_FAILED = Dict{String,Float64}()
const _CONNECT_LOCK = ReentrantLock()

"""
    connect!(host; interactive = false) -> Bool

Ensure a session exists. Only an `interactive` call may raise a dialog — logging in is something a
person chooses to do, so opening a notebook, reconciling a sweep or polling a roster must not stop to
ask. A host is left alone for a while after a failure: the pollers here would otherwise retry
continuously, and on a gated host every retry is a failed authentication.
"""
function connect!(host::AbstractString; interactive::Bool = false)
    isempty(host) && return true
    has_delegate() && return _via(() -> false, :connect,
                                  (; host = String(host), interactive = interactive)) === true
    SshTransport.connected(String(host)) && return true
    # A login already in flight belongs to whoever started it, and it lasts as long as a person takes
    # to find their phone. Requests queue behind it, which is right for a cell someone ran and wrong
    # for a poller — so a poller reports "not connected" and comes back once it has landed.
    !interactive && SshTransport.opening(String(host)) && return false
    # The backoff exists to stop pollers hammering a host; someone who just pressed a button is not
    # a poller, and making them wait it out is the wrong answer.
    interactive || lock(_CONNECT_LOCK) do
        time() - get(_CONNECT_FAILED, String(host), 0.0) < _CONNECT_BACKOFF
    end && return false
    interactive && SshTransport.disconnect!(String(host))   # clear a half-open session first
    # `session` only STARTS the connection — the handshake and any prompt happen on its owner task.
    # Asking whether it is connected right after would always say no, so send a trivial command:
    # it queues behind the opening and comes back when there is a session, or when there cannot be.
    ok, why = try
        r = SshTransport.exec(String(host), "true"; ask = interactive ? _ask : _noask)
        (first(r) && SshTransport.connected(String(host)), String(last(r)))
    catch e
        (false, first(sprint(showerror, e), 200))
    end
    lock(_CONNECT_LOCK) do
        ok ? delete!(_CONNECT_FAILED, String(host)) : (_CONNECT_FAILED[String(host)] = time())
    end
    # Only for a login someone asked for: they are the one waiting on an answer, and a poller's
    # silent failure is not news.
    interactive && SshAuth.report!(String(host), ok, ok ? "" : why)
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
    has_delegate() && return _via(() -> (false, _offline(host)), :exec,
                                  (; host = String(host), script = String(script)))
    connect!(host) || return (false, _offline(host))
    return SshTransport.exec(String(host), String(script); ask = _ask)
end

# What to say when work needs a host nobody has signed in to. Naming the control matters: the bare
# fact leaves the reader with a red cell and no idea that signing in is a thing they do.
_offline(host) = "$host: not signed in — use the padlock at the top of the page"

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
    has_delegate() && return _via(() -> (false, UInt8[]), :io,
                                  (; host = String(host), script = String(script), input = input))
    connect!(host) || return (false, UInt8[])
    ok, data, _ = SshTransport.exec_io(String(host), String(script), input; ask = _ask)
    return (ok, data)
end

"Write `data` to `path` on the host, creating its directory."
function put_file(host::AbstractString, data::Vector{UInt8}, path::AbstractString)
    script = "mkdir -p " * shq(dirname(String(path))) * " && cat > " * shq(String(path))
    return first(run_io(host, script, data))
end

# ── Packing bytes for the wire ───────────────────────────────────────────────────────────────
# Archiving is ours to do, not a shell's. `tar` is not one program: bsdtar rejects an option placed
# before the bundled mode that GNU tar accepts, and Windows guarantees neither. `Tar` behaves
# identically everywhere, so the only `tar` left is the one on the FAR side — a cluster login node,
# which is POSIX by definition.
#
# UNCOMPRESSED, and it has to stay that way while this file runs in a worker: a worker loads in the
# NOTEBOOK's project, where the only packages guaranteed present are stdlibs. `Tar` is one;
# `CodecZlib` is not. Compressing wants either a stdlib codec or the far side told which format to
# expect.

# `tar --exclude` semantics for the patterns actually used — a bare name (`.git`, `Manifest.toml`)
# or a suffix glob (`*.cov`) — matched against every component of the path.
function _excluded(rel::AbstractString, pats)
    isempty(pats) && return false
    for c in split(String(rel), '/'; keepempty = false), p in pats
        ps = String(p)
        ps == c && return true
        startswith(ps, "*") && endswith(c, SubString(ps, 2)) && return true
    end
    return false
end

"A tar of `dir`, keeping the relative paths `keep` accepts."
function _archive(dir::AbstractString, keep = _ -> true)
    root = abspath(String(dir))
    io = IOBuffer()
    # `Tar.create` hands its predicate an ABSOLUTE path. Callers reason in paths relative to `dir` —
    # which is also what lands in the archive — so convert before asking, and use `/` regardless of
    # what the local platform separates with.
    Tar.create(p -> keep(replace(relpath(String(p), root), '\\' => '/')), root, io)
    return take!(io)
end

"Unpack a tar into `dest`, MERGING with what is there — a mirror is updated, not replaced."
function _unarchive(data::Vector{UInt8}, dest::AbstractString)
    isempty(data) && return true
    tmp = ""
    try
        tmp = Tar.extract(IOBuffer(data))
        mkpath(String(dest))
        for e in readdir(tmp)
            cp(joinpath(tmp, e), joinpath(String(dest), e); force = true, follow_symlinks = false)
        end
        return true
    catch e
        @warn "slate: could not unpack a transfer" dest exception = e
        return false
    finally
        isempty(tmp) || rm(tmp; recursive = true, force = true)
    end
end

"Copy a local directory's contents to `dest` on the host."
function put_dir(host::AbstractString, localdir::AbstractString, dest::AbstractString;
                 delete::Bool = false, excludes::Vector{String} = String[])
    isdir(localdir) || return false
    data = try
        _archive(localdir, p -> !_excluded(p, excludes))
    catch e
        # A bare `false` here reads as the far side refusing the transfer, so name this side.
        @warn "slate: could not archive $localdir for transfer" exception = e
        return false
    end
    if isempty(host)                    # same machine: no shell, so this works on Windows too
        delete && rm(String(dest); force = true, recursive = true)
        return _unarchive(data, dest)
    end
    script = (delete ? "rm -rf " * shq(String(dest)) * "; " : "") *
             "mkdir -p " * shq(String(dest)) * " && cd " * shq(String(dest)) * " && tar xf -"
    return first(run_io(host, script, data))
end

"Copy named local files into `dest` on the host, flattened. All must share a directory."
function put_files(host::AbstractString, files, dest::AbstractString)
    files = String[String(f) for f in files]
    isempty(files) && return true
    dir = dirname(first(files))
    names = Set(String[basename(f) for f in files])
    data = try
        _archive(dir, p -> String(p) in names)
    catch e
        @warn "slate: could not archive $(length(files)) files for transfer" dir exception = e
        return false
    end
    isempty(host) && return _unarchive(data, dest)
    script = "mkdir -p " * shq(String(dest)) * " && cd " * shq(String(dest)) * " && tar xf -"
    return first(run_io(host, script, data))
end

"""
    forward!(host, localport, target, targetport) -> (ok, message)

Carry `localport` here to `target:targetport` over the session already open to `host`. No new
connection, so no second prompt.

"Here" is wherever the session is, which is the hub — a region's tunnel is the hub dialling a worker
it is about to spawn, so that is the machine the port belongs on.
"""
forward!(host::AbstractString, localport::Integer, target::AbstractString, targetport::Integer) =
    _via(:forward, (; host = String(host), localport = Int(localport),
                      target = String(target), targetport = Int(targetport))) do
        connect!(host) ?
            SshTransport.forward!(String(host), localport, String(target), targetport; ask = _noask) :
            (false, _offline(host))
    end

"Stop carrying `localport`."
unforward!(host::AbstractString, localport::Integer) =
    _via(() -> SshTransport.unforward!(String(host), localport), :unforward,
         (; host = String(host), localport = Int(localport)))

"End the session for `host`. The next call authenticates again — this is what logging out means."
function disconnect!(host::AbstractString)
    isempty(host) && return false
    has_delegate() && return _via(() -> false, :disconnect, (; host = String(host))) === true
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
    connected(s.host) || return false
    names = _dirlist(dirs)
    script = "cd " * shq(s.root) * " 2>/dev/null || exit 0; mkdir -p " * names * "; tar cf - " * names
    ok, data = run_io(String(s.host), script, nothing)
    ok || return false
    for d in dirs
        sync_flags(d, :in) && rm(joinpath(s.mirror, String(d)); force = true, recursive = true)
        mkpath(joinpath(s.mirror, String(d)))
    end
    return _unarchive(data, s.mirror)
end

"""
    push_meta!(s; dirs) -> Bool

Send what this hub has written — descriptors, the blobs they reference, and the markers — to the
store. What may be DELETED there is `sync_flags`' decision, not this function's.
"""
function push_meta!(s::RemoteStore; dirs = (META_DIRS..., "blobs"))
    isempty(s.host) && return true
    connected(s.host) || return false
    present = String[String(d) for d in dirs if isdir(joinpath(s.mirror, String(d)))]
    isempty(present) && return true
    keep = Set(present)
    data = _archive(s.mirror, p -> first(split(String(p), '/'; keepempty = false)) in keep)
    wipe = String[shq(joinpath(s.root, d)) for d in present if sync_flags(d, :out)]
    script = "mkdir -p " * shq(s.root) *
             (isempty(wipe) ? "" : "; rm -rf " * join(wipe, " ")) *
             "; cd " * shq(s.root) * " && tar xf -"
    return first(run_io(String(s.host), script, data))
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
