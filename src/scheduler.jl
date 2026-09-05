# ── Is this host a cluster login node? ───────────────────────────────────────────────────────
#
# A remote host is one of two quite different things, and Slate has to know which before it can
# offer sensible configuration:
#
#   a MACHINE     — ssh in, start a worker, done. The host you configure is the host you run on.
#   a LOGIN NODE  — ssh in and you are on a gateway. Running work here is antisocial and often
#                   forbidden; you ask the scheduler for a node, and it tells you which one you got.
#
# The second needs everything the first does NOT: a walltime, a partition or queue, how many CPUs,
# whether you want GPUs and how many, an account to bill. And the host the worker ends up on is an
# OUTPUT of that request, not something anyone can type in advance.
#
# So detection is not a nicety — it decides which questions to ask. Asking a plain workstation for a
# walltime is noise; failing to ask a cluster for one means the allocation is whatever the site's
# default happens to be, which is how people end up holding a GPU overnight by accident.
#
# Detected by asking the host what commands it has, which is cheap, and reading the partition list
# in the same round trip, which is what turns "pick a partition" into a menu rather than a guess.

module SchedulerDetect

"""
    Partition

One queue a job can be submitted to, as the scheduler describes it. `gpus` is what a node in it
offers (empty when none) — the thing that decides whether "GPU node" is even an option here.
"""
struct Partition
    name::String
    gpus::String        # SLURM's GRES string ("gpu:a100:4"), PBS's resource, or "" for none
    maxtime::String     # "infinite", "10:00", "3-00:00:00" — the ceiling a walltime must respect
    up::Bool
end

has_gpu(p::Partition) = !isempty(p.gpus) && lowercase(p.gpus) ∉ ("(null)", "none", "n/a")

Base.show(io::IO, p::Partition) =
    print(io, p.name, has_gpu(p) ? " [" * p.gpus * "]" : "",
          isempty(p.maxtime) ? "" : " ≤" * p.maxtime, p.up ? "" : " (down)")

"""
    SchedulerInfo

ONE scheduler this host can talk to: which, what version, and the queues it offers.
"""
struct SchedulerInfo
    kind::Symbol
    version::String
    partitions::Vector{Partition}
end

SchedulerInfo() = SchedulerInfo(:none, "", Partition[])

is_cluster(s::SchedulerInfo) = s.kind !== :none
gpu_partitions(s::SchedulerInfo) = [p for p in s.partitions if has_gpu(p)]

function Base.show(io::IO, s::SchedulerInfo)
    s.kind === :none && return print(io, "SchedulerInfo(none)")
    print(io, "SchedulerInfo(", s.kind, isempty(s.version) ? "" : " " * s.version,
          ", ", length(s.partitions), " partition", length(s.partitions) == 1 ? "" : "s")
    g = gpu_partitions(s)
    isempty(g) || print(io, ", ", length(g), " with GPUs")
    print(io, ")")
end

"""
    HostSchedulers

EVERY scheduler whose client tools are on a host — because a host can have more than one, and
detection is not entitled to decide which you meant. A site mid-migration has both; so does a SLURM
cluster carrying PBS compatibility wrappers, where finding `qsub` says nothing about what actually
runs the jobs.

So this reports, and configuration chooses. `suggested` is the default to offer, not a verdict.
"""
struct HostSchedulers
    found::Vector{SchedulerInfo}
end

HostSchedulers() = HostSchedulers(SchedulerInfo[])

is_cluster(h::HostSchedulers) = !isempty(h.found)
kinds(h::HostSchedulers) = Symbol[s.kind for s in h.found]

"The scheduler to offer by default: the first found, or `:none`."
suggested(h::HostSchedulers) = isempty(h.found) ? :none : first(h.found).kind

"The detected record for `kind`, or `nothing` when this host has no such scheduler."
function scheduler(h::HostSchedulers, kind::Symbol)
    kind === :none && return nothing
    i = findfirst(s -> s.kind === kind, h.found)
    return i === nothing ? nothing : h.found[i]
end

"""
    resolve(h, setting) -> Symbol

Turn a configured choice into the scheduler to actually use. `setting` is `:auto` (take the
suggestion), `:none` (do not use one, even here — a perfectly reasonable choice on a cluster whose
login node you are content to run a small worker on), or an explicit `:slurm`/`:pbs`.

An explicit choice is HONOURED even when detection did not find it: the tools may be behind a
`module load`, and refusing to configure what the user knows is there would be worse than trying.
"""
function resolve(h::HostSchedulers, setting::Symbol)
    setting === :none && return :none
    setting === :auto && return suggested(h)
    return setting
end

function Base.show(io::IO, h::HostSchedulers)
    isempty(h.found) && return print(io, "HostSchedulers(none — an ordinary machine)")
    print(io, "HostSchedulers(", join((string(s.kind) for s in h.found), " + "),
          length(h.found) > 1 ? "; suggested " * string(suggested(h)) : "", ")")
end

# One round trip: which client tools exist, the version, and the queue list. Written as a single
# script because a login node's round trip is the expensive part, not the commands.
# Both probes run — NOT `elseif`. A host can have both sets of tools, and stopping at the first
# would silently pick one on the user's behalf. Each line is tagged with the scheduler it came from
# so two answers cannot be confused for one.
const _DETECT_SCRIPT = raw"""
if command -v sinfo >/dev/null 2>&1 && command -v sbatch >/dev/null 2>&1; then
  echo "KIND slurm"
  echo "VERSION slurm $(sinfo --version 2>/dev/null | head -1)"
  sinfo -h -o 'PART slurm %R|%G|%l|%a' 2>/dev/null | sort -u
fi
if command -v qstat >/dev/null 2>&1 && command -v qsub >/dev/null 2>&1; then
  echo "KIND pbs"
  echo "VERSION pbs $(qstat --version 2>&1 | head -1)"
  # PBS names them queues; the shape Slate needs is the same, so it reports them the same way.
  qstat -Qf 2>/dev/null | awk '
    /^Queue: /        { q=$2; gpu=""; mt=""; en="True" }
    /resources_max.walltime/ { mt=$3 }
    /resources_max.ngpus/    { gpu="gpu:" $3 }
    /enabled = /      { en=$3 }
    /^$/              { if (q != "") { print "PART pbs " q "|" gpu "|" mt "|" (en=="True" ? "up" : "down"); q="" } }
    END               { if (q != "") print "PART pbs " q "|" gpu "|" mt "|" (en=="True" ? "up" : "down") }'
fi
"""

# ── What the cluster is doing right now ──────────────────────────────────────────────────────
#
# `detect` reports what a host OFFERS, which does not change; this reports what is FREE, which is
# the only thing that explains a wait. A cell queued for a node says nothing about whether the
# answer is thirty seconds or tomorrow — "0 of 8 cpus free, 12 jobs queued" does.
#
# Deliberately a separate round trip from detection: this one is asked while somebody is looking at
# a queued cell, and detection is asked once when a form opens.

"Free capacity in one queue, as the scheduler reports it now."
struct QueueLoad
    name::String
    nodes_free::Int      # nodes with nothing on them; 0 when the scheduler did not say
    nodes_total::Int     # 0 means "no node count available", not "no nodes" — see `show`
    cpus_free::Int
    cpus_total::Int
    queued::Int          # jobs waiting, across the whole scheduler — a queue of one is not a wait
    down::Int            # nodes the scheduler will not use (down/offline/drained)
    eta::String          # when it expects to start OUR job, verbatim from the scheduler; "" if silent
end

Base.show(io::IO, q::QueueLoad) =
    print(io, q.name, ": ", q.cpus_free, "/", q.cpus_total, " cpus free",
          q.nodes_total > 0 ? ", $(q.nodes_free)/$(q.nodes_total) nodes" : "",
          q.down > 0 ? ", $(q.down) down" : "",
          q.queued > 0 ? ", $(q.queued) queued" : "",
          isempty(q.eta) ? "" : ", starts ~$(q.eta)")

# SLURM counts cpus per partition with `%C` = allocated/idle/other/total. PBS has no per-queue view
# of the same thing, so its nodes are counted once and reported against every queue — a small lie,
# and the honest alternative (a per-queue node map) costs a round trip per queue to say the same
# thing on a cluster where the queues share nodes, which is the normal shape.
# Also asked for, because they change the answer rather than decorate it:
#   ETA   — when the scheduler expects to start OUR job. Both backfill schedulers publish an
#           estimate, and it is the only thing here that answers "how long" directly.
#   DOWN  — nodes the scheduler will not schedule onto (down/offline/drained). A queue that looks
#           merely busy reads very differently when half the cluster is out.
# `JOBNAME` is substituted with the allocation's name; with none, those lines are simply absent.
const _LOAD_SCRIPT = raw"""
if command -v sinfo >/dev/null 2>&1; then
  sinfo -h -o 'LOAD slurm %R|%C|%D|%A' 2>/dev/null | sort -u
  echo "PEND slurm $(squeue -h -t PENDING -o '%i' 2>/dev/null | wc -l | tr -d ' ')"
  echo "DOWN slurm $(sinfo -h -o '%D %T' 2>/dev/null | awk '$2 ~ /down|drain|fail|maint|unk/ { d += $1 } END { print d+0 }')"
  [ -n "JOBNAME" ] && echo "ETA slurm $(squeue -h -n JOBNAME -u "$USER" --start -o '%S' 2>/dev/null | head -1)"
fi
if command -v pbsnodes >/dev/null 2>&1; then
  pbsnodes -a 2>/dev/null | awk '
    /^[^ ]/            { n++ }
    /state = free/     { free++ }
    /state = /         { if ($0 ~ /down|offline/) dn++ }
    /resources_available.ncpus/ { tot += $3 }
    /resources_assigned.ncpus/  { used += $3 }
    END { print "LOADPBS " (free+0) "|" (n+0) "|" (tot-used) "|" (tot+0); print "DOWN pbs " (dn+0) }'
  echo "PEND pbs $(qselect -s Q 2>/dev/null | wc -l | tr -d ' ')"
  if [ -n "JOBNAME" ]; then
    ids=$(qselect -N JOBNAME -u "$USER" 2>/dev/null)
    [ -n "$ids" ] && qstat -f $ids 2>/dev/null |
      awk '/estimated.start_time/ { sub(/^[^=]*= /, ""); print "ETA pbs " $0; exit }'
  fi
fi
"""

"""
    load(runner, kind, queues; job = "") -> Vector{QueueLoad}

What is free right now, per queue. One round trip. Empty when the host cannot be reached or the
scheduler says nothing — a wait with no explanation is better than an invented one.

`job` is the allocation's name: given one, the scheduler is also asked when it expects to start it.
"""
function load(runner, kind::Symbol, queues::Vector{String} = String[]; job::AbstractString = "")
    # The name is ours (`slate-<region>`), never user text, but it is still pasted into a script —
    # so anything that is not a plain job-name character does not go in.
    jn = replace(String(job), r"[^A-Za-z0-9_.-]" => "")
    ok, out = try; runner(replace(_LOAD_SCRIPT, "JOBNAME" => jn)); catch; (false, ""); end
    ok || return QueueLoad[]
    pend = 0; down = 0; eta = ""
    rows = QueueLoad[]
    pbs = (free = -1, nodes = 0, cfree = 0, ctot = 0)
    for line in split(out, '\n')
        line = strip(line)
        if startswith(line, "PEND ")
            f = split(line); length(f) >= 3 && (pend = max(pend, something(tryparse(Int, f[3]), 0)))
        elseif startswith(line, "DOWN ")
            f = split(line); length(f) >= 3 && (down = max(down, something(tryparse(Int, f[3]), 0)))
        elseif startswith(line, "ETA ")
            v = strip(line[5:end])
            i = findfirst(' ', v); v = i === nothing ? "" : strip(v[i+1:end])
            # SLURM says N/A when backfill has no estimate; PBS just omits the attribute.
            (isempty(v) || v in ("N/A", "Unknown", "(null)")) || (eta = String(v))
        elseif startswith(line, "LOAD slurm ")
            g = split(strip(line[12:end]), '|')
            length(g) >= 4 || continue
            # `%C` is "allocated/idle/other/total"; `%A` is "allocated/idle" NODES.
            c = split(g[2], '/'); a = split(g[4], '/')
            length(c) >= 4 || continue
            push!(rows, QueueLoad(String(strip(g[1])),
                                  length(a) >= 2 ? something(tryparse(Int, a[2]), 0) : 0,
                                  something(tryparse(Int, g[3]), 0),
                                  something(tryparse(Int, c[2]), 0),
                                  something(tryparse(Int, c[4]), 0), 0, 0, ""))
        elseif startswith(line, "LOADPBS ")
            g = split(strip(line[9:end]), '|')
            length(g) >= 4 && (pbs = (free = something(tryparse(Int, g[1]), 0),
                                      nodes = something(tryparse(Int, g[2]), 0),
                                      cfree = something(tryparse(Int, g[3]), 0),
                                      ctot = something(tryparse(Int, g[4]), 0)))
        end
    end
    if kind === :pbs && pbs.nodes > 0
        qs = isempty(queues) ? ["(cluster)"] : queues
        rows = QueueLoad[QueueLoad(q, pbs.free, pbs.nodes, pbs.cfree, pbs.ctot, 0, 0, "") for q in qs]
    end
    # The scheduler-wide figures are collected once and stamped onto every row: they describe the
    # scheduler, not a queue, and a reader looking at one queue still needs them.
    return QueueLoad[QueueLoad(r.name, r.nodes_free, r.nodes_total, r.cpus_free, r.cpus_total,
                               pend, down, eta) for r in rows]
end

"""
    detect(runner) -> SchedulerInfo

Ask a host whether it fronts a scheduler, and if so which and with what queues. One round trip.

`runner(script) -> (ok, output)` is the caller's transport — the hub reaches a host one way and a
worker another, and neither belongs in here. That also makes this testable by handing it a function
that returns canned scheduler output.
"""
function detect(runner)
    ok, out = try; runner(_DETECT_SCRIPT); catch; (false, ""); end
    ok || return HostSchedulers()
    order = Symbol[]                       # detection order, which decides what is suggested
    version = Dict{Symbol,String}()
    parts = Dict{Symbol,Vector{Partition}}()
    tag(w) = w == "slurm" ? :slurm : w == "pbs" ? :pbs : :none
    for line in split(out, '\n')
        line = strip(line)
        if startswith(line, "KIND ")
            k = tag(String(strip(line[6:end])))
            k === :none || k in order || push!(order, k)
        elseif startswith(line, "VERSION ")
            f = split(strip(line[9:end]), ' '; limit = 2)
            length(f) == 2 && (version[tag(String(f[1]))] = String(strip(f[2])))
        elseif startswith(line, "PART ")
            f = split(strip(line[6:end]), ' '; limit = 2)
            length(f) == 2 || continue
            k = tag(String(f[1])); k === :none && continue
            g = split(strip(f[2]), '|')
            length(g) >= 1 && !isempty(strip(g[1])) || continue
            gres = length(g) >= 2 ? String(strip(g[2])) : ""
            lowercase(gres) in ("(null)", "none", "n/a") && (gres = "")
            push!(get!(Vector{Partition}, parts, k),
                  Partition(String(strip(g[1])), gres,
                            length(g) >= 3 ? String(strip(g[3])) : "",
                            length(g) >= 4 ? lowercase(strip(g[4])) != "down" : true))
        end
    end
    return HostSchedulers([SchedulerInfo(k, get(version, k, ""), get(parts, k, Partition[]))
                           for k in order])
end

end # module SchedulerDetect
