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
