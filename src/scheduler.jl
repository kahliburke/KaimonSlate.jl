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

What kind of front door this host is. `kind` is `:slurm`, `:pbs`, or `:none` — and `:none` is a
perfectly good answer meaning "an ordinary machine", not a failure.
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
    s.kind === :none && return print(io, "SchedulerInfo(not a cluster login node)")
    print(io, "SchedulerInfo(", s.kind, isempty(s.version) ? "" : " " * s.version,
          ", ", length(s.partitions), " partition", length(s.partitions) == 1 ? "" : "s")
    g = gpu_partitions(s)
    isempty(g) || print(io, ", ", length(g), " with GPUs")
    print(io, ")")
end

# One round trip: which client tools exist, the version, and the queue list. Written as a single
# script because a login node's round trip is the expensive part, not the commands.
const _DETECT_SCRIPT = raw"""
if command -v sinfo >/dev/null 2>&1 && command -v sbatch >/dev/null 2>&1; then
  echo "KIND slurm"
  echo "VERSION $(sinfo --version 2>/dev/null | head -1)"
  sinfo -h -o 'PART %R|%G|%l|%a' 2>/dev/null | sort -u
elif command -v qstat >/dev/null 2>&1 && command -v qsub >/dev/null 2>&1; then
  echo "KIND pbs"
  echo "VERSION $(qstat --version 2>&1 | head -1)"
  # PBS names them queues; the shape Slate needs is the same, so it reports them the same way.
  qstat -Qf 2>/dev/null | awk '
    /^Queue: /        { q=$2; gpu=""; mt=""; en="True" }
    /resources_max.walltime/ { mt=$3 }
    /resources_max.ngpus/    { gpu="gpu:" $3 }
    /enabled = /      { en=$3 }
    /^$/              { if (q != "") { print "PART " q "|" gpu "|" mt "|" (en=="True" ? "up" : "down"); q="" } }
    END               { if (q != "") print "PART " q "|" gpu "|" mt "|" (en=="True" ? "up" : "down") }'
else
  echo "KIND none"
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
    ok || return SchedulerInfo()
    kind = :none; version = ""; parts = Partition[]
    for line in split(out, '\n')
        line = strip(line)
        if startswith(line, "KIND ")
            k = strip(line[6:end])
            kind = k == "slurm" ? :slurm : k == "pbs" ? :pbs : :none
        elseif startswith(line, "VERSION ")
            version = strip(line[9:end])
        elseif startswith(line, "PART ")
            f = split(strip(line[6:end]), '|')
            length(f) >= 1 && !isempty(strip(f[1])) || continue
            g = length(f) >= 2 ? String(strip(f[2])) : ""
            lowercase(g) in ("(null)", "none", "n/a") && (g = "")
            push!(parts, Partition(String(strip(f[1])), g,
                                   length(f) >= 3 ? String(strip(f[3])) : "",
                                   length(f) >= 4 ? lowercase(strip(f[4])) != "down" : true))
        end
    end
    return SchedulerInfo(kind, version, parts)
end

end # module SchedulerDetect
