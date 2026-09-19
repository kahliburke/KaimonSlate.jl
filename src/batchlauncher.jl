# How batch work gets scheduled. One interface, several backends, and deliberately nothing else:
# provisioning (how code reaches the node) and the store (how blobs move) are separate concerns
# with separate interfaces, because Kubernetes answers all three differently and folding them
# together is what would make it a rewrite later.
#
# The interface is keyed on NAMES, not job ids. A name is content-derived, so the hub can always
# recompute it from the notebook; a job id is exactly the kind of state that goes stale while the
# hub is closed. `poll` therefore asks "is anything running under these names", which is a question
# that can be answered after a restart, a reboot, or from a different machine.
#
# `poll` is also batched by construction. A sweep can have hundreds of submissions and the answer
# has to cost one call, not one call each.

module BatchLauncher

import Dates

export Launcher, ExecLauncher, SlurmLauncher, PbsLauncher, JobSpec, submit!, poll, cancel!, logs,
       log_files, log_tail, log_stat, log_slice, log_search, job_pids

"""
    JobSpec

One submission: run `chunks[i]` as array element `i`. `name` is the dedup token the backend
registers the work under, and is what `poll`/`cancel!` later match on.
"""
struct JobSpec
    name::String
    chunks::Vector{String}
    root::String                 # CAS root, as the COMPUTE node sees it
    project::String              # Julia project the task runs under
    payload::String              # path to slatetask.jl on the compute node
    julia::String                # julia binary (or a module-load prologue can supply it)
    resources::NamedTuple        # (; cpus, mem, walltime, partition, ...)
    logdir::String
    prologue::String             # shell run before julia: `module load`, depot exports, ...
    directives::String           # scheduler flags verbatim, one per line — see `directive_lines`
    # The umask every process writing into this store runs under, e.g. "077". A store on scratch is
    # outside the protection a home directory gives, and a site's default umask is routinely 002 —
    # so without this a sweep's results, its logs, and the source of the body that produced them are
    # world-readable on a machine shared with everyone else who has an account. Empty leaves the
    # site's own default, for a store that is meant to be shared.
    umask::String
    # A submission this one waits for, and how many elements that one had. The second wave of a
    # sweep is queued behind the probe rather than released by something watching from a laptop —
    # the scheduler already knows how to hold a job until another succeeds, and it does not stop
    # knowing when the hub goes away. Empty = nothing to wait for.
    after::String
    after_n::Int
end

JobSpec(name, chunks; root, project, payload, julia = "julia",
        resources = (; cpus = 1, mem = "1G", walltime = "00:30:00", partition = ""),
        logdir = joinpath(root, "logs"), prologue = "", directives = "", umask = "",
        after = "", after_n = 0) =
    JobSpec(String(name), String.(collect(chunks)), String(root), String(project),
            String(payload), String(julia), resources, String(logdir), String(prologue),
            String(directives), String(umask), String(after), Int(after_n))

"""
    directive_lines(text; prefix = "#SBATCH", example = "--constraint=avx512") -> Vector{String}

Free-form scheduler directives → directive lines. One per line; blank lines and `#` comments are
dropped, and a line may be written with or without the prefix (`--exclusive` or
`#SBATCH --exclusive`) because both are what people have in front of them when they are copying from
a working batch script. Either scheduler's prefix is accepted on input, so moving a definition
between clusters does not mean re-typing the block.

This is the escape hatch for a flag whose value contains characters a cell header cannot carry, and
for the site-specific ones there is no point naming (`--licenses`, `--switches`, `--wckey`). It is
emitted verbatim: Slate does not know what a site's flags mean and should not pretend to.
"""
function directive_lines(text::AbstractString; prefix::AbstractString = "#SBATCH",
                         example::AbstractString = "--constraint=avx512")
    out = String[]
    for raw in eachsplit(String(text), '\n')
        s = strip(raw)
        (isempty(s) || startswith(s, "# ") || s == "#") && continue
        for p in ("#SBATCH", "#PBS")
            startswith(s, p) && (s = strip(s[(length(p) + 1):end]); break)
        end
        isempty(s) && continue
        # A directive is one flag. Anything else would be a shell line in a place that only accepts
        # scheduler options, where it is silently ignored rather than run — so say so instead.
        startswith(s, "-") ||
            error("scheduler directive `$s` does not start with `-`. These are scheduler flags " *
                  "(`$example`), one per line; shell setup belongs in the cluster's prologue.")
        push!(out, prefix * " " * s)
    end
    return out
end

abstract type Launcher end

"""
    submit!(launcher, spec) -> String

Start the work and return a backend handle (a job id, a pid). The handle is a convenience for logs
and diagnostics; correctness never depends on the hub remembering it.
"""
function submit! end

"""
    poll(launcher, names) -> Dict{String,Symbol}

State of every name in ONE call: `:pending`, `:running`, or `:unknown`. `:unknown` means the
backend has nothing live under that name, which is deliberately not the same as "finished" — only
the store can answer that, because a job can die without producing anything.
"""
function poll end

"""
    cancel!(launcher, names) -> Int

Cancel anything live under these names. Returns how many names were acted on.
"""
function cancel! end

"Recent output for a name, best effort. Empty string when there is nothing to show."
function logs end

"""
    log_files(launcher, root, name) -> Vector{NamedTuple}

The output files a submission wrote, as `(; path, bytes, modified)` — one per array element.

Listing them is a different question from reading them, and conflating the two is what made a job's
output a single undifferentiated dump: one `tail` across every element of every job, ordered by
however the shell expanded a glob. With the files named, a reader can take the most recent one and
pay for that one only. `modified` is unix time, `0` when the backend could not report it.
"""
function log_files end
# One submission reads better at a call site than a one-element list; the work is the same.
log_files(l, root::AbstractString, name::AbstractString) = log_files(l, root, [String(name)])

"""
    log_tail(launcher, path; lines) -> String

The last `lines` of ONE output file. `path` must be one `log_files` reported: it reaches a shell on
the far side, so a caller that invents paths is writing a command injection.
"""
function log_tail end

# One shell word, whatever it contains. A log path comes back from the browser and is about to be
# interpolated into a command on the far side, so quoting it is not tidiness: inside single quotes
# the shell expands nothing, so a path is a path and never a glob, a variable or a second command.
# (`Sweep.shq` is the same function; this module has no reference to the one that defines it.)
_shq(s) = "'" * replace(String(s), "'" => "'\\''") * "'"

# One output file's facts, portably. `stat` is GNU on Linux and BSD on macOS with no common flags,
# so both spellings are tried and the first that answers wins; a `LocalTarget` on a Mac and a
# cluster login node are the same code path here.
_STAT_LINE = raw"""for f in %GLOB%; do [ -f "$f" ] || continue;
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0);
  b=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0);
  printf '%s\t%s\t%s\n' "$m" "$b" "$f"; done"""

# `<mtime>\t<bytes>\t<path>` lines → entries, newest first.
function _parse_log_listing(txt::AbstractString)
    out = NamedTuple{(:path, :bytes, :modified),Tuple{String,Int,Int}}[]
    for line in split(String(txt), '\n')
        isempty(strip(line)) && continue
        parts = split(line, '\t')
        length(parts) == 3 || continue
        m = tryparse(Int, strip(parts[1])); b = tryparse(Int, strip(parts[2]))
        push!(out, (; path = String(parts[3]), bytes = something(b, 0),
                      modified = something(m, 0)))
    end
    sort!(out; by = e -> (-e.modified, e.path))
    return out
end

# The last `n` lines of a string, for a backend that hands back a whole file.
function _last_lines(s::AbstractString, n::Integer)
    lines = split(String(s), '\n')
    length(lines) <= n && return String(s)
    return join(lines[end-n+1:end], "\n")
end

# 1 MB is far more than `lines` lines of any ordinary log, and a hard bound on what a tail can cost.
const _TAIL_WINDOW = 1 << 20

"""
    tail_file(path, lines; window = _TAIL_WINDOW) -> String

The last `lines` of a file, reading only the END of it.

`read(path, String)` and `readlines` pull the WHOLE file into memory to throw nearly all of it away,
and a job's output has no size bound: a unit printing inside a loop writes until the disk stops it.
Asking for a tail then costs the file, not the tail — and the caller's character cap is applied
after the allocation it was meant to prevent.
"""
function tail_file(path::AbstractString, lines::Integer; window::Integer = _TAIL_WINDOW)
    sz = try; filesize(path); catch; return ""; end
    sz == 0 && return ""
    return open(String(path), "r") do io
        n = min(sz, Int(window))
        seek(io, sz - n)
        s = read(io, String)
        # A window that starts mid-line would show half of one — and, worse, half of a multi-byte
        # character. Dropping to the first newline makes what is left whole on both counts.
        if n < sz
            i = findfirst('\n', s)
            i === nothing ? (s = "") : (s = SubString(s, nextind(s, i)))
        end
        return _last_lines(s, lines)
    end
end

# ── Reading a log that will not fit in memory ────────────────────────────────────────────────
# A job's output has no size bound, and the viewer has to search ALL of it, page backwards through
# it, and stay responsive. So nothing here ever reads a whole file: every call names a byte range,
# and searching is a scan on whichever side the file lives.
#
# Byte offsets are the addressing throughout — not line numbers. A line number cannot be turned into
# a position without counting from the start of the file, which is the one thing a gigabyte forbids;
# an offset can be seeked to directly, and `rg --json` reports one per match for free.

# ripgrep, resolved by UUID rather than imported. `using` reaches only a project's DIRECT
# dependencies, and this file is included into the worker (built against the NOTEBOOK's project) as
# well as the hub — the artifact is on both paths, but named by neither. Falls back to an `rg` on
# PATH, which is what a remote login node offers. `nothing` when there is none, and the caller says
# so rather than pretending the file had no matches.
# ripgrep, resolved SOFTLY and off the request path.
#
# Soft, because this file is included into every worker behind one `try`: a hard `import` that cannot
# resolve takes the whole batch fabric down with it, and a notebook loses `@sweep` entirely because a
# LOG SEARCH dependency was missing. Searching is the only thing here that wants it.
#
# Off the request path, because loading a package is something a process does while starting, not
# while answering. The worker reaches this file by `include`, so the module body below runs at boot
# and the answer is cached before any browser can ask. The hub reaches it as a package, where the
# body is baked at precompile time and cannot run — there it resolves on first use instead, which is
# a lookup of an already-loaded direct dependency rather than a load.
const _RG_UUID = "e10fc14b-37cd-5cbc-b289-ad01b12ebaad"
const _RG = Ref{Any}(missing)         # missing = not looked for yet; nothing = looked, not found

function _resolve_rg()
    try
        m = Base.require(Base.PkgId(Base.UUID(_RG_UUID), "ripgrep_jll"))
        return collect(String, Base.invokelatest(getfield(m, :rg)).exec)
    catch
        w = Sys.which("rg")           # a login node usually has one
        return w === nothing ? nothing : String[w]
    end
end

_rg() = _RG[] === missing ? (_RG[] = _resolve_rg()) : _RG[]

"""
    log_stat(launcher, path) -> (; bytes, modified)

One file's size and mtime, which is all a poll needs to know whether to re-read. `bytes = -1` when
the file cannot be reached at all, which is different from an empty file and reads differently.
"""
function log_stat end

"""
    log_slice(launcher, path; offset, nbytes) -> (; text, from, to, size)

`nbytes` of the file starting at `offset`, with the partial lines at each end trimmed so what comes
back is whole. `from`/`to` are the byte range actually returned, which is how a caller pages
backwards: ask for `[from - N, from)` next.

A negative `offset` counts from the END, so the first page of a viewer that shows newest content
first is `offset = -nbytes` and needs no prior knowledge of the size.
"""
function log_slice end

"""
    log_search(launcher, path, pattern; ignorecase = false, regex = false, limit = 1000)
        -> (; total, hits, capped)

Every line matching `pattern`, as `(; offset, line, text)` — `offset` being the byte position the
viewer seeks to. `total` counts the whole file even when `hits` stops at `limit`, because "3 of 412"
is the number a reader needs and truncating it silently would be a lie about the file.
"""
function log_search end

# The command a task process runs. Written once here so every backend launches identically and a
# bug in the invocation cannot differ between local and cluster runs.
#
# JULIA_PKG_PRECOMPILE_AUTO=0 is not optional: hundreds of tasks starting against an incomplete
# depot would each try to precompile into it, which is how a shared filesystem gets taken down. A
# task must load from a ready depot or fail fast.
function task_command(spec::JobSpec, chunks; heap::AbstractString = "")
    # Before the prologue: whatever a site's `module load` writes belongs to this store too.
    um = isempty(spec.umask) ? "" : "umask " * spec.umask * "\n"
    pre = um * (isempty(spec.prologue) ? "" : spec.prologue * "\n")
    cs = chunks isa AbstractString ? String(chunks) : join(String.(collect(chunks)), " ")
    # A task process runs its chunks in SEQUENCE, so it is long-lived and every unit's garbage
    # passes through one heap. Julia sizes that heap against the machine, which on a workstation
    # means it may grow for a long time before collecting — and a few hundred units that each churn
    # a gigabyte then measure in tens of them. The hint makes it collect instead of grow.
    hh = isempty(heap) ? "" : "--heap-size-hint=" * String(heap) * " "
    return string(pre,
        "export JULIA_PKG_PRECOMPILE_AUTO=0\n",
        spec.julia, " --project=", spec.project, " --startup-file=no ", hh,
        "-e 'include(\"", spec.payload, "\"); exit(SlateTask.main(ARGS))' ",
        spec.root, " ", cs)
end

# The memory a unit may use, as Julia's `--heap-size-hint` wants it. On a SCHEDULER this mirrors what
# the job asked for, so Julia collects rather than being killed for exceeding it.
_heap_hint(spec::JobSpec) = string(get(spec.resources, :mem, ""))

# Locally there is no scheduler and `mem` means nothing: a `LocalTarget` sets no resources, so it
# carries the JobSpec default — hinting THAT would starve a unit that legitimately needs more and
# make Julia collect continuously for no reason. A share of the machine is the honest bound: it
# stops one task process growing into all of memory without pretending to know what a unit needs.
function _local_heap_hint(nproc::Integer)
    total = try; Sys.total_memory(); catch; return ""; end
    total == 0 && return ""
    per = fld(total * 7, 10 * max(1, nproc))
    return string(max(1, fld(per, 1 << 30)), "G")
end

# ── Local execution ──────────────────────────────────────────────────────────────────────────
# No scheduler at all: run the chunks as local subprocesses. This is what makes the whole fabric
# testable without a cluster, and it is also the honest answer for `slate_map` on a laptop.
#
# There is no squeue to ask here, so the launcher keeps its own pid files. That is not a violation
# of "derive, don't store": a pid file is observable state that can be checked against the process
# table, which is precisely what squeue does on a cluster.
struct ExecLauncher <: Launcher
    maxproc::Int
    # Empty runs the work HERE. Otherwise it is a machine with no scheduler on it — a lab box, a
    # cloud VM — reached over its authenticated session, exactly as a login node is. "No scheduler"
    # and "this machine" are separate facts, and welding them together left the useful combination
    # of the two with no way to be said.
    host::String
    # The store AS THE HOST SEES IT. Callers hand every launcher a root, and for a cluster that is
    # the hub's local mirror: right for reading manifests, and a path the far side does not have.
    # The pid files are over there, so this launcher carries where rather than being told. Empty
    # when the work runs here and the two are the same path.
    root::String
    runner::Any                  # (host, script) -> (ok, output)
end
# The binding constraint is MEMORY, not cores: every task process is a separate Julia that loads
# the project, so this is deliberately far below the core count. Raise it only with an eye on RSS.
# A sweep picks its number through `Sweep.local_procs`, which falls back to this when neither the
# target nor the machine setting names one.
default_maxproc() = clamp(Sys.CPU_THREADS ÷ 3, 1, 4)
ExecLauncher(host::AbstractString = ""; maxproc::Int = default_maxproc(), root::AbstractString = "",
             runner = (h, sc) -> _local_run(sc)) =
    ExecLauncher(maxproc, String(host), String(root), runner)

_remote(l::ExecLauncher) = !isempty(l.host)
_there(l::ExecLauncher, script) = l.runner(l.host, script)
# Where THIS launcher's pid files are, which is not where the caller reads manifests. See `root`.
_procfile(l::ExecLauncher, root, name) = _jobfile(isempty(l.root) ? String(root) : l.root, name)

# Warm the cache at module load — see `_rg`. Skipped while PRECOMPILING, which is the package case:
# the body is baked, so the value would be frozen at `missing` anyway and the hub resolves lazily.
ccall(:jl_generating_output, Cint, ()) == 1 || (_RG[] = _resolve_rg())

# NOT `jobs/`. A remote exec submission writes its pid file on the far side, and `jobs/` is the one
# store directory the hub owns outright: a push wipes it and replaces it with the hub's copy, which
# never held those pids. `poll` then found nothing and reported every chunk as no longer running.
_jobdir(root) = joinpath(root, "procs")
_jobfile(root, name) = joinpath(_jobdir(root), name)

_alive(pid::Integer) = pid > 0 && try
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
catch
    false
end

# Chunks are dealt round-robin into at most `maxproc` slices, and each slice becomes ONE process
# that runs its chunks in sequence.
#
# The earlier version started a process per chunk with nothing bounding it, which on a sweep of a
# few hundred units meant dozens of concurrent Julia processes each loading a full project. That is
# gigabytes, and it can take a machine down. On a cluster the scheduler enforces this; running
# locally there is nothing but this function.
function _deal(chunks, n)
    n = max(1, min(n, length(chunks)))
    slices = [String[] for _ in 1:n]
    for (i, c) in enumerate(chunks); push!(slices[mod1(i, n)], String(c)); end
    return filter(!isempty, slices)
end

function submit!(l::ExecLauncher, spec::JobSpec)
    isempty(spec.chunks) && return ""
    slices = _deal(spec.chunks, l.maxproc)
    # A hint from THIS machine's memory, which is the right answer only when the work runs here.
    # A remote box is sized by whoever configured it, so nothing is imposed on it.
    heap = _remote(l) ? "" : _local_heap_hint(length(slices))
    pids = _remote(l) ? _exec_start_there(l, spec, slices, heap) :
                        _exec_start_here(spec, slices, heap)
    return join(pids, ",")
end

function _exec_start_here(spec::JobSpec, slices, heap)
    mkpath(_jobdir(spec.root)); mkpath(spec.logdir)
    # Running here, the store is on this machine and `task_command` carries the umask into the task
    # process; the directories it writes into are made now, so they get it explicitly.
    isempty(spec.umask) || for d in (_jobdir(spec.root), spec.logdir)
        try; chmod(d, 0o777 & ~parse(UInt16, spec.umask; base = 8)); catch; end
    end
    pids = Int[]
    for (i, slice) in enumerate(slices)
        logf = joinpath(spec.logdir, "$(spec.name).$(i).log")
        cmd = pipeline(Cmd(`sh -c $(task_command(spec, slice; heap = heap))`);
                       stdout = logf, stderr = logf)
        p = run(cmd; wait = false)
        push!(pids, getpid(p))
    end
    write(_jobfile(spec.root, spec.name), join(pids, "\n"))
    return pids
end

# One round trip starts every slice and hands back their pids. `nohup … &` with stdin closed is
# what survives the session closing: there is no scheduler here to own the process, so the only
# thing keeping it alive is its own detachment.
#
# The pid file is written ON THE FAR SIDE, where the pids mean something — the same place `poll`
# and `cancel!` read it from. A pid is only meaningful to the kernel that issued it.
function _exec_start_there(l::ExecLauncher, spec::JobSpec, slices, heap)
    # The log files are created by THIS shell's redirection, not by the task process, so the umask
    # has to be set here as well as inside `task_command`.
    lines = [isempty(spec.umask) ? ":" : "umask " * spec.umask,
             "mkdir -p $(_shq(_jobdir(spec.root))) $(_shq(spec.logdir))", "pids=''"]
    for (i, slice) in enumerate(slices)
        logf = joinpath(spec.logdir, "$(spec.name).$(i).log")
        push!(lines, "nohup sh -c $(_shq(task_command(spec, slice; heap = heap))) " *
                     "> $(_shq(logf)) 2>&1 < /dev/null &")
        push!(lines, "pids=\"\$pids \$!\"")
    end
    push!(lines, "printf '%s\\n' \$pids > $(_shq(_jobfile(spec.root, spec.name)))")
    push!(lines, "printf '%s\\n' \$pids")
    ok, out = _there(l, join(lines, "\n"))
    ok || error("could not start work on $(l.host): " * first(strip(String(out)), 300))
    return [something(tryparse(Int, s), 0) for s in split(String(out); keepempty = false)]
end

"""
    job_pids(launcher, root, name) -> Vector{Int}

The process ids a submission started, in array-task order — so `pids[i]` is the process that wrote
`<name>.<i>.log`. Empty for a launcher whose work runs somewhere this machine cannot signal: a
scheduler's own job id is what identifies those, and `poll` already reports it.

A pid is reported as the historical fact that it is. Whether it is still ALIVE is deliberately not,
because the answer stops being trustworthy the moment the process exits and the OS hands the number
to something else — the chunk's own status says whether it is still going.
"""
job_pids(::Launcher, ::AbstractString, ::AbstractString) = Int[]

function job_pids(l::ExecLauncher, root::AbstractString, name::AbstractString)
    f = _procfile(l, root, String(name))
    txt = if _remote(l)
        ok, o = _there(l, "cat $(_shq(f)) 2>/dev/null")
        ok ? String(o) : ""
    else
        isfile(f) ? read(f, String) : ""
    end
    return [something(tryparse(Int, x), 0) for x in split(txt; keepempty = false)]
end

function poll(l::ExecLauncher, root::AbstractString, names)
    _remote(l) && return _exec_poll_there(l, root, names)
    out = Dict{String,Symbol}()
    for name in names
        f = _procfile(l, root, name)
        if !isfile(f)
            out[String(name)] = :unknown
            continue
        end
        pids = [something(tryparse(Int, s), 0) for s in split(read(f, String); keepempty = false)]
        out[String(name)] = any(_alive, pids) ? :running : :unknown
    end
    return out
end

# Every name in ONE round trip, like every other backend's poll: a sweep can have hundreds of
# submissions and the answer has to cost one call, not one call each. `kill -0` is the far side's
# `_alive` — it signals nothing and only asks whether the pid is still there.
function _exec_poll_there(l::ExecLauncher, root, names)
    out = Dict{String,Symbol}(String(n) => :unknown for n in names)
    isempty(out) && return out
    lines = String[]
    for name in names
        f = _procfile(l, root, name)
        push!(lines, "n=0; if [ -f $(_shq(f)) ]; then while read p; do " *
                     "[ -n \"\$p\" ] && kill -0 \$p 2>/dev/null && n=\$((n+1)); " *
                     "done < $(_shq(f)); fi; printf '%s\\t%s\\n' $(_shq(String(name))) \$n")
    end
    ok, txt = _there(l, join(lines, "\n"))
    ok || return out
    for line in eachsplit(String(txt), '\n'; keepempty = false)
        parts = split(line, '\t'); length(parts) == 2 || continue
        alive = something(tryparse(Int, strip(parts[2])), 0)
        out[String(strip(parts[1]))] = alive > 0 ? :running : :unknown
    end
    return out
end

function cancel!(l::ExecLauncher, root::AbstractString, names)
    _remote(l) && return _exec_cancel_there(l, root, names)
    n = 0
    for name in names
        f = _procfile(l, root, name); isfile(f) || continue
        for s in split(read(f, String); keepempty = false)
            pid = tryparse(Int, s); pid === nothing && continue
            _alive(pid) && (try; ccall(:kill, Cint, (Cint, Cint), pid, 15); catch; end)
        end
        rm(f; force = true); n += 1
    end
    return n
end

function _exec_cancel_there(l::ExecLauncher, root, names)
    lines = String[]
    for name in names
        f = _procfile(l, root, name)
        push!(lines, "if [ -f $(_shq(f)) ]; then while read p; do " *
                     "[ -n \"\$p\" ] && kill -TERM \$p 2>/dev/null; done < $(_shq(f)); " *
                     "rm -f $(_shq(f)); echo x; fi")
    end
    isempty(lines) && return 0
    ok, txt = _there(l, join(lines, "\n"))
    return ok ? count(==("x"), [strip(s) for s in eachsplit(String(txt), '\n'; keepempty = false)]) : 0
end

function log_files(l::ExecLauncher, root::AbstractString, names::AbstractVector)
    # `.log` here, not the scheduler's `.out`: this launcher names its own files.
    _remote(l) && return _remote_log_files((sc) -> _there(l, sc), root, names; ext = "log")
    dir = joinpath(String(root), "logs")
    isdir(dir) || return NamedTuple{(:path, :bytes, :modified),Tuple{String,Int,Int}}[]
    want = Set(String(n) * "." for n in names)
    out = NamedTuple{(:path, :bytes, :modified),Tuple{String,Int,Int}}[]
    for f in readdir(dir; join = true)
        any(p -> startswith(basename(f), p), want) || continue
        isfile(f) || continue
        push!(out, (; path = f, bytes = Int(filesize(f)),
                      modified = try; round(Int, mtime(f)); catch; 0; end))
    end
    sort!(out; by = e -> (-e.modified, e.path))
    return out
end

function log_stat(l::ExecLauncher, path::AbstractString)
    _remote(l) && return _remote_log_stat((sc) -> _there(l, sc), path)
    isfile(path) || return (; bytes = -1, modified = 0)
    return (; bytes = Int(filesize(path)),
              modified = try; round(Int, mtime(path)); catch; 0; end)
end

# Trim to whole lines at BOTH ends. A window that begins mid-line shows half of one, and — worse —
# can begin mid-character, so the bytes do not decode. Dropping to the first newline fixes both.
# The end is only trimmed when there is more file after it; the last line of a file is whole.
#
# `aligned` says the offset is ALREADY a line start, in which case trimming would throw away a whole
# good line — which is exactly what a search hit is, since `rg` reports the offset of the line's
# first byte. The caller establishes it by looking at the byte before, so no API carries the claim.
function _whole_lines(buf::Vector{UInt8}, from::Int, size::Int; aligned::Bool = false)
    lo = 1
    if from > 0 && !aligned
        i = findfirst(==(UInt8('\n')), buf)
        i === nothing ? (return ("", from, from)) : (lo = i + 1)
    end
    hi = length(buf)
    if from + length(buf) < size
        j = findlast(==(UInt8('\n')), buf)
        j === nothing ? (return ("", from, from)) : (hi = j)
    end
    lo > hi && return ("", from + lo - 1, from + lo - 1)
    return (String(@view buf[lo:hi]), from + lo - 1, from + hi - 1)
end

function log_slice(l::ExecLauncher, path::AbstractString; offset::Integer = -1 << 16,
                   nbytes::Integer = 1 << 16)
    _remote(l) && return _remote_log_slice((sc) -> _there(l, sc), path, offset, nbytes)
    isfile(path) || return (; text = "", from = 0, to = 0, size = 0)
    size = Int(filesize(path))
    n = max(0, Int(nbytes))
    from = Int(offset) < 0 ? max(0, size + Int(offset)) : min(Int(offset), size)
    n = min(n, size - from)
    n <= 0 && return (; text = "", from, to = from, size)
    buf, aligned = open(path, "r") do io
        a = true
        if from > 0                          # is `from` already the first byte of a line?
            seek(io, from - 1)
            a = read(io, UInt8) == UInt8('\n')
        end
        seek(io, from)
        (read(io, n), a)
    end
    text, lo, hi = _whole_lines(buf, from, size; aligned)
    return (; text, from = lo, to = hi, size)
end

# `rg --json` emits one object per event; a `match` carries `absolute_offset` and the line's text,
# which is exactly the pair the viewer needs and avoids parsing a `grep -bn` prefix out of content
# that may itself contain colons. `--count-matches` is a second, cheap pass for the true total.
function log_search(l::ExecLauncher, path::AbstractString, pattern::AbstractString;
                    ignorecase::Bool = false, regex::Bool = false, limit::Integer = 1000)
    _remote(l) && return _remote_log_search((sc) -> _there(l, sc), path, pattern,
                                            ignorecase, regex, limit)
    (isfile(path) && !isempty(pattern)) ||
        return (; total = 0, hits = NamedTuple{(:offset, :line, :text),Tuple{Int,Int,String}}[],
                  capped = false)
    rg = _rg()
    rg === nothing && error("log search needs ripgrep, and neither the bundled artifact nor an " *
                            "`rg` on PATH could be found")
    return _rg_search(rg, path, pattern, ignorecase, regex, limit)
end

# Two passes, because the two answers have very different costs. The count is one integer however
# many times the pattern occurs; the hit list is a JSON object per match, which for a term appearing
# on most lines runs to several times the size of the file. `-m` bounds what ripgrep EMITS, so the
# limit is enforced at the source rather than by discarding what has already crossed a pipe.
# What ripgrep said, as one line a reader can act on. Its complaint spans several lines of caret-art
# pointing into the pattern — helpful in a terminal, noise in a status bar — and the sentence worth
# keeping is the one it labels `error:`.
function _rg_message(err::AbstractString)
    best = ""
    for l in eachsplit(err, '\n')
        s = String(strip(l))
        (isempty(s) || startswith(s, "^") || startswith(s, "|") || startswith(s, "=")) && continue
        s = replace(s, r"^rg: *" => "")
        startswith(s, "error:") && return "search pattern rejected: " * strip(s[7:end])
        isempty(best) && (best = s)
    end
    return isempty(best) ? "the search pattern was rejected" : first(best, 200)
end

function _rg_search(rg, path, pattern, ignorecase, regex, limit)
    flags = String[]
    ignorecase && push!(flags, "-i")
    regex || push!(flags, "-F")
    # ripgrep says which of the two it is: 1 is "no matches", 2 is "I could not do that" — an
    # unbalanced regex, an unreadable file. Treating both as no matches turns a pattern the engine
    # rejected into a confident answer of zero, which is the one reply a searcher cannot question.
    run_rg(extra) = begin
        out, err = IOBuffer(), IOBuffer()
        cmd = Cmd(String[rg..., flags..., extra..., "--", String(pattern), String(path)])
        code = try
            run(pipeline(ignorestatus(cmd); stdout = out, stderr = err)).exitcode
        catch e
            error("could not run ripgrep: " * first(sprint(showerror, e), 160))
        end
        code >= 2 && error(_rg_message(String(take!(err))))
        return String(take!(out))
    end
    total = something(tryparse(Int, strip(run_rg(["-c"]))), 0)
    hits = NamedTuple{(:offset, :line, :text),Tuple{Int,Int,String}}[]
    n = max(0, Int(limit))
    if n > 0 && total > 0
        for ln in eachsplit(run_rg(["--json", "-m", string(n)]), '\n'; keepempty = false)
            # Deliberately not a JSON parse: these lines are machine-written, one per event, and the
            # three fields wanted are flat. Pulling them out directly keeps this free of a JSON
            # dependency in a file that is included into the worker.
            occursin("\"type\":\"match\"", ln) || continue
            push!(hits, (; offset = _json_int(ln, "absolute_offset"),
                           line = _json_int(ln, "line_number"), text = _json_text(ln)))
        end
    end
    return (; total, hits, capped = total > length(hits))
end

function _json_int(s::AbstractString, key::AbstractString)
    i = findfirst("\"$key\":", s); i === nothing && return 0
    j = nextind(s, last(i))
    k = j
    while k <= lastindex(s) && !isdigit(s[k]); k = nextind(s, k); end
    e = k
    while e <= lastindex(s) && isdigit(s[e]); e = nextind(s, e); end
    return something(tryparse(Int, s[k:prevind(s, e)]), 0)
end

# A match's line text lives at `"lines":{"text":"…"}`. Binary or invalid UTF-8 comes back as
# `{"bytes":"<base64>"}` instead, which is reported as such rather than guessed at.
function _json_text(s::AbstractString)
    i = findfirst("\"lines\":{\"text\":\"", s)
    i === nothing && return "(binary)"
    j = nextind(s, last(i))
    io = IOBuffer()
    while j <= lastindex(s)
        c = s[j]
        if c == '\\'
            j = nextind(s, j); j > lastindex(s) && break
            d = s[j]
            print(io, d == 'n' ? '\n' : d == 't' ? '\t' : d == 'r' ? '\r' :
                      d == '"' ? '"' : d == '\\' ? '\\' : d)
        elseif c == '"'
            break
        else
            print(io, c)
        end
        j = nextind(s, j)
    end
    return rstrip(String(take!(io)), '\n')
end

log_tail(l::ExecLauncher, path::AbstractString; lines::Int = 500) =
    _remote(l) ? _remote_log_tail((sc) -> _there(l, sc), path, lines) :
    isfile(path) ? tail_file(path, lines) : ""

function logs(l::ExecLauncher, root::AbstractString, name::AbstractString; lines::Int = 200)
    dir = joinpath(root, "logs")
    isdir(dir) || return ""
    fs = filter(f -> startswith(basename(f), String(name) * "."), readdir(dir; join = true))
    isempty(fs) && return ""
    buf = IOBuffer()
    per = max(1, lines ÷ length(fs))
    for f in fs
        println(buf, "== ", basename(f), " ==")
        # `readlines` read the whole file to keep its last few lines — see `tail_file`.
        println(buf, tail_file(f, per))
    end
    return String(take!(buf))
end

# ── SLURM ────────────────────────────────────────────────────────────────────────────────────
# One array job per submission: the scheduler sees a single entry with N elements, which is what
# array jobs exist for, instead of N separate jobs competing in the queue.
#
# Array element i runs chunks[i], resolved through an index file written next to the job. The hub
# never needs that mapping back: per-chunk progress comes from the status directory, and per-shard
# completion comes from the store.
struct SlurmLauncher <: Launcher
    host::String                 # the login node; "" runs the client tools locally
    account::String
    qos::String
    runner::Any                  # (host, script) -> (ok, output); the caller's authenticated session
end
# The default runner is a plain local shell, which is what the tests use and what running ON a login
# node needs. Anything reaching a remote cluster passes its own.
SlurmLauncher(host = ""; account = "", qos = "",
              runner = (h, sc) -> _local_run(sc)) =
    SlurmLauncher(String(host), String(account), String(qos), runner)

function _local_run(script::AbstractString)
    buf = IOBuffer()
    ok = try; run(pipeline(`sh -c $script`; stdout = buf, stderr = buf)); true; catch; false; end
    return (ok, String(take!(buf)))
end

# An empty host means the SLURM client tools are on THIS machine, which is the case when Slate runs
# on a login node (a common enough deployment that it should not need a loopback ssh) and when the
# reconciler itself runs inside the cluster. Everything else about the backend is identical, so the
# two cases differ only in how a command is wrapped.
# Returns `(ok, output)` — the runner is the caller's authenticated session, not a Cmd.
_ssh(l::SlurmLauncher, script::AbstractString) = l.runner(l.host, String(script))

function _run_capture(cmd::Cmd)
    buf = IOBuffer()
    ok = try; run(pipeline(cmd; stdout = buf, stderr = buf)); true; catch; false; end
    return (ok, String(take!(buf)))
end

# The batch script. `$SLURM_ARRAY_TASK_ID` picks this element's chunk out of the index file, so one
# script serves every element and the mapping lives on the shared filesystem rather than in the
# submission.
# The three settings whose Slate name differs from sbatch's, because they predate the rest. Every
# other key becomes its own flag with `_` → `-` — which is what lets an option Slate has never heard
# of work anyway (`--licenses`, `--switches`, a scheduler patch a site added last week).
const _SBATCH_RENAME = Dict(:cpus => "cpus-per-task", :walltime => "time", :gpus => "gpus")

sbatch_flag(k::Symbol) = get(_SBATCH_RENAME, k, replace(String(k), '_' => '-'))

# `--exclusive` is the one flag whose VALUE is optional (`--exclusive`, or `=user`/`=mcs`/`=topo`),
# so it cannot be emitted as a plain `--key=value`.
function _exclusive_line(v)
    s = strip(String(v))
    (isempty(s) || lowercase(s) in ("no", "false", "0")) && return nothing
    return lowercase(s) in ("yes", "true", "1") ? "#SBATCH --exclusive" : "#SBATCH --exclusive=$s"
end

# The three Slate always emits, because a job with no cores, memory or time limit is at the mercy of
# whatever the site's defaults happen to be — and those are the numbers a sweep most needs to state.
const _SBATCH_ALWAYS = (cpus = 1, mem = "1G", walltime = "00:30:00")

function _sbatch_script(l::SlurmLauncher, spec::JobSpec, indexfile::AbstractString)
    r = spec.resources
    for k in sort!(collect(keys(r)))
        haskey(_SBATCH_HINT, k) && _hint_once(:SLURM, k, _SBATCH_HINT[k], "--$(sbatch_flag(k))=…")
    end
    lines = ["#!/bin/bash",
             "#SBATCH --job-name=$(spec.name)",
             "#SBATCH --array=1-$(length(spec.chunks))",

             "#SBATCH --output=$(spec.logdir)/$(spec.name).%A_%a.out",
             "#SBATCH --cpus-per-task=$(get(r, :cpus, _SBATCH_ALWAYS.cpus))",
             "#SBATCH --mem=$(get(r, :mem, _SBATCH_ALWAYS.mem))",
             "#SBATCH --time=$(get(r, :walltime, _SBATCH_ALWAYS.walltime))",
             # ONE `--dependency`, because SLURM keeps only the last one it is given. Two lines
             # would silently drop the first, which is the wave-ordering this exists for.
             #
             # `singleton` prevents a duplicate submission across a hub restart: only one job of
             # this name per user runs, and the name is content-derived. `afterok` on an array job
             # waits for every element, so the probe's own size changes nothing. Comma is AND.
             "#SBATCH --dependency=" *
                 (isempty(spec.after) ? "singleton" : "afterok:$(spec.after),singleton")]
    # Everything else the spec carries, sorted so two identical sweeps produce identical scripts.
    # A key absent from the spec emits no line at all: writing `--nodes=1` where the author asked
    # for nothing would override the partition's own configuration with a guess.
    #
    # Deduplicated by the FLAG, not the key: three options have a Slate name that differs from
    # sbatch's, so `cpus` and `cpus_per_task` are the same setting reached two ways. A spec holding
    # both (an older notebook, a hand-edited footer) would emit `--cpus-per-task` twice — which
    # sbatch tolerates by taking the last, and a reader does not. The explicit key wins over the one
    # already emitted above.
    seen = Set{String}(["job-name", "array", "output", "cpus-per-task", "mem", "time",
                        "dependency", "account", "qos"])
    for k in sort!(collect(keys(r)))
        k in (:cpus, :mem, :walltime, :account, :qos, :exclusive) && continue
        v = getfield(r, k)
        (v === nothing || isempty(string(v))) && continue
        f = sbatch_flag(k)
        if f in seen
            # An alias of something already written: replace that line rather than adding a second.
            i = findfirst(l -> startswith(l, "#SBATCH --$f="), lines)
            i === nothing || (lines[i] = "#SBATCH --$f=$(v)")
            continue
        end
        push!(seen, f)
        push!(lines, "#SBATCH --$f=$(v)")
    end
    # Account and QoS default to the SITE's (they are a property of the launcher), but a cell may
    # override them — someone with two allocations bills one sweep to each.
    for (k, site) in ((:account, l.account), (:qos, l.qos))
        v = string(get(r, k, site))
        isempty(v) || push!(lines, "#SBATCH --$(sbatch_flag(k))=$(v)")
    end
    exc = _exclusive_line(get(r, :exclusive, ""))
    exc === nothing || push!(lines, exc)
    # Site directives, verbatim and LAST so they win over everything above (sbatch takes the last
    # occurrence of a repeated option). This is what a flag whose value a cell header cannot carry
    # uses, and what makes a definition able to say everything a hand-written `#SBATCH` block said.
    append!(lines, directive_lines(spec.directives))
    append!(lines, ["set -euo pipefail",
                    "CHUNK=\$(sed -n \"\${SLURM_ARRAY_TASK_ID}p\" $(indexfile))",
                    "test -n \"\$CHUNK\"",
                    replace(task_command(spec, "\$CHUNK"), "\n" => "\n")])
    return join(lines, "\n") * "\n"
end

function submit!(l::SlurmLauncher, spec::JobSpec)
    isempty(spec.chunks) && return ""
    indexfile = joinpath(spec.root, "jobs", spec.name * ".index")
    script = _sbatch_script(l, spec, indexfile)
    # Write the index and the script on the far side, then submit. Heredocs keep it to one ssh
    # round trip and avoid quoting the script through two shells.
    payload = """
    set -e
    mkdir -p $(joinpath(spec.root, "jobs")) $(spec.logdir)
    cat > $(indexfile) <<'SLATE_INDEX_EOF'
    $(join(spec.chunks, "\n"))
    SLATE_INDEX_EOF
    cat > $(indexfile).sbatch <<'SLATE_SBATCH_EOF'
    $(script)SLATE_SBATCH_EOF
    sbatch --parsable $(indexfile).sbatch
    """
    ok, out = (_ssh(l, payload))
    ok || error("sbatch failed on $(l.host): $(strip(out))")
    return strip(split(strip(out), '\n')[end])
end

function poll(l::SlurmLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return Dict{String,Symbol}()
    out = Dict{String,Symbol}(n => :unknown for n in ns)
    # One call for every name. squeue lists only live jobs, so anything absent stays :unknown and
    # the store decides whether that means finished or lost.
    ok, txt = (_ssh(l, "squeue -h -o '%j %T' --name=$(join(ns, ','))"))
    ok || return out
    for line in split(txt, '\n'; keepempty = false)
        parts = split(strip(line))
        length(parts) >= 2 || continue
        name, state = String(parts[1]), uppercase(String(parts[2]))
        haskey(out, name) || continue
        # A name with several elements in flight reports RUNNING as soon as any element runs.
        if state == "RUNNING" || out[name] === :running
            out[name] = :running
        elseif state in ("PENDING", "CONFIGURING", "REQUEUED", "RESIZING", "SUSPENDED")
            out[name] === :running || (out[name] = :pending)
        else
            out[name] === :running || (out[name] = :pending)
        end
    end
    return out
end

# ONE scancel per name. `--name` takes a single job name: `scancel --name=a,b` matches nothing and
# still EXITS 0, so batching them reported every job cancelled while the work carried on running —
# a cancel that silently keeps burning the allocation. Verified against SLURM 24.11.
#
# Sent as one ssh round trip regardless, and the count comes from what actually left the queue
# rather than from scancel's exit status, which says nothing about whether a name matched.
function cancel!(l::SlurmLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return 0
    before = poll(l, root, ns)
    live = [n for n in ns if get(before, n, :unknown) in (:pending, :running)]
    isempty(live) && return 0
    (_ssh(l, join(("scancel --name=$(n)" for n in live), "; ")))
    after = poll(l, root, live)
    return count(n -> !(get(after, n, :unknown) in (:pending, :running)), live)
end

function logs(l::SlurmLauncher, root::AbstractString, name::AbstractString; lines::Int = 200)
    ok, txt = (_ssh(l,
        "tail -n $(lines) $(joinpath(root, "logs"))/$(name).*.out 2>/dev/null"))
    return ok ? txt : ""
end

# Both schedulers list and tail identically: the files are on a filesystem reached through the same
# session, and which scheduler wrote them does not change how they are read.
# Every named submission in ONE round trip. A sweep is reconciled, so it is normally several
# submissions, and asking per name made opening the viewer cost a login-node round trip each. The
# globs are listed rather than the whole directory: a store holds every run the sweep ever made,
# and listing all of that to throw most of it away is the other way to be slow.
_remote_log_files(runner, root, names::AbstractVector; ext::AbstractString = "out") = begin
    out = NamedTuple{(:path, :bytes, :modified),Tuple{String,Int,Int}}[]
    isempty(names) && return out
    dir = joinpath(String(root), "logs")
    # Chunked, so the script cannot grow without bound on a sweep with very many submissions.
    for part in Iterators.partition(names, 150)
        glob = join(("$(dir)/$(n).*.$(ext)" for n in part), " ")
        ok, txt = runner(replace(_STAT_LINE, "%GLOB%" => glob) * " 2>/dev/null")
        # A glob matching nothing still exits 0 with no output, so a failure here is the transport
        # and not an empty logs directory. Reported, because the alternative reads as "no output".
        ok || error("could not list job output on the far side: " *
                    first(strip(String(txt)), 200))
        append!(out, _parse_log_listing(txt))
    end
    sort!(out; by = e -> (-e.modified, e.path))
    return out
end
_remote_log_files(runner, root, name; ext::AbstractString = "out") =
    _remote_log_files(runner, root, [name]; ext)
_remote_log_tail(runner, path, lines) = begin
    ok, txt = runner("tail -n $(Int(lines)) " * _shq(String(path)) * " 2>/dev/null")
    ok ? txt : ""
end

# The same three primitives, on the far side. Each is ONE command: a login node is reached over a
# shared connection and a round trip costs more than the work, so nothing here reads a file twice.
_remote_log_stat(runner, path) = begin
    q = _shq(String(path))
    ok, txt = runner("[ -f $q ] || exit 1; " *
                     "m=\$(stat -c %Y $q 2>/dev/null || stat -f %m $q 2>/dev/null || echo 0); " *
                     "b=\$(stat -c %s $q 2>/dev/null || stat -f %z $q 2>/dev/null || echo 0); " *
                     "printf '%s\\t%s\\n' \"\$m\" \"\$b\"")
    ok || return (; bytes = -1, modified = 0)
    parts = split(strip(String(txt)), '\t')
    length(parts) == 2 || return (; bytes = -1, modified = 0)
    return (; bytes = something(tryparse(Int, parts[2]), 0),
              modified = something(tryparse(Int, parts[1]), 0))
end

# `dd` with explicit byte units, the same primitive `range_command` uses for a blob: it seeks rather
# than streaming the file through `tail`, so the cost is the range and not the offset.
function _remote_log_slice(runner, path, offset::Integer, nbytes::Integer)
    st = _remote_log_stat(runner, path)
    st.bytes < 0 && return (; text = "", from = 0, to = 0, size = 0)
    size = st.bytes
    n = max(0, Int(nbytes))
    from = Int(offset) < 0 ? max(0, size + Int(offset)) : min(Int(offset), size)
    n = min(n, size - from)
    n <= 0 && return (; text = "", from, to = from, size)
    # One byte earlier when there is one, so the caller can tell whether `from` was already a line
    # boundary — the same question `log_slice` answers locally by peeking behind the offset.
    back = from > 0 ? 1 : 0
    ok, txt = runner("dd if=" * _shq(String(path)) * " bs=1 skip=$(from - back) " *
                     "count=$(n + back) iflag=skip_bytes,count_bytes 2>/dev/null")
    ok || return (; text = "", from, to = from, size)
    buf = Vector{UInt8}(String(txt))
    aligned = back == 1 ? (!isempty(buf) && buf[1] == UInt8('\n')) : true
    back == 1 && !isempty(buf) && (buf = buf[2:end])
    text, lo, hi = _whole_lines(buf, from, size; aligned)
    return (; text, from = lo, to = hi, size)
end

# rg when the far side has it — the JSON carries the byte offset, which is what the viewer seeks to.
# Otherwise `grep -bn`, whose `offset:line:text` prefix carries the same two numbers; the content
# may itself contain colons, so only the first two are split off.
function _remote_log_search(runner, path, pattern, ignorecase, regex, limit)
    q = _shq(String(path)); pq = _shq(String(pattern))
    ic = ignorecase ? " -i" : ""
    fixed = regex ? "" : " -F"
    ok, txt = runner("if command -v rg >/dev/null 2>&1; then " *
                     "rg$(ic)$(fixed) --json -- $pq $q; else " *
                     "grep -b -n$(ic)$(regex ? " -E" : " -F") -- $pq $q; fi 2>/dev/null")
    hits = NamedTuple{(:offset, :line, :text),Tuple{Int,Int,String}}[]
    total = 0
    ok || return (; total, hits, capped = false)
    for ln in eachsplit(String(txt), '\n'; keepempty = false)
        if occursin("\"type\":\"match\"", ln)
            total += 1
            length(hits) < limit &&
                push!(hits, (; offset = _json_int(ln, "absolute_offset"),
                               line = _json_int(ln, "line_number"), text = _json_text(ln)))
        elseif !startswith(ln, "{")
            # grep: `<byteoffset>:<lineno>:<text>`
            a = findfirst(':', ln); a === nothing && continue
            b = findnext(':', ln, a + 1); b === nothing && continue
            off = tryparse(Int, ln[1:a-1]); no = tryparse(Int, ln[a+1:b-1])
            (off === nothing || no === nothing) && continue
            total += 1
            length(hits) < limit && push!(hits, (; offset = off, line = no, text = ln[b+1:end]))
        end
    end
    return (; total, hits, capped = total > length(hits))
end

log_files(l::SlurmLauncher, root::AbstractString, names::AbstractVector) =
    _remote_log_files(sc -> _ssh(l, sc), root, names)
log_tail(l::SlurmLauncher, path::AbstractString; lines::Int = 500) =
    _remote_log_tail(sc -> _ssh(l, sc), path, lines)
log_stat(l::SlurmLauncher, path::AbstractString) = _remote_log_stat(sc -> _ssh(l, sc), path)
log_slice(l::SlurmLauncher, path::AbstractString; offset::Integer = -(1 << 16),
          nbytes::Integer = 1 << 16) =
    _remote_log_slice(sc -> _ssh(l, sc), path, offset, nbytes)
log_search(l::SlurmLauncher, path::AbstractString, pattern::AbstractString; ignorecase::Bool = false,
           regex::Bool = false, limit::Integer = 1000) =
    _remote_log_search(sc -> _ssh(l, sc), path, pattern, ignorecase, regex, limit)

"""
    explain_failure(l::SlurmLauncher, name) -> String

Why a submission's elements ended, from accounting. Only ever consulted to explain a failure:
whether a shard is done is a question for the store, since `sacct` needs site-configured accounting
and may return nothing at all.
"""
function explain_failure(l::SlurmLauncher, name::AbstractString)
    ok, txt = (_ssh(l,
        "sacct -n -X --name=" * _shq(String(name)) *
        " -o JobID,State,ExitCode,Elapsed,MaxRSS 2>/dev/null"))
    return ok ? txt : ""
end

# ── PBS ──────────────────────────────────────────────────────────────────────────────────────
# The other scheduler a site is likely to have, and NOT a renaming of the one above. Three things
# differ in kind rather than in spelling, and each of them is a decision made below:
#
#   * PBS asks for per-node resources INSIDE a chunk statement (`-l select=2:ncpus=8:mem=16gb`) and
#     for job-wide ones beside it (`-l walltime=…`). SLURM's one-flag-per-setting form has no chunk,
#     so the pass-through rule needs a shape here, not just a different flag name.
#   * There is no `--dependency=singleton`, which is what stopped a SLURM sweep double-submitting
#     across a hub restart. PBS will happily queue two jobs of the same name, so the check the
#     scheduler used to do is done in the submission itself.
#   * Names are the interface (see the top of this file), and PBS cannot cancel by name. `qselect`
#     turns a name into ids and `qdel` takes those, which is two commands and still one round trip.
struct PbsLauncher <: Launcher
    host::String                 # the login node; "" runs the client tools locally
    account::String
    qos::String
    runner::Any                  # (host, script) -> (ok, output); the caller's authenticated session
end
PbsLauncher(host = ""; account = "", qos = "",
            runner = (h, sc) -> _local_run(sc)) =
    PbsLauncher(String(host), String(account), String(qos), runner)

_ssh(l::PbsLauncher, script::AbstractString) = l.runner(l.host, String(script))

# The settings that go INSIDE the chunk statement — what one node of the job must have.
# `nodelist` is `vnode`, NOT `host`. They are different names and only coincide on a cluster whose
# vnodes are named after their physical hosts: `host` is what the mom reports for the machine, while
# `vnode` is the name `pbsnodes` lists and `exec_host` reports — so it is the one a user has, and the
# one `find_allocation` hands back as the node. `host=` silently matches nothing and the job queues
# forever with the node sitting idle.
const _PBS_CHUNK = Dict(:cpus => "ncpus", :gpus => "ngpus", :mem => "mem",
                        :ntasks_per_node => "mpiprocs", :nodelist => "vnode")

# Settings whose usual SLURM meaning has no PBS form. ADVISORY, not a block: the editor shows the
# note, and the option is still forwarded as `-l key=value` like any other.
#
# Refusing them outright was tried and is wrong. PBS lets a site define ARBITRARY resources
# (`qmgr -c "create resource ntasks type=long"`), so a name that means one thing on SLURM may be a
# real resource here — and blocking it because SLURM uses the word contradicts the rule at the top
# of this file. A site that has no such resource gets `Unknown resource: constraint` from `qsub`,
# which is the loud rejection that rule is asking for.
const _PBS_HINT = Dict(
    :constraint  => "usually a chunk resource on PBS — see `select=`",
    :gres        => "usually `gpus=` (a count), or `select=…:ngpus=2:gpu_model=v100`",
    :exclude     => "PBS has no exclude list — pick a queue, or name nodes with `select=…:vnode=`",
    :reservation => "a PBS reservation IS a queue — usually `partition=`",
    :ntasks      => "PBS counts per chunk — usually `nodes=` and `ntasks_per_node=`",
)

# `select=` is PBS's chunk statement and sbatch has no such option. Same treatment in reverse.
const _SBATCH_HINT = Dict(
    :select => "PBS's chunk statement — on SLURM say `nodes=`, `cpus=`, `mem=`, `gpus=`",
)

# Warned once per setting per process: a sweep emits a script per submission, and the same advice a
# few hundred times would bury the run's own output.
const _HINTED = Set{Tuple{Symbol,Symbol}}()
const _HINT_LOCK = ReentrantLock()

function _hint_once(kind::Symbol, k::Symbol, note::AbstractString, flag::AbstractString)
    fresh = lock(_HINT_LOCK) do; (kind, k) in _HINTED ? false : (push!(_HINTED, (kind, k)); true); end
    fresh || return nothing
    @warn "`$k` has no standard $(kind) equivalent — $(note). Sending it as `$(flag)` anyway; " *
          "$(kind) will reject it unless this site defines it."
    return nothing
end

# The settings that become something other than a job-wide `-l key=value`.
const _PBS_NAMED = (:cpus, :mem, :mem_per_cpu, :walltime, :partition, :account, :qos, :exclusive,
                    :nodes, :select)

"""
    pbs_size(v) -> String

A memory size as PBS writes it. SLURM's `16G` is not a size PBS accepts: its units are two letters
(`kb`, `mb`, `gb`, `tb`), and a bare number is bytes. Anything already in that form, or in a syntax
this does not recognise, is passed through — a site's own spelling is not ours to correct.
"""
function pbs_size(v)
    s = strip(string(v))
    m = match(r"^(\d+)\s*([kmgtKMGT]?)[bB]?$", s)
    m === nothing && return String(s)
    return string(m.captures[1], lowercase(m.captures[2]), "b")
end

const _PBS_ALWAYS = (cpus = 1, mem = "1gb", walltime = "00:30:00")

"""
    pbs_select(resources; defaults = true) -> String

The chunk statement: how many nodes, and what each must have. `select=` in the resources wins
outright — a PBS user thinks in chunk statements, and one escape hatch answers every site resource
Slate has no name for, which is why the unmappable settings above point at it.

`defaults = false` asks for only what was named. A batch job states its limits (a job at the mercy
of a site's defaults is the one whose limits kill it); an interactive allocation does not, so that
an unset memory is the queue's own default rather than a number Slate invented.
"""
function pbs_select(r; defaults::Bool = true)
    explicit = strip(string(get(r, :select, "")))
    isempty(explicit) || return String(explicit)
    ncpus = get(r, :cpus, defaults ? _PBS_ALWAYS.cpus : nothing)
    chunk = String[]
    ncpus === nothing || push!(chunk, "ncpus=$(ncpus)")
    mem = _pbs_chunk_mem(r, ncpus, defaults)
    mem === nothing || push!(chunk, "mem=$(mem)")
    for k in sort!(collect(keys(r)))
        (k === :cpus || k === :mem || !haskey(_PBS_CHUNK, k)) && continue
        v = getfield(r, k)
        (v === nothing || isempty(string(v))) && continue
        push!(chunk, string(_PBS_CHUNK[k], "=", k === :nodelist ? _pbs_host(v) : v))
    end
    n = get(r, :nodes, 1)
    return isempty(chunk) ? string(n) : string(n, ":", join(chunk, ":"))
end

# How much memory one chunk gets. `mem_per_cpu` is SLURM's spelling and PBS has no per-CPU memory,
# but a chunk holds exactly `ncpus` cpus — so the multiplication is arithmetic, not a guess, and it
# is right for a multi-chunk job too. Naming BOTH is ambiguous and SLURM rejects it as well.
function _pbs_chunk_mem(r, ncpus, defaults::Bool)
    per = strip(string(get(r, :mem_per_cpu, "")))
    flat = strip(string(get(r, :mem, "")))
    isempty(per) && return isempty(flat) ? (defaults ? _PBS_ALWAYS.mem : nothing) : pbs_size(flat)
    isempty(flat) ||
        error("`mem` and `mem_per_cpu` are both set; PBS asks for memory per chunk, so it can " *
              "honour one of them. Say `mem=` for the whole chunk, or `mem_per_cpu=` alone.")
    ncpus === nothing &&
        error("`mem_per_cpu` needs a cpu count to multiply out on PBS — set `cpus=` too.")
    m = match(r"^(\d+)([kmgt])b$", pbs_size(per))
    m === nothing &&
        error("`mem_per_cpu=$per` is not a size that can be multiplied out — say `mem=` instead.")
    return string(parse(Int, m.captures[1]) * Int(ncpus), m.captures[2], "b")
end

# `nodelist` maps only when it names ONE node: a PBS chunk is placed on a single one, so several
# would need one chunk each and there is no honest way to guess how the work should be split.
function _pbs_host(v)
    s = strip(string(v))
    (occursin(',', s) || occursin('[', s)) &&
        error("`nodelist=$s` names more than one node; a PBS chunk sits on one. Write the " *
              "placement out with `select=` (`1:ncpus=4:vnode=c1+1:ncpus=4:vnode=c2`).")
    return s
end

# `-l place=`, PBS's answer to `--exclusive`. Its vocabulary is its own (`excl`, `exclhost`,
# `shared`), so anything but a yes/no is forwarded for PBS to accept or reject.
function _pbs_place(v)
    s = strip(String(v))
    (isempty(s) || lowercase(s) in ("no", "false", "0")) && return nothing
    return lowercase(s) in ("yes", "true", "1") ? "excl" : s
end

"""
    pbs_flag(k) -> String

How a catalogued setting is spelled for PBS, for the cell editor's benefit. Empty when PBS has no
way to say it — which the editor shows rather than pretending the setting will be honoured.
"""
pbs_flag(k::Symbol) =
    haskey(_PBS_HINT, k)     ? "" :
    haskey(_PBS_CHUNK, k)    ? "select=…:" * _PBS_CHUNK[k] :
    k === :walltime          ? "-l walltime" :
    k === :partition         ? "-q" :
    k === :account           ? "-A" :
    k === :nodes             ? "-l select=N:…" :
    k === :exclusive         ? "-l place" :
    # No per-CPU memory on PBS: it becomes the chunk's `mem`, multiplied by its cpu count.
    k === :mem_per_cpu       ? "select=…:mem (×ncpus)" :
    "-l " * String(k)

# `$PBS_ARRAY_INDEX` picks this element's chunk out of the index file, the same trick the sbatch
# script plays with `$SLURM_ARRAY_TASK_ID`.
function _pbs_script(l::PbsLauncher, spec::JobSpec, indexfile::AbstractString)
    r = spec.resources
    for k in sort!(collect(keys(r)))
        haskey(_PBS_HINT, k) && _hint_once(:PBS, k, _PBS_HINT[k], "-l $(k)=$(get(r, k, ""))")
    end
    lines = ["#!/bin/bash",
             "#PBS -N $(spec.name)",
             # One file, not two: PBS spools stdout and stderr separately otherwise.
             "#PBS -j oe"]
    # Waiting on an ARRAY is a different keyword here than waiting on a job (`afterokarray`, and the
    # id carries a `[]`), and a one-element submission is not an array — PBS rejects the degenerate
    # range, so the probe is normally a plain job on this side. SLURM spells both the same way.
    isempty(spec.after) || push!(lines,
        spec.after_n > 1 ? "#PBS -W depend=afterokarray:$(spec.after)[]" :
                           "#PBS -W depend=afterok:$(spec.after)")
    # Naming the output is three-way, and only one of them is right. Measured on OpenPBS 23.06:
    #
    #   -o <dir>/                          PBS names the file after the JOB ID, which is the one
    #                                      thing the fabric never keeps — `logs` is asked for a
    #                                      NAME, so it would find nothing, ever.
    #   -o <dir>/<name>.out                every element of the array writes to that ONE file.
    #                                      Silently, which makes it the worst of the three.
    #   -o <dir>/<name>.^array_index^.out  one file per element, where we asked for it.
    #
    # `^array_index^` is PBS Pro / OpenPBS (Altair's token for array output paths), not TORQUE. A
    # TORQUE site would have to fall back on the default naming — no `-o` at all gives
    # `$HOME/<name>.o<seq>.<index>`, which is findable by name but ignores `logdir`.
    #
    # A one-element array is not an array (PBS rejects the degenerate range), so the index is read
    # with a default and its log is named as though it were element 1 — one glob finds either.
    if length(spec.chunks) > 1
        push!(lines, "#PBS -J 1-$(length(spec.chunks))",
                     "#PBS -o $(spec.logdir)/$(spec.name).^array_index^.out")
    else
        push!(lines, "#PBS -o $(spec.logdir)/$(spec.name).1.out")
    end
    push!(lines, "#PBS -l select=$(pbs_select(r))")
    push!(lines, "#PBS -l walltime=$(get(r, :walltime, _PBS_ALWAYS.walltime))")
    q = strip(string(get(r, :partition, "")))
    isempty(q) || push!(lines, "#PBS -q $(q)")
    acct = strip(string(get(r, :account, l.account)))
    isempty(acct) || push!(lines, "#PBS -A $(acct)")
    # Job-wide resources: QoS if the site has one, exclusivity, and then everything the spec carries
    # that is not a chunk resource and not named above. Sorted, so two identical sweeps produce
    # identical scripts and the content-derived name keeps matching what was submitted.
    wide = Pair{String,String}[]
    qos = strip(string(get(r, :qos, l.qos)))
    isempty(qos) || push!(wide, "qos" => qos)
    pl = _pbs_place(get(r, :exclusive, ""))
    pl === nothing || push!(wide, "place" => pl)
    for k in sort!(collect(keys(r)))
        (k in _PBS_NAMED || haskey(_PBS_CHUNK, k)) && continue
        v = getfield(r, k)
        (v === nothing || isempty(string(v))) && continue
        # PBS resource names carry underscores (`min_walltime`, `scratch_local`), so unlike sbatch's
        # long options they pass through exactly as written.
        push!(wide, String(k) => string(v))
    end
    for (k, v) in wide; push!(lines, "#PBS -l $(k)=$(v)"); end
    # Site directives, verbatim and LAST, for the same reason as the sbatch script.
    append!(lines, directive_lines(spec.directives; prefix = "#PBS",
                                   example = "-l scratch_local=10gb"))
    append!(lines, ["set -euo pipefail",
                    "CHUNK=\$(sed -n \"\${PBS_ARRAY_INDEX:-1}p\" $(indexfile))",
                    "test -n \"\$CHUNK\"",
                    task_command(spec, "\$CHUNK")])
    return join(lines, "\n") * "\n"
end

function submit!(l::PbsLauncher, spec::JobSpec)
    isempty(spec.chunks) && return ""
    indexfile = joinpath(spec.root, "jobs", spec.name * ".index")
    script = _pbs_script(l, spec, indexfile)
    # The `qselect` guard is what `--dependency=singleton` does on SLURM: the hub can restart, or two
    # notebooks can reconcile the same sweep, and the name is content-derived either way. Without it
    # the second reconcile queues the work twice and both copies write the same shards.
    payload = """
    set -e
    mkdir -p $(joinpath(spec.root, "jobs")) $(spec.logdir)
    cat > $(indexfile) <<'SLATE_INDEX_EOF'
    $(join(spec.chunks, "\n"))
    SLATE_INDEX_EOF
    cat > $(indexfile).pbs <<'SLATE_PBS_EOF'
    $(script)SLATE_PBS_EOF
    if [ -n "\$(qselect -N $(spec.name) -u \"\$USER\" 2>/dev/null)" ]; then
      echo SLATE_ALREADY
      exit 0
    fi
    qsub $(indexfile).pbs
    """
    ok, out = (_ssh(l, payload))
    ok || error("qsub failed on $(l.host): $(strip(out))")
    id = strip(split(strip(out), '\n')[end])
    return id == "SLATE_ALREADY" ? "" : String(id)
end

# One `qstat -f` for the user's jobs, parsed by name. PBS has no `--name` filter, and asking per name
# would be one command per sweep unit — which is exactly the cost `poll` is documented not to have.
# An array job appears ONCE, under its own name, which is the entry we want; its elements are only
# visible with `-t` and the store answers for them anyway.
#
# `qselect` FIRST, and not `qstat -f -u "$USER"`: `-u` silently overrides `-f` and prints the short
# table instead, which has no Job_Name column — so every name parses as absent and a running sweep
# reads as one that never started. Verified against OpenPBS 23.06. `set -f` because an array job's
# id contains `[]`, which the shell would otherwise try to glob.
#
# Attributes are accumulated per JOB BLOCK rather than read in order: `qstat -f` emits them in
# whatever order the server holds them, and `resources_used` lands before `job_state`.
const _PBS_POLL = raw"""
set -f
ids=$(qselect -u "$USER" 2>/dev/null)
[ -n "$ids" ] || exit 0
qstat -f $ids 2>/dev/null | awk '
  function out() { if (n != "") print n " " s; n = ""; s = "" }
  /^Job Id:/                    { out() }
  /^[ \t]*Job_Name = /          { n = substr($0, index($0, "= ") + 2); sub(/[ \t\r]+$/, "", n) }
  /^[ \t]*job_state = /         { s = substr($0, index($0, "= ") + 2); sub(/[ \t\r]+$/, "", s) }
  END                           { out() }'
"""

# PBS's single-letter states. `B` is an array job with elements running, `E` a job on its way out —
# both are still live, and only a job the scheduler no longer holds leaves a name `:unknown`.
_pbs_state(s::AbstractString) =
    s in ("R", "B", "E") ? :running :
    s in ("Q", "H", "W", "T", "S", "M") ? :pending : :unknown

function poll(l::PbsLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return Dict{String,Symbol}()
    out = Dict{String,Symbol}(n => :unknown for n in ns)
    ok, txt = (_ssh(l, _PBS_POLL))
    ok || return out
    for line in split(txt, '\n'; keepempty = false)
        parts = split(strip(line))
        length(parts) >= 2 || continue
        name = String(parts[1])
        haskey(out, name) || continue
        st = _pbs_state(uppercase(String(parts[2])))
        st === :unknown && continue
        out[name] === :running || (out[name] = st)
    end
    return out
end

# `qdel` takes ids, so each name is resolved first — and that is also what makes the count honest
# here without a second poll: `qselect` lists only live jobs, so a name it answers for was live, and
# `qdel`'s exit status says whether it was acted on.
#
# Deliberately NOT the SLURM shape of re-polling to see what left. A cancelled PBS job goes to `E`
# (exiting) before it disappears, so a poll taken straight after a successful `qdel` still reports it
# live and every cancel would report zero. SLURM re-polls because `scancel` exits 0 whether or not a
# name matched anything; PBS hands us ids instead, which is a better answer to the same question.
function cancel!(l::PbsLauncher, root::AbstractString, names)
    ns = String.(collect(names))
    isempty(ns) && return 0
    ok, out = (_ssh(l, join(("ids=\$(qselect -N $(n) -u \"\$USER\" 2>/dev/null); " *
                             "[ -n \"\$ids\" ] && qdel \$ids >/dev/null 2>&1 && echo CANCELLED"
                             for n in ns), "\n")))
    return count(==("CANCELLED"), strip.(split(out, '\n'; keepempty = false)))
end

# Only after the job ENDS: PBS spools output on the execution node and copies it back at exit, where
# SLURM writes it live. Per-unit progress comes from the status directory either way, so this is for
# reading what a finished job said — which is when it is asked for.
function logs(l::PbsLauncher, root::AbstractString, name::AbstractString; lines::Int = 200)
    ok, txt = (_ssh(l,
        "tail -n $(lines) $(joinpath(root, "logs"))/$(name).*.out 2>/dev/null"))
    return ok ? txt : ""
end

log_files(l::PbsLauncher, root::AbstractString, names::AbstractVector) =
    _remote_log_files(sc -> _ssh(l, sc), root, names)
log_tail(l::PbsLauncher, path::AbstractString; lines::Int = 500) =
    _remote_log_tail(sc -> _ssh(l, sc), path, lines)
log_stat(l::PbsLauncher, path::AbstractString) = _remote_log_stat(sc -> _ssh(l, sc), path)
log_slice(l::PbsLauncher, path::AbstractString; offset::Integer = -(1 << 16),
          nbytes::Integer = 1 << 16) =
    _remote_log_slice(sc -> _ssh(l, sc), path, offset, nbytes)
log_search(l::PbsLauncher, path::AbstractString, pattern::AbstractString; ignorecase::Bool = false,
           regex::Bool = false, limit::Integer = 1000) =
    _remote_log_search(sc -> _ssh(l, sc), path, pattern, ignorecase, regex, limit)

"""
    explain_failure(l::PbsLauncher, name) -> String

Why a submission's elements ended, from job history — PBS's answer to `sacct`, and with the same
caveat: `qstat -x` needs the server's `job_history_enable` set, so it may return nothing at all.
Only ever consulted to explain a failure; whether a shard is done is a question for the store.
"""
function explain_failure(l::PbsLauncher, name::AbstractString)
    ok, txt = (_ssh(l,
        "for j in \$(qselect -x -N $(name) -u \"\$USER\" 2>/dev/null); do " *
        "qstat -x -f \"\$j\" 2>/dev/null | " *
        "grep -E 'Job Id|job_state|Exit_status|resources_used'; done"))
    return ok ? txt : ""
end

end # module BatchLauncher
