# End-to-end proof against a real scheduler: build a sweep, submit it as a SLURM array job, let the
# compute nodes run it, and read the results back out of the shared store.
#
# This runs ON the login node, which is both the simplest way to prove the SLURM path and a real
# deployment shape in its own right (Slate running on a login node needs no ssh hop). Driving it
# from a laptop additionally needs the remote-store adapter, which does not exist yet: the hub
# cannot see the cluster filesystem, so `plan` has nothing to read.
#
# Invoked by integration.sh, which ships the sources across first.

const SRC = get(ENV, "SLATE_SRC", "/scratch/slate/src")
const ROOT = get(ENV, "SLATE_CAS", "/scratch/slate/cas")

include(joinpath(SRC, "batchsweep.jl"))

const BL = BatchLauncher
const BS = BatchSweep

nshards = parse(Int, get(ENV, "SLATE_SHARDS", "24"))
per     = parse(Int, get(ENV, "SLATE_PER_CHUNK", "6"))
part    = get(ENV, "SLATE_PARTITION", "compute")

mkpath(ROOT)

# A sweep that is obviously parallel and obviously verifiable: shard i returns i^2, and one shard
# is rigged to throw so the failure path is exercised for real rather than only in unit tests.
fn_src = """
p -> begin
    p == 7 && error("rigged failure on shard 7")
    sleep(0.5)
    p * p
end
"""

sweep = "itest" * string(round(Int, time()))
chunks = String[]
for (ci, lo) in enumerate(1:per:nshards)
    hi = min(lo + per - 1, nshards)
    params = collect(lo:hi)
    chunk = "$(sweep)_c$(ci)"
    SlateTask.write_chunk!(ROOT, chunk; fn_src, params,
                           keys = ["$(sweep)_s$(p)" for p in params])
    push!(chunks, chunk)
end
BS.write_sweep!(ROOT, sweep, chunks)
println("sweep $sweep: $nshards shards in $(length(chunks)) chunks")

launcher = BL.SlurmLauncher()          # no host: sbatch is on this machine
spec = (name, cs) -> BL.JobSpec(name, cs;
    root = ROOT,
    project = get(ENV, "SLATE_PROJECT", tempdir()),
    payload = joinpath(SRC, "slatetask.jl"),
    julia = get(ENV, "SLATE_JULIA", "julia"),
    resources = (; cpus = 1, mem = "512M", walltime = "00:10:00", partition = part))

p0 = BS.plan(ROOT, sweep; launcher)
@assert length(p0.to_submit) == length(chunks) "fresh sweep should have every chunk to submit"
println("before submit: $p0")

BS.reconcile!(ROOT, sweep, launcher, spec)
println("submitted; polling...")

# In a function, not at top level: a `while` at top level is soft scope, where assigning to a
# variable that shares a name with a Base binding is a warning and then an error.
function poll_until_done(root, sweep, launcher; timeout = 300)
    deadline = time() + timeout
    prev = ""
    while time() < deadline
        p = BS.plan(root, sweep; launcher)
        line = "  $(p.shards_done)/$(p.shards_total) shards " *
               "(ok $(p.shards_ok), failed $(p.shards_failed)) " *
               "chunks: " * join(sort(["$k=$v" for (k, v) in p.chunk_state]), " ")
        if line != prev
            println(line); prev = line
        end
        BS.is_complete(p) && return true
        sleep(3)
    end
    return false
end

poll_until_done(ROOT, sweep, launcher)

final = BS.plan(ROOT, sweep; launcher)
println("final: $final")

rs = BS.results(ROOT, sweep)
ok = [r for r in rs if r.status == "ok"]
vals = Dict(r.key => r.value for r in ok)
expected_ok = [i for i in 1:nshards if i != 7]

errs = String[]
BS.is_complete(final) || push!(errs, "sweep did not complete: $final")
final.shards_failed == 1 || push!(errs, "expected exactly 1 failed shard, got $(final.shards_failed)")
for i in expected_ok
    got = get(vals, "$(sweep)_s$(i)", nothing)
    got == i * i || push!(errs, "shard $i: expected $(i * i), got $(repr(got))")
end
fs = BS.failures(ROOT, sweep)
(length(fs) == 1 && occursin("rigged failure", String(fs[1].error))) ||
    push!(errs, "failure not recorded as expected: $fs")

# Provenance: the whole point of running this on a cluster is that shards did NOT all run here.
hosts = unique([r.ran_on for r in ok])
println("ran on: ", join(hosts, ", "))
any(h -> occursin("c1", h) || occursin("c2", h), hosts) ||
    push!(errs, "no shard reported running on a compute node: $hosts")

# Re-reconciling a finished sweep must submit nothing. This is the property that makes reopening a
# notebook safe.
before = BS.known_submissions(ROOT)
BS.reconcile!(ROOT, sweep, launcher, spec)
BS.known_submissions(ROOT) == before || push!(errs, "a completed sweep submitted more work")

println()
if isempty(errs)
    println("== INTEGRATION PASSED ==")
    exit(0)
else
    println("== INTEGRATION FAILED ==")
    for e in errs; println("  - ", e); end
    exit(1)
end
