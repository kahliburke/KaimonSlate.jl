# ── Preparing a machine for batch work ───────────────────────────────────────────────────────
# A sweep sends one environment to many nodes at once, so a broken one costs every task in the array.
# Preparing for batch builds the project's task environment on the machine and runs ONE task through
# the scheduler, exactly as the sweep's tasks are submitted, on the node type they ask for but for a
# short time: it precompiles there, loads every package, checks CUDA, and times it. What it finds is the
# machine's record of that environment (`record_env_test!`), the same one a region's prepare writes,
# and a sweep submits only when `env_readiness` says it may.

# A test needs minutes, not the sweep's walltime, so it queues behind less.
const _TEST_WALLTIME = "00:20:00"

# Its progress and reports sit beside the regions', under a key no region folds to.
_batch_key(machine::AbstractString) = "batch_" * _fold_region(machine)

"""
    prepare_batch!(machine; project, resources = NamedTuple()) -> Dict

Prepare `machine` for `project`'s sweeps: the machine's own steps (sign in, Julia, the site, the
depot), then build the project's task environment there and run one test task through the scheduler
with `resources` (the sweep's node type; the walltime is short and the machine's `test_qos` applies).
Blocking; returns the record, and keeps a report like every prepare.
"""
function prepare_batch!(machine::AbstractString; project::AbstractString, resources = NamedTuple())
    entry = cluster_get(machine)
    entry === nothing && error("no machine '$machine'")
    m = machine_from(entry)
    isempty(m.host) && error("machine '$machine' is this one; there is nothing to prepare")
    ref = _reference_env(project)
    isempty(ref[1]) && error("nothing to test: '$project' has no environment")
    key = _batch_key(machine)
    facts = Dict{String,Any}()
    measured = Dict{String,Any}()
    passed = Ref("")   # the kind of node, once the test task has loaded the environment there
    finish = function (ok, state)
        hostf = get(facts, "host", Dict{String,String}())
        isempty(hostf) || _record_site!(m.host, hostf, Dict{String,String}(), m.prologue, state["id"])
        rec = Dict{String,Any}("prepared_at" => time(), "ok" => ok, "steps" => deepcopy(state["steps"]),
                               "report" => state["id"], "project" => ref[1])
        if !isempty(passed[])
            record_env_test!(m.host, ref[1], passed[]; by = "test task", depot = machine_depot(m),
                status = String(get(measured, "env_status", "ok")), load_s = get(measured, "env_load_s", 0.0),
                precompile_s = get(measured, "precompile_s", 0.0), cuda = get(measured, "cuda", nothing),
                report = state["id"])
            rec["tested"] = Sweep.env_key(ref[1], passed[])
        end
        return rec
    end
    return _run_prepare(key, m.host, ref[1]; finish) do step, note
        _site_steps!(step, m.host, m, facts) == "fail" && return
        # Read again now the depot is settled: the target's shell has to carry it.
        spec = Dict{String,String}(String(k) => string(v) for (k, v) in cluster_get_resolved(machine))
        t = Sweep.with_resources(Sweep._with(Sweep.cluster(spec); parent = ref[1]), resources)
        # The environment a region's worker for this project uses, built the same way: a sweep runs in it.
        envdir = Ref("~/" * Sweep.shared_env(ref[1]))
        built = step("Install $(basename(ref[1]))") do
            rt = RemoteTarget(m.host; project = envdir[], origin_env = ref[1], depot = machine_depot(m),
                              setup = machine_setup(m))
            provision_remote!(rt, ref[2]; precompile = false)
            ("ok", "")
        end
        built == "fail" && return
        tested = step("Run a test task on the nodes") do
            _batch_test!(t, envdir[], measured, note; qos = String(get(entry, "test_qos", "")))
        end
        tested in ("ok", "warn") && (passed[] = Sweep.node_type(string(get(t.resources, :partition, "")),
                                                               string(get(t.resources, :constraint, ""))))
    end
end

# One task through the scheduler, as the sweep's would go: same script, same shell, same node type,
# a short walltime. It precompiles where the tasks run, then loads every package and reports.
function _batch_test!(t, envdir::AbstractString, measured, note; qos::AbstractString = "")
    code = "t0 = time(); import Pkg; Pkg.precompile(); println(\"precompile=\", round(time() - t0; digits = 1))\n" *
           _LOAD_CODE
    # A node of the same kind already held by a region on this machine: the test runs there, as a
    # step in that allocation, rather than queueing for another node to do the same thing.
    held = _held_node_like(t)
    if held !== nothing
        note("on $(held.node), held by region $(held.region)")
        ok, out = _run_on(held.node, Sweep._prefix(t) * "julia --startup-file=no --project=" * Sweep.shq_path(envdir) *
                                     " -e " * Sweep.shq(code); timeout = 1800.0)
        ok || return ("fail", "on $(held.node): " * first(strip(out), 400))
        return _test_result!(measured, out, "on $(held.node) (held by $(held.region))")
    end
    shape = merge(t.resources, (; walltime = _TEST_WALLTIME), isempty(qos) ? NamedTuple() : (; qos))
    name = "slate-test-" * Sweep.env_key(t)
    logdir = "$(t.root_remote)/logs"
    spec = BatchLauncher.JobSpec(name, ["test"]; root = t.root_remote, project = envdir, payload = "",
        resources = shape, logdir, prologue = Sweep._as_line(Sweep._prefix(t)), directives = t.directives,
        umask = Sweep.store_umask(t),
        command = "julia --startup-file=no --project=" * Sweep.shq_path(envdir) * " -e " * Sweep.shq(code))
    l = Sweep.launcher_for(t)
    id = BatchLauncher.submit!(l, spec)
    note("submitted as job $id")
    # Polled rather than waited on: the login session carries one command at a time, and a blocking
    # wait would hold it for the whole queue.
    deadline = time() + 6 * 3600
    while true
        time() > deadline && return ("fail", "job $id did not finish within 6 hours; it was left queued")
        sleep(15)
        st = get(BatchLauncher.poll(l, t.root_remote, [name]), name, :unknown)
        st === :unknown && break
        note(st === :pending ? "queued as job $id" : "running as job $id")
    end
    f = t.kind === :pbs ? "$logdir/$name.1.out" : "$logdir/$name.$(id)_1.out"
    ok, out = Sweep.run_there(t.host, "cat " * Sweep.shq_path(f))
    ok || return ("fail", "job $id left no output at $f")
    return _test_result!(measured, out, "job $id")
end

function _test_result!(measured, out::AbstractString, where_::AbstractString)
    facts = _parse_probe(out)
    haskey(facts, "load") ||
        return ("fail", "$where_ did not get as far as loading; its output ends: " *
                        join(last(split(strip(out), '\n'), 12), "\n"))
    measured["precompile_s"] = something(tryparse(Float64, get(facts, "precompile", "")), 0.0)
    status, detail = _load_result!(measured, out)
    return (status, "$where_ · precompiled in $(measured["precompile_s"])s · " * detail)
end

# A node a region on `t`'s machine holds now, of the kind `t` asks for (`Sweep.node_type`).
function _held_node_like(t)
    want = Sweep.node_type(string(get(t.resources, :partition, "")), string(get(t.resources, :constraint, "")))
    for r in regions()
        (r.host == t.host && r.scheduler !== :none && _region_holds_node(r)) || continue
        Sweep.node_type(r.partition, get(r.options, "constraint", "")) == want || continue
        node = region_host(r)
        (isempty(node) || node == r.host) && continue
        return (node = node, region = r.name)
    end
    return nothing
end

# ── The machine alone ─────────────────────────────────────────────────────────────────────────
_machine_key(machine::AbstractString) = "machine_" * _fold_region(machine)

"""
    prepare_machine!(machine) -> Dict

The steps every prepare of `machine` starts with, on their own: sign in, Julia, read the site, settle
the depot. What they find is recorded for the host, and every region and sweep on it uses it. Blocking;
keeps a report like every prepare.
"""
function prepare_machine!(machine::AbstractString)
    entry = cluster_get(machine)
    entry === nothing && error("no machine '$machine'")
    m = machine_from(entry)
    isempty(m.host) && error("machine '$machine' is this one; there is nothing to prepare")
    facts = Dict{String,Any}()
    finish = function (ok, state)
        hostf = get(facts, "host", Dict{String,String}())
        isempty(hostf) || _record_site!(m.host, hostf, Dict{String,String}(), m.prologue, state["id"])
        return Dict{String,Any}("prepared_at" => time(), "ok" => ok, "steps" => deepcopy(state["steps"]),
                                "report" => state["id"])
    end
    return _run_prepare(_machine_key(machine), m.host, ""; finish) do step, note
        _site_steps!(step, m.host, m, facts)
    end
end

"""
    machine_view(machine) -> Dict

A machine for the page: its entry, what preparing found on its host (with the depot in use), the task
environments tested on its nodes (by a region or a test task), and any prepare of it running now.
"""
function machine_view(machine::AbstractString)
    entry = cluster_get(machine)
    entry === nothing && return Dict{String,Any}("ok" => false, "error" => "no machine '$machine'")
    m = machine_from(entry)
    hf = isempty(m.host) ? Dict{String,Any}() : host_facts(m.host)
    delete!(hf, "envs")
    tests = isempty(m.host) ? Dict{String,Any}() : tested_envs(m.host)
    depot = machine_depot(m)
    return Dict{String,Any}("ok" => true, "name" => m.name, "host" => m.host, "depot" => depot,
        "site" => hf, "tests" => [merge(Dict{String,Any}("key" => k), v, Dict{String,Any}("changed" => !env_unchanged(v; depot)))
                                  for (k, v) in sort!(collect(tests); by = first) if v isa AbstractDict],
        "key" => _machine_key(machine), "preparing" => preparing(_machine_key(machine)))
end

# ── Testing before a submitted sweep goes out ────────────────────────────────────────────────
# Submit asks for the work; a run whose environment has never passed a test on the machine cannot
# go out yet, so the hub's supervisor starts the test (`Sweep.advance_started!`) and submits once it
# passes. Once per machine and project for the life of this hub: a test that fails is not retried
# behind anyone's back, and the card's Prepare runs it again.
const _AUTO_TESTS = Set{String}()
const _AUTO_TESTS_LOCK = ReentrantLock()

function auto_prepare_batch!(machine::AbstractString, project::AbstractString, resources)
    isempty(project) && return false
    key = _batch_key(machine)
    st = preparing(key)
    (st !== nothing && st["running"] === true) && return false
    fresh = lock(_AUTO_TESTS_LOCK) do
        k = String(machine) * "|" * String(project)
        k in _AUTO_TESTS ? false : (push!(_AUTO_TESTS, k); true)
    end
    fresh || return false
    _rlog("sweep on $machine: $(basename(project))'s environment has not run on its nodes — testing it before submitting")
    Threads.@spawn try
        prepare_batch!(machine; project, resources)
    catch e
        prepare_failed_to_start!(key, e)
    end
    return true
end
