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

# ── "This answer belongs to the session, not to the source" ──────────────────────────────────
# A cell that ASKS a host something is not a function of its source: the answer changes the moment
# someone signs in or out, and the notebook never edits to say so. Cached, it comes back on the next
# load reporting a connection that isn't there — and a run-all then RESTORES that instead of asking,
# so the notebook contradicts the padlock above it.
#
# Declared at the CALL rather than left to a cell tag, because the author of a cell that says
# `Sweep.connected(host)` has no reason to know a memo layer exists. `_slate_effect` is a task-local
# push that no-ops outside a cell eval, so the pollers that call this constantly pay nothing, and the
# classification is persisted per-cell (`EffectStore`) so it holds from t=0 on the next load — which
# is the case that actually bit.
const _EFFECT_FN = Ref{Any}(missing)          # resolved once; `nothing` = no channel in this process

function _declare_volatile()
    f = _EFFECT_FN[]
    if f === missing
        f = isdefined(P, :_slate_effect) ?
            (try; Base.invokelatest(getfield, P, :_slate_effect); catch; nothing; end) : nothing
        _EFFECT_FN[] = f
    end
    f === nothing && return nothing            # Sweep loaded without the capture channel
    try; f(:volatile); catch; end
    return nothing
end

"True if there is an authenticated session for `host`."
connected(host::AbstractString) = (_declare_volatile(); isempty(host) ||
    _via(() -> SshTransport.connected(String(host)), :connected, (; host = String(host))) === true)

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
    _declare_volatile()          # running a command somewhere is never a function of the cell's source
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
    shq_path(s) -> String

`shq` for a PATH, which may begin `~/`. Quoting is what makes a path with a space one word, and it
is also what stops the shell expanding `~` — so a destination like `~/.cache/kaimonslate/remote`
was creating a directory literally named `~` beside the home directory, while the Julia running on
the far side resolved the same string against the real home and looked somewhere else. Only the
leading `~/` is handled: a bare `~user` form is not something these paths use, and the rest of the
path stays quoted so it is still exactly one word.
"""
shq_path(s) = (p = String(s); startswith(p, "~/") ? "\"\$HOME\"/" * shq(SubString(p, 3)) : shq(p))

"""
    run_io(host, script, input) -> (ok, stdout::Vector{UInt8})

`run_there` with bytes on stdin and bytes back — how files and archives cross without a second
authenticated transport.
"""
function run_io(host::AbstractString, script::AbstractString, input::Union{Vector{UInt8},IO,Nothing})
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
    script = "mkdir -p " * shq_path(dirname(String(path))) * " && cat > " * shq_path(String(path))
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

# ── What travels ─────────────────────────────────────────────────────────────────────────────
# A project directory is shipped WHOLESALE, which is fine until something large sits beside the
# code: a data directory, a results tree, a checkout of inputs. None of it is code and none of it
# belongs on the far side, but the exclude list above could not tell — it is a fixed handful of
# names, so a project whose root holds hundreds of gigabytes tries to send all of it.
#
# Two sources, both belonging to the PROJECT rather than to the host, because "too big to ship" is
# a fact about the project and is the same fact for every remote it goes to:
#
#   .gitignore     Honoured whenever the directory is a git work tree. `git ls-files` answers
#                  "tracked, plus untracked and not ignored" exactly, which is the intent, and it
#                  reads the whole ignore chain (nested files, excludesFile, info/exclude) rather
#                  than a reimplementation of it.
#   .slateignore   Beside Project.toml, gitignore syntax. For a directory that IS tracked but is
#                  not worth sending, and for projects that are not git repositories at all.
#
# `.slateignore` may also name a REGION, for the one thing that genuinely varies by destination: a
# host that already has the data by other means (a shared filesystem, a sync service). A section
# `[region:<name>]` applies only when shipping there, and `!pattern` un-ignores. Kept in the
# project's file rather than the region's definition because a region is global across projects,
# and `data/` names a different directory in each of them.
const _SLATEIGNORE = ".slateignore"

# Files git would keep: tracked + untracked-not-ignored. `nothing` when this is not a work tree or
# git is unavailable, which is the signal to fall back to shipping everything but the fixed names.
function _git_kept(dir::AbstractString)
    out = try
        d = abspath(String(dir))
        readchomp(`git -C $d ls-files -c -o --exclude-standard -z`)
    catch
        return nothing
    end
    keep = Set{String}()
    for f in split(out, '\0'; keepempty = false)
        push!(keep, replace(String(f), '\\' => '/'))
    end
    return keep
end

# One `.slateignore` rule: a gitignore-style pattern plus whether it un-ignores.
struct _IgnoreRule
    negated::Bool
    anchored::Bool      # a leading `/` — matches from the project root only
    dironly::Bool       # a trailing `/` — matches a directory, and so its whole subtree
    pat::String
end

# The GLOBAL section, then the one for `region` if it names one. Later rules win, so a region's
# lines override the defaults above them — which is what makes "everywhere except this host"
# and "only on this host" both expressible.
function _slateignore_rules(dir::AbstractString, region::AbstractString)
    f = joinpath(String(dir), _SLATEIGNORE)
    isfile(f) || return _IgnoreRule[]
    rules, active = _IgnoreRule[], true
    for raw in eachline(f)
        line = strip(raw)
        (isempty(line) || startswith(line, '#')) && continue
        if startswith(line, '[') && endswith(line, ']')
            sec = strip(SubString(line, 2, lastindex(line) - 1))
            active = !startswith(sec, "region:") ||
                     strip(SubString(sec, ncodeunits("region:") + 1)) == String(region)
            continue
        end
        active || continue
        neg = startswith(line, '!')
        neg && (line = strip(SubString(line, 2)))
        isempty(line) && continue
        anch = startswith(line, '/')
        anch && (line = SubString(line, 2))
        dironly = endswith(line, '/')
        dironly && (line = SubString(line, 1, lastindex(line) - 1))
        isempty(line) || push!(rules, _IgnoreRule(neg, anch, dironly, String(line)))
    end
    return rules
end

# A gitignore pattern against ONE path component or a whole relative path. `*` and `?` only —
# character classes are rare in these files and a wrong match here silently drops a file.
function _glob_match(pat::AbstractString, s::AbstractString)
    occursin('*', pat) || occursin('?', pat) || return pat == s
    re = "^" * replace(Base.escape_string(String(pat)),
                       "\\*" => "*", "\\?" => "?") * "\$"
    re = replace(re, "." => "\\.", "*" => "[^/]*", "?" => "[^/]")
    return occursin(Regex(re), String(s))
end

# Does `rel` (a path relative to the project root, `/`-separated) match? An UNANCHORED pattern with
# no slash matches any component, so `data/` catches `a/b/data/x` — gitignore's own rule, and the
# one people rely on. A match on any parent prefix carries the whole subtree.
function _rule_hits(r::_IgnoreRule, rel::AbstractString)
    parts = split(String(rel), '/'; keepempty = false)
    if occursin('/', r.pat)                       # a path pattern: match from the root
        pp = split(r.pat, '/'; keepempty = false)
        length(parts) >= length(pp) || return false
        return all(i -> _glob_match(pp[i], parts[i]), eachindex(pp))
    end
    r.anchored && return !isempty(parts) && _glob_match(r.pat, parts[1])
    # `dironly` means only a DIRECTORY matches, so the last component of a file path cannot.
    last_i = r.dironly ? length(parts) - 1 : length(parts)
    return any(i -> _glob_match(r.pat, parts[i]), 1:max(last_i, 0))
end

"""
    transfer_keep(dir; region, excludes) -> (rel -> Bool)

Which relative paths under `dir` may travel. `.gitignore` (via git) and `.slateignore` decide,
with the fixed `excludes` applied on top — those name things that must never travel regardless
(`.git`, a Manifest the far side is meant to resolve itself).
"""
function transfer_keep(dir::AbstractString; region::AbstractString = "",
                       excludes::Vector{String} = String[])
    kept = _git_kept(dir)
    rules = _slateignore_rules(dir, region)
    return function (rel::AbstractString)
        r = replace(String(rel), '\\' => '/')
        _excluded(r, excludes) && return false
        # A directory is offered before its contents; keep it so the walk can descend, and let the
        # files inside be judged on their own. Dropping it here would prune a subtree that
        # `.slateignore` may have un-ignored.
        isdirpath = isdir(joinpath(String(dir), r))
        if kept !== nothing && !isdirpath && !(r in kept)
            return false                                   # git ignores it, or it is not a file git sees
        end
        hit = false
        for ru in rules                                    # later rules win
            _rule_hits(ru, r) && (hit = !ru.negated)
        end
        return !hit
    end
end

# Skip anything that is not a regular file, directory or symlink. A store is written while it is
# shipped — an atomic write stages a temp file and renames it away — and `Tar` stats each entry
# after listing its parent, so an entry that vanished in between reports a type it refuses to encode
# and aborts the ENTIRE archive. Losing one in-flight temp is correct; losing the sync is not, and
# it fails far from here (a marker that never reached the store).
function _sendable(abs::AbstractString)
    st = try; lstat(abs); catch; return false; end
    return ispath(st) && (isfile(st) || isdir(st) || islink(st))
end

"A tar of `dir`, keeping the relative paths `keep` accepts."
function _archive(dir::AbstractString, keep = _ -> true)
    root = abspath(String(dir))
    io = IOBuffer()
    # `Tar.create` hands its predicate an ABSOLUTE path. Callers reason in paths relative to `dir` —
    # which is also what lands in the archive — so convert before asking, and use `/` regardless of
    # what the local platform separates with.
    Tar.create(p -> _sendable(String(p)) &&
                    keep(replace(relpath(String(p), root), '\\' => '/')), root, io)
    return take!(io)
end

"""
    _archive_file(dir, keep) -> path

The same archive, written to a temp FILE. For a directory whose size is not known in advance — a
user's project — because `_archive` holds the whole tar in memory and a second copy of a tree that
is already large is what turns a big project into an out-of-memory failure instead of a slow
transfer. The caller deletes it.
"""
function _archive_file(dir::AbstractString, keep = _ -> true)
    root = abspath(String(dir))
    path, io = mktemp()
    try
        Tar.create(p -> _sendable(String(p)) &&
                        keep(replace(relpath(String(p), root), '\\' => '/')), root, io)
        close(io)
        return path
    catch
        close(io); rm(path; force = true)
        rethrow()
    end
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
                 delete::Bool = false, excludes::Vector{String} = String[],
                 region::AbstractString = "", filter::Bool = false)
    isdir(localdir) || return false
    # `filter` is opt-in: this also ships Slate's OWN directories (the SDK source, a dev dep), which
    # are not the user's project and have no ignore files to consult.
    keep = filter ? transfer_keep(localdir; region, excludes) : (p -> !_excluded(p, excludes))
    # Spilled to a file rather than held as bytes: this is the one transfer whose size is the user's
    # to decide, and the archive of a project can be arbitrarily large.
    tarpath = try
        _archive_file(localdir, keep)
    catch e
        # A bare `false` here reads as the far side refusing the transfer, so name this side.
        @warn "slate: could not archive $localdir for transfer" exception = e
        return false
    end
    try
        if isempty(host)                # same machine: no shell, so this works on Windows too
            delete && rm(String(dest); force = true, recursive = true)
            return _unarchive(read(tarpath), dest)
        end
        script = (delete ? "rm -rf " * shq_path(String(dest)) * "; " : "") *
                 "mkdir -p " * shq_path(String(dest)) * " && cd " * shq_path(String(dest)) * " && tar xf -"
        # A DELEGATED call hands the input to another process, so it has to be bytes; that path is a
        # worker asking the hub, where the bytes were always going to cross a process boundary. The
        # direct path — the hub provisioning a host, which is where the large ones are — streams.
        return has_delegate() ? first(run_io(host, script, read(tarpath))) :
               open(tarpath, "r") do io; first(run_io(host, script, io)); end
    finally
        rm(tarpath; force = true)
    end
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
    script = "mkdir -p " * shq_path(String(dest)) * " && cd " * shq_path(String(dest)) * " && tar xf -"
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

# One sync at a time per mirror. A pull REPLACES the mirror's metadata dirs — remove, then extract —
# so two of them on the same store interleave: one walks a directory while the other is writing into
# it, and the `rm` fails with ENOTEMPTY on a directory that was empty when it started. That is not
# hypothetical bookkeeping: a sweep cell running while its own card polls is two syncs on one store,
# and a notebook with several sweep cells against one cluster is more.
#
# The lock is held across the round trip, which also collapses a burst of concurrent syncs into one
# useful fetch instead of several redundant ones.
const _SYNC_LOCKS = Dict{String,ReentrantLock}()
const _SYNC_LOCKS_LOCK = ReentrantLock()

_sync_lock(mirror::AbstractString) = lock(_SYNC_LOCKS_LOCK) do
    get!(ReentrantLock, _SYNC_LOCKS, String(mirror))
end

"Bring the local mirror up to date with the store's metadata. One round trip."
function pull_meta!(s::RemoteStore; dirs = META_DIRS)
    isempty(s.host) && return true          # same machine: the mirror IS the store
    connected(s.host) || return false
    names = _dirlist(dirs)
    script = "cd " * shq_path(s.root) * " 2>/dev/null || exit 0; mkdir -p " * names * "; tar cf - " * names
    lock(_sync_lock(s.mirror)) do
        ok, data = run_io(String(s.host), script, nothing)
        ok || return false
        for d in dirs
            sync_flags(d, :in) && rm(joinpath(s.mirror, String(d)); force = true, recursive = true)
            mkpath(joinpath(s.mirror, String(d)))
        end
        return _unarchive(data, s.mirror)
    end
end

"""
    push_meta!(s; dirs) -> Bool

Send what this hub has written — descriptors, the blobs they reference, and the markers — to the
store. What may be DELETED there is `sync_flags`' decision, not this function's.
"""
function push_meta!(s::RemoteStore; dirs = (META_DIRS..., "blobs"))
    isempty(s.host) && return true
    connected(s.host) || return false
    # Under the same lock as `pull_meta!`: this READS the mirror to build the archive, and a pull
    # rewriting those directories underneath it would ship a half-replaced tree.
    present, data = lock(_sync_lock(s.mirror)) do
        pres = String[String(d) for d in dirs if isdir(joinpath(s.mirror, String(d)))]
        isempty(pres) && return (pres, nothing)
        keep = Set(pres)
        (pres, _archive(s.mirror, p -> first(split(String(p), '/'; keepempty = false)) in keep))
    end
    isempty(present) && return true
    wipe = String[shq_path(joinpath(s.root, d)) for d in present if sync_flags(d, :out)]
    script = "mkdir -p " * shq_path(s.root) *
             (isempty(wipe) ? "" : "; rm -rf " * join(wipe, " ")) *
             "; cd " * shq_path(s.root) * " && tar xf -"
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
