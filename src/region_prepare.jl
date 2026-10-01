# ── Preparing a region ───────────────────────────────────────────────────────────────────────
# Setting a machine up for workers, done once and on purpose rather than inside a notebook run: sign
# in, put Julia and the worker runtime in place, read what the site is like, and, for a cluster, try a
# worker on a real node. What it finds is kept in the region (`Region.readiness`), and a run uses it:
# the prologue a site needs, the patience its package loads need, and the fingerprints a start checks
# to notice the site has changed since.
#
# The notebook's own environment is not prepared here. It changes during a session, so it stays with
# provisioning, which a matching fingerprint makes free.

# What the probe reads. One line per fact, `key=value`, so a site that lacks one tool loses one fact.
const _PROBE_SCRIPT = raw"""
echo "arch=$(uname -m)"
echo "cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')"
echo "cores=$(nproc 2>/dev/null)"
echo "home=$HOME"
echo "modules=$( (module -t list 2>&1) 2>/dev/null | grep -v ':$' | tr '\n' ' ')"
echo "cudalibs=$(echo "$LD_LIBRARY_PATH" | tr ':' '\n' | grep -i cuda | tr '\n' ' ')"
echo "julia=$(PATH="$HOME/.juliaup/bin:$PATH" julia --version 2>/dev/null)"
echo "gpus=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')"
echo "gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
"""

function _parse_probe(out::AbstractString)
    d = Dict{String,String}()
    for line in eachline(IOBuffer(out))
        m = match(r"^([a-z]+)=(.*)$", line)
        m === nothing || (d[m.captures[1]] = strip(m.captures[2]))
    end
    return d
end

# Modules a site loads by default that put a CUDA toolkit's libraries on LD_LIBRARY_PATH. CUDA.jl
# brings its own and warns, and can fail, when the system's are found first. Unloading them before
# the worker starts is the fix, unless the region's own prologue already does.
function _site_prologue(facts::AbstractDict, own_prologue::AbstractString = "")
    isempty(get(facts, "cudalibs", "")) && return ""
    mods = split(get(facts, "modules", ""))
    shadow = [String(m) for m in mods if occursin(r"^(cudatoolkit|cuda)(/|$)"i, m)]
    names = unique([first(split(m, '/')) for m in shadow])
    names = filter(n -> !occursin(Regex("unload\\s+(\\S+\\s+)*" * n * "\\b"), own_prologue), names)
    return isempty(names) ? "" : "module unload " * join(names, " ")
end

# How long a worker here may be silent before its wire is dropped: the time it took to load the
# runtime and the environment, with room for a slower node and a busy filesystem. Never below the
# hub's default, which still covers the ordinary pause.
_grace_for(load_s::Real; floor_s::Real = 45) = max(Int(floor_s), ceil(Int, 2 * load_s + 30))

# The fingerprints a start compares against the record. A start reads them as part of `_host_state`.
const _STAMP_SCRIPT = raw"""
echo "julia=$(PATH="$HOME/.juliaup/bin:$PATH" julia --version 2>/dev/null)"
echo "modules=$( (module -t list 2>&1) 2>/dev/null | grep -v ':$' | sort | tr '\n' ' ')"
"""

_stamps_of(facts::AbstractDict) = Dict{String,Any}(
    "julia" => get(facts, "julia", ""),
    "modules" => join(sort(split(get(facts, "modules", ""))), " "))

# Progress of the prepares running now, for the page and the tool. One per region at a time.
const _PREPARING = Dict{String,Dict{String,Any}}()
const _PREPARING_LOCK = ReentrantLock()

# Every line logged since the region's prepare started; the report keeps all of them.
_full_log(name) = lock(_REGION_TRACE_LOCK) do; copy(get(_REGION_FULL_LOG, String(name), String[])); end

# The latest lines logged while region `name` was being worked on, oldest first.
_trace_tail(name, n::Int) = lock(_REGION_TRACE_LOCK) do
    b = get(_REGION_TRACE, String(name), String[])
    length(b) > n ? b[end-n+1:end] : copy(b)
end

"Whether a prepare of region `name` is running now."
prepare_running(name) = lock(_PREPARING_LOCK) do
    x = get(_PREPARING, _fold_region(name), nothing)
    x !== nothing && x["running"] === true
end

function preparing(name)
    s = lock(_PREPARING_LOCK) do
        x = get(_PREPARING, _fold_region(name), nothing)
        x === nothing ? nothing : deepcopy(x)
    end
    if s !== nothing
        s["log"] = _trace_tail(_fold_region(name), 80)
        # When anything was last heard: the page tells a slow step from a stuck one by this.
        s["last_output"] = lock(() -> get(_REGION_TRACE_AT, _fold_region(name), 0.0), _REGION_TRACE_LOCK)
        s["now"] = time()
    end
    return s
end

# ── Reports ──────────────────────────────────────────────────────────────────────────────────
# Every prepare leaves a file, written when it starts and again after each step, so one cut off by a
# hub restart still says how far it got. Slate never deletes or rewrites them: they are what is left
# to read when a site misbehaves. `Region.readiness` is the summary a start uses; this is the record.
# Under the DATA home, which nothing clears: the cache home is regenerable and may be wiped.
_reports_dir(name) = joinpath(SlateHome.data_home(), "prepare", String(name))

function _write_report!(name, state)
    try
        d = _reports_dir(name); mkpath(d)
        snap = lock(_PREPARING_LOCK) do; deepcopy(state); end
        snap["log"] = _full_log(String(name))
        p = joinpath(d, String(snap["id"]) * ".json")
        tmp = p * ".tmp"
        write(tmp, JSON.json(snap, 2)); mv(tmp, p; force = true)
    catch e
        _rlog("prepare[$name]: could not write the report — $(sprint(showerror, e))")
    end
    return nothing
end

# How a report ended: running (this hub is still on it), interrupted (it stopped mid-way, the hub
# restarting under it), failed, with warnings, or ok.
function _report_outcome(name, rep::AbstractDict)
    if rep["running"] === true
        live = preparing(name)
        return (live !== nothing && live["running"] === true && get(live, "id", "") == rep["id"]) ? "running" : "interrupted"
    end
    rec = get(rep, "record", nothing)
    steps = get(rep, "steps", Any[])
    any(s -> get(s, "status", "") == "fail", steps) && return "failed"
    any(s -> get(s, "status", "") == "warn", steps) && return "warnings"
    return rec isa AbstractDict && get(rec, "ok", false) === true ? "ok" : "failed"
end

"""
    prepare_reports(name) -> Vector{Dict}

Every prepare of region `name` this hub has run, newest first: `id`, `started`, `outcome`, the
project it tested, and how many steps warned or failed.
"""
function prepare_reports(name)
    d = _reports_dir(_fold_region(name))
    isdir(d) || return Dict{String,Any}[]
    out = Dict{String,Any}[]
    for f in sort(filter(endswith(".json"), readdir(d)); rev = true)
        rep = try; JSON.parsefile(joinpath(d, f)); catch; continue; end
        steps = get(rep, "steps", Any[])
        push!(out, Dict{String,Any}("id" => get(rep, "id", first(f, length(f) - 5)),
            "started" => get(rep, "started", 0), "project" => get(rep, "project", ""),
            "outcome" => _report_outcome(_fold_region(name), rep),
            "warnings" => count(s -> get(s, "status", "") == "warn", steps),
            "failures" => count(s -> get(s, "status", "") == "fail", steps)))
    end
    return out
end

"One prepare report of region `name` in full, or `nothing`."
function prepare_report(name, id::AbstractString)
    occursin(r"^[0-9T-]+$", id) || return nothing          # an id is a timestamp, never a path
    p = joinpath(_reports_dir(_fold_region(name)), id * ".json")
    isfile(p) || return nothing
    rep = try; JSON.parsefile(p); catch; return nothing; end
    rep["outcome"] = _report_outcome(_fold_region(name), rep)
    return rep
end

# The environment a reference project stands for, as a start would install it: a notebook's own
# environment when it has one, else the project it sits in; a folder is taken as a project. Returns
# `(origin_env, parent_project)`, or two empty strings when there is nothing to test with.
function _reference_env(p::AbstractString)
    isempty(strip(p)) && return ("", "")
    path = abspath(expanduser(strip(p)))
    if isfile(path)
        proj = Base.current_project(dirname(path))
        proj === nothing && error("no Project.toml above $path")
        parent = dirname(proj)
        envdir = notebook_env_dir(path)
        return (isfile(joinpath(envdir, "Project.toml")) ? envdir : parent, parent)
    end
    isfile(joinpath(path, "Project.toml")) || error("$path has no Project.toml")
    return (path, path)
end

"""
    prepare_failed_to_start!(name, err)

Record a prepare that ended before its first step, so whoever asked sees why rather than nothing:
it shows as a finished prepare with one failed step carrying the error.
"""
function prepare_failed_to_start!(name, err)
    msg = err isa Exception ? first(sprint(showerror, err), 600) : String(err)
    n = _fold_region(name)
    lock(_PREPARING_LOCK) do
        cur = get(_PREPARING, n, nothing)
        (cur !== nothing && cur["running"] === true) && return
        step = Dict{String,Any}("step" => "Start", "status" => "fail", "detail" => msg, "secs" => 0.0)
        _PREPARING[n] = Dict{String,Any}("region" => n, "running" => false, "started" => time(),
            "steps" => Any[step], "record" => Dict{String,Any}("prepared_at" => time(), "ok" => false,
                                                               "steps" => Any[step]))
    end
    _rlog("prepare[$n]: could not start — $msg")
    return nothing
end

"""
    prepare_region!(name; node = nothing, project = "", keep_node = false, worker = nothing) -> Dict

Prepare region `name`: sign in, put Julia and the worker runtime in place, read the site, create the
data root, and on a scheduler region (by default the first time only, or as `node` says) start a
worker on a granted node to time its loads and check its GPUs. `project` (a notebook or a project
folder; the region's preload when empty) is installed and loaded on that node (on the host itself for
a region without a scheduler), which is where CUDA is checked, and leaves the environment there ready
for that project's first start. `keep_node` leaves the node held for the notebook that asked.
`worker` is that notebook's own worker, as `(start = () -> …, run = code -> stdout)`: when given, the
packages are loaded in it rather than in a throwaway process, and it stays up for the notebook's cells.
Returns the readiness record, which is
also stored in the region. Runs to the end even when a step fails, recording each step's outcome, so
one problem does not hide the next. Blocking; callers that cannot wait spawn it.
"""
function prepare_region!(name::AbstractString; node::Union{Nothing,Bool} = nothing,
                         project::AbstractString = "", keep_node::Bool = false, worker = nothing)
    r = region_get(name)
    r === nothing && error("no region '$name'")
    isempty(r.host) && error("region '$(r.name)' has no host")
    ref = _reference_env(isempty(strip(project)) ? r.preload : project)   # checked before anything runs
    state = Dict{String,Any}("region" => r.name, "running" => true, "started" => time(),
                             "steps" => Any[], "host" => r.host, "project" => ref[1],
                             "id" => Dates.format(Dates.now(Dates.UTC), "yyyymmddTHHMMSS"))
    lock(_PREPARING_LOCK) do
        cur = get(_PREPARING, r.name, nothing)
        (cur !== nothing && cur["running"] === true) && error("region '$(r.name)' is already being prepared")
        _PREPARING[r.name] = state
    end
    facts = Dict{String,Any}()
    measured = Dict{String,Any}()
    ok_all = Ref(true)
    # Every `_rlog` from here on, however deep, lands in this region's trace: the page shows it as the
    # prepare's activity, and the record keeps its tail. Restored at the end, for a caller's own task.
    region_trace_reset!(r.name)
    lock(_REGION_TRACE_LOCK) do; _REGION_FULL_LOG[r.name] = String[]; end
    was_region = _current_rlog_region()
    task_local_storage(:slate_rlog_region, r.name)
    _write_report!(r.name, state)
    function step(f, title)
        s = Dict{String,Any}("step" => title, "status" => "running", "detail" => "", "secs" => 0.0,
                             "started" => time())
        lock(_PREPARING_LOCK) do; push!(state["steps"], s); end
        _write_report!(r.name, state)
        t0 = time()
        status, detail = try
            f()
        catch e
            ("fail", first(sprint(showerror, e), 600))
        end
        lock(_PREPARING_LOCK) do
            s["status"] = status; s["detail"] = String(detail); s["secs"] = round(time() - t0; digits = 1)
        end
        status == "fail" && (ok_all[] = false)
        _rlog("prepare[$(r.name)]: $title — $status" * (isempty(detail) ? "" : ": $(first(detail, 300))"))
        _write_report!(r.name, state)
        return status
    end
    # What a long step is doing now, shown under it while it runs and logged to the activity.
    function note(text)
        lock(_PREPARING_LOCK) do
            isempty(state["steps"]) || (state["steps"][end]["detail"] = String(text))
        end
        _rlog("prepare[$(r.name)]: $text")
        return nothing
    end
    host = r.host
    try
        signed = step("Sign in to $host") do
            Sweep.connected(host) && return ("ok", "session already open")
            ok, why = Sweep.connect_waiting!(host)
            ok ? ("ok", "signed in with a key") :
                ("fail", "could not sign in without a prompt" * (isempty(why) ? "" : ": " * first(strip(why), 300)) *
                         " — use the padlock, then prepare again")
        end
        if signed != "fail"
            step("Julia on $host") do
                _ensure_julia!(host) || return ("fail", "no working julia after the install; see remote.log")
                ok, out = _run_on(host, _julia_sh("julia --version"))
                ok ? ("ok", strip(out)) : ("fail", strip(out))
            end
            step("Worker runtime on $host") do
                ("ok", _provision_runtime!(host))
            end
            step("Read the site") do
                ok, out = _run_on(host, _PROBE_SCRIPT)
                ok || return ("fail", first(strip(out), 300))
                merge!(facts, Dict("host" => _parse_probe(out)))
                h = facts["host"]
                ("ok", join(filter(!isempty, [get(h, "cpu", ""), get(h, "julia", ""),
                                             isempty(get(h, "modules", "")) ? "" : "modules: " * h["modules"]]), " · "))
            end
            if !isempty(r.data_root)
                step("Data root $(r.data_root)") do
                    q = Sweep.shq_path(r.data_root)
                    ok, out = _run_on(host, "mkdir -p $q && test -w $q && echo ok")
                    (ok && occursin("ok", out)) ? ("ok", "exists and is writable") :
                        ("fail", "cannot create or write it: " * first(strip(out), 200))
                end
            end
            # Fetching the project's packages needs the network and nothing else, so on a cluster it
            # happens here, on the login node, where it costs no allocation. They are compiled on a node.
            if r.scheduler !== :none && !isempty(ref[1])
                step("Download $(basename(ref[1]))'s packages") do
                    t = _region_target(r; origin_env = ref[1], at = (String(host), ""))
                    provision_remote!(t, ref[2]; precompile = false)
                    ("ok", "")
                end
            end
            run_node = node === nothing ? (r.scheduler !== :none && isempty(r.readiness)) : node
            if r.scheduler === :none
                _prepare_env!(r, step, measured, ref, host, _probed_prologue(r, facts); worker)
            elseif run_node
                _prepare_on_node!(r, step, facts, measured, ref; keep_node, note, worker)
            end
        end
    finally
        hostf = get(facts, "host", Dict{String,String}())
        nodef = get(facts, "node", Dict{String,String}())
        seen = isempty(nodef) ? hostf : nodef         # the node is where the worker runs, when we got one
        rt = Float64(get(measured, "runtime_load_s", 0.0))
        prev = region_get(r.name)
        old = prev === nothing ? Dict{String,Any}() : prev.readiness
        # The site's part: what any worker here meets, whatever notebook it serves.
        rec = Dict{String,Any}(
            "prepared_at" => time(), "ok" => ok_all[], "steps" => deepcopy(state["steps"]),
            "facts" => facts, "measured" => rt > 0 ? Dict{String,Any}("runtime_load_s" => rt) : Dict{String,Any}(),
            "prologue" => _site_prologue(seen, prev === nothing ? r.prologue : prev.prologue),
            "liveness_grace_s" => rt > 0 ? _grace_for(rt) : 0,
            # Only what was actually read: a prepare that never reached the site has nothing to
            # compare a start against, and blanks would mark every start as a changed site.
            "stamps" => isempty(seen) ? Dict{String,Any}() : _stamps_of(seen), "stale" => "",
            "report" => state["id"])   # the full log is in the report, not here
        # One report per project tested here, keyed like the project's environment on the host. This
        # prepare's replaces the one for its project; the others stand.
        envs = Dict{String,Any}(get(old, "envs", Dict{String,Any}()))
        if haskey(measured, "env_load_s")
            el = Float64(measured["env_load_s"])
            envs[_proj_key(ref[1])] = Dict{String,Any}(
                "project" => ref[1], "fingerprint" => _env_fingerprint(ref[1], _infra_spec()),
                "prepared_at" => time(), "status" => get(measured, "env_status", "ok"),
                "load_s" => el, "liveness_grace_s" => _grace_for(rt + el),
                "cuda" => get(measured, "cuda", nothing))
        end
        rec["envs"] = envs
        # A host-only prepare keeps what an earlier node stage found: nothing here re-read the node.
        if isempty(nodef) && !isempty(old)
            if rt == 0 && haskey(old, "measured")
                rec["measured"] = old["measured"]
                rec["liveness_grace_s"] = get(old, "liveness_grace_s", 0)
            end
            of = get(old, "facts", nothing)
            if of isa AbstractDict && haskey(of, "node")
                rec["facts"]["node"] = of["node"]
                rec["stamps"] = _stamps_of(of["node"])
                rec["prologue"] = _site_prologue(of["node"], prev.prologue)
            end
        end
        try; region_set!(r.name; readiness = rec); catch e
            _rlog("prepare[$(r.name)]: could not store the record — $(sprint(showerror, e))")
        end
        lock(_PREPARING_LOCK) do; state["running"] = false; state["record"] = rec; state["ended"] = time(); end
        _write_report!(r.name, state)
        lock(_REGION_TRACE_LOCK) do; delete!(_REGION_FULL_LOG, r.name); end
        task_local_storage(:slate_rlog_region, was_region)
    end
    return lock(_PREPARING_LOCK) do; state["record"]; end
end

# What the host's probe calls for, applied now: the record is written at the end, and a node stage
# that ran without it would report the very problem it already knows how to fix.
function _probed_prologue(r::Region, facts)
    parts = filter(!isempty, [_site_prologue(get(facts, "host", Dict{String,String}()), r.prologue),
                              strip(r.prologue)])
    return isempty(parts) ? "" : "{ " * join(parts, " ; ") * " ; } && "
end

# The node stage: a granted node, read the same way the host was, and a worker runtime loaded there
# the way a worker loads it, timed. The region's preload environment, when it has one, is provisioned
# and loaded too, which is where CUDA is checked. The node is given back at the end.
# When the scheduler expects a pending job to start, as it prints it, or "" when it has no estimate.
function _start_estimate(r::Region, id::AbstractString)
    region_scheduler(r) === :slurm || return ""
    ok, out = _run_on(r.host, "squeue -h --start -j " * Sweep.shq(id) * " -o %S 2>/dev/null")
    t = ok ? strip(out) : ""
    return (isempty(t) || t == "N/A") ? "" : replace(t, "T" => " ")
end

function _prepare_on_node!(r::Region, step, facts, measured, ref; keep_node::Bool = false, note = _ -> nothing,
                           worker = nothing)
    got = step("Get a node from $(r.scheduler)") do
        deadline = time() + 30 * 60
        t0 = time()
        while time() < deadline
            nodehost, a = region_place!(r; wait_s = 30)
            isempty(nodehost) || return ("ok", "$nodehost (job $(a === nothing ? "?" : a.id))")
            a === nothing && return ("fail", "the scheduler granted nothing and reported no request")
            a.state === :unreachable && return ("fail", "cannot reach $(r.host) to ask for a node")
            est = isempty(a.id) ? "" : _start_estimate(r, a.id)
            note("queued as job $(a.id) for $(round(Int, (time() - t0) / 60))m" *
                 (isempty(est) ? "" : " · estimated start $est"))
        end
        ("fail", "no node within 30 minutes; the request was left queued")
    end
    got == "ok" || return nothing
    node = region_host(r)
    pro = _probed_prologue(r, facts)
    try
        step("Read the node") do
            ok, out = _run_on(node, _PROBE_SCRIPT)
            ok || return ("fail", first(strip(out), 300))
            nf = _parse_probe(out)
            facts["node"] = nf
            hf = get(facts, "host", Dict{String,String}())
            same_cpu = get(hf, "cpu", "") == get(nf, "cpu", "")
            facts["same_cpu"] = same_cpu
            ("ok", join(filter(!isempty, [get(nf, "cpu", ""), get(nf, "cores", "") * " cores",
                                         get(nf, "gpus", "0") == "0" ? "" : get(nf, "gpus", "") * " × " * get(nf, "gpu", ""),
                                         same_cpu ? "same CPU as $(r.host)" : "different CPU from $(r.host)"]), " · "))
        end
        step("Home shared with $(r.host)") do
            mark = ".cache/kaimonslate/.prepare-$(bytes2hex(rand(UInt8, 4)))"
            _run_on(r.host, "mkdir -p .cache/kaimonslate && touch $mark")
            ok, out = _run_on(node, "test -f $mark && echo shared; rm -f $mark")
            facts["home_shared"] = ok && occursin("shared", out)
            facts["home_shared"] ? ("ok", "") :
                ("warn", "the node does not see files written on $(r.host); Julia and packages install on the node itself")
        end
        # With the notebook's worker to start, its start is the runtime's load, timed for real.
        worker === nothing && step("Load the worker runtime") do
            t0 = time()
            ok, out = _run_on(node, pro * _julia_sh("julia --startup-file=no --project=\$HOME/$_REMOTE_KGATE_ENV " *
                                                    "-e 'using KaimonGate, Revise'"))
            secs = round(time() - t0; digits = 1)
            ok || return ("fail", first(strip(out), 400))
            measured["runtime_load_s"] = secs
            ("ok", "$(secs)s")
        end
        _prepare_env!(r, step, measured, ref, node, pro; worker)
    finally
        keep_node ? step(() -> ("ok", region_host(r) * (haskey(measured, "worker_start_s") ? " · its worker is up" : "")),
                         "Keep the node for the notebook") :
        step("Give the node back") do
            region_release!(r) ? ("ok", "") : ("warn", "nothing to release")
        end
    end
    return nothing
end

# Loads every direct dependency of the active project and reports, one `key=value` per line, how long
# that took and what CUDA found. Run in a fresh process, or in the notebook's worker.
const _LOAD_CODE = """
t0 = time()
import Pkg, Libdl
for (_, p) in Pkg.dependencies()
    p.is_direct_dep || continue
    try; Core.eval(Main, Expr(:import, Expr(:., Symbol(p.name)))); catch; end
end
println("load=", round(time() - t0; digits = 1))
if isdefined(Main, :CUDA)
    C = getfield(Main, :CUDA)
    println("cuda=", C.functional(), " devices=", C.functional() ? length(C.devices()) : 0)
    sys = filter(l -> occursin("cuda", lowercase(l)) && startswith(l, "/opt"), Libdl.dllist())
    println("syscuda=", join(sys, " "))
end
"""

# Install the reference project's environment where its workers will run, load every package in it
# with timing, and check CUDA when it is among them. On a scheduler region `host` is the granted node;
# elsewhere it is the host itself. The environment stays installed, stamped, for the project's start.
function _prepare_env!(r::Region, step, measured, ref, host, pro; worker = nothing)
    isempty(ref[1]) && return nothing
    name = basename(ref[1])
    t = _region_target(r; origin_env = ref[1])
    rel = startswith(t.project, "~/") ? t.project[3:end] : t.project
    got = step("Install $name") do
        provision_remote!(t, ref[2])
        ("ok", "")
    end
    got == "fail" && return nothing
    # Compiled here, where the workers run, and timed apart from loading: the load time below is what
    # every start pays, which is what the liveness grace is made from; this is paid once.
    step("Precompile $name") do
        t0 = time()
        ok, out = _ssh_julia!(host, "import Pkg; Pkg.activate(joinpath(homedir(), raw\"$rel\")); Pkg.precompile()",
                              "precompile $name on $host"; stream = true)
        ok ? ("ok", "$(round(time() - t0; digits = 1))s") : ("fail", first(strip(out), 400))
    end
    worker === nothing || return _prepare_in_worker!(step, measured, name, worker)
    step("Load $name") do
        ok, out = _run_on(host, pro * _julia_sh("julia --startup-file=no --project=\$HOME/$rel -e " * Sweep.shq(_LOAD_CODE));
                          timeout = 1800.0)
        ok || return ("fail", first(strip(out), 400))
        _load_result!(measured, out)
    end
    return nothing
end

# The load report as a step outcome, with what it measured kept in `measured`.
function _load_result!(measured, out::AbstractString)
    f = _parse_probe(out)
    measured["env_load_s"] = something(tryparse(Float64, get(f, "load", "")), 0.0)
    cuda = get(f, "cuda", "")
    sys = get(f, "syscuda", "")
    isempty(cuda) || (measured["cuda"] = Dict("functional" => cuda, "system_libs" => sys))
    status = (startswith(cuda, "false") || !isempty(sys)) ? "warn" : "ok"
    measured["env_status"] = status
    return (status, "loaded in $(measured["env_load_s"])s" *
                    (isempty(cuda) ? "" : " · CUDA functional=$cuda") *
                    (isempty(sys) ? "" : " · CUDA libraries from the system: $(first(sys, 200))"))
end

# The notebook's own worker: started the way its cells would start it, and the packages loaded in it,
# so the first run after preparing finds both done. Its start is the runtime's load time.
function _prepare_in_worker!(step, measured, name, worker)
    up = step("Start the notebook's worker") do
        t0 = time()
        worker.start()
        measured["worker_start_s"] = measured["runtime_load_s"] = round(time() - t0; digits = 1)
        ("ok", "up in $(measured["worker_start_s"])s")
    end
    up == "ok" || return nothing
    step("Load $name in it") do
        # In a module of its own: the code imports at top level, and its names must not land in the
        # notebook's namespace.
        _load_result!(measured, worker.run("Core.eval(Module(:SlatePrepare), Meta.parseall(" * repr(_LOAD_CODE) * "))"))
    end
    return nothing
end

"""
    readiness_check!(t::RemoteTarget; seen = nothing)

On a start, compare what a prepared region recorded about its site with what the host reports now,
and mark the region stale when they differ. `seen` is the host's state when the caller already read
it (`_host_state`); otherwise one command reads the stamps. Never blocks the start.
"""
function readiness_check!(t::RemoteTarget; seen = nothing)
    isempty(t.region) && return nothing
    r = region_get(t.region)
    (r === nothing || isempty(r.readiness)) && return nothing
    want = get(r.readiness, "stamps", nothing)
    (want isa AbstractDict && !isempty(want)) || return nothing
    if seen === nothing
        ok, out = _run_on(t.ssh_host, _STAMP_SCRIPT)
        ok || return nothing
        seen = _parse_probe(out)
    end
    now = _stamps_of(seen)
    diffs = [k for k in keys(now) if String(get(want, k, "")) != String(now[k])]
    stale = isempty(diffs) ? "" : "changed since prepared: " * join(sort(diffs), ", ")
    stale == String(get(r.readiness, "stale", "")) && return nothing
    rec = copy(r.readiness); rec["stale"] = stale
    region_set!(r.name; readiness = rec)
    isempty(stale) || _rlog("region[$(r.name)]: $stale — prepare it again")
    return nothing
end

# ── Reading it back ──────────────────────────────────────────────────────────────────────────
"What preparing `r` found for the project whose environment is `origin_env`, or `nothing`."
function env_report(r::Region, origin_env::AbstractString)
    isempty(origin_env) && return nothing
    envs = get(r.readiness, "envs", nothing)
    envs isa AbstractDict || return nothing
    e = get(envs, _proj_key(origin_env), nothing)
    return e isa AbstractDict ? e : nothing
end

# Whether a tested project's environment is still the one that was tested.
env_unchanged(e::AbstractDict) = isdir(String(get(e, "project", ""))) &&
    _env_fingerprint(String(e["project"]), _infra_spec()) == String(get(e, "fingerprint", ""))

# The record as the page shows it: each tested project marked `changed` when its environment is no
# longer the one that was tested.
function readiness_view(r::Region)
    isempty(r.readiness) && return r.readiness
    rec = copy(r.readiness)
    envs = get(rec, "envs", nothing)
    envs isa AbstractDict || return rec
    rec["envs"] = Dict{String,Any}(k => (e isa AbstractDict ? merge(Dict{String,Any}(e), Dict{String,Any}("changed" => !env_unchanged(e))) : e)
                                   for (k, e) in envs)
    return rec
end

const _STEP_MARK = Dict("ok" => "✓", "warn" => "⚠", "fail" => "✗", "running" => "…")

function _steps_text(io, steps)
    for s in steps
        mark = get(_STEP_MARK, String(get(s, "status", "")), "?")
        secs = get(s, "secs", 0)
        detail = String(get(s, "detail", ""))
        println(io, "  $mark $(get(s, "step", ""))", secs > 0 ? "  ($(secs)s)" : "",
                isempty(detail) ? "" : " — " * detail)
    end
end

"The readiness of region `r` in a few lines: when, the outcome, and what it set for run time."
function readiness_text(r::Region)
    rec = r.readiness
    isempty(rec) && return "not prepared"
    io = IOBuffer()
    at = Dates.format(Dates.unix2datetime(Float64(get(rec, "prepared_at", 0))), "yyyy-mm-dd HH:MM") * " UTC"
    stale = String(get(rec, "stale", ""))
    println(io, "prepared $at — ", get(rec, "ok", false) === true ? "ok" : "with failures",
            isempty(stale) ? "" : " — STALE ($stale)")
    pro = String(get(rec, "prologue", ""))
    isempty(pro) || println(io, "  site prologue: $pro")
    envs = get(rec, "envs", nothing)
    if envs isa AbstractDict
        for (_, e) in sort!(collect(envs); by = first)
            c = get(e, "cuda", nothing)
            println(io, "  tested with $(e["project"]): loads in $(e["load_s"])s",
                    c isa AbstractDict ? ", CUDA functional=$(c["functional"])" : "",
                    env_unchanged(e) ? "" : " (its environment has changed since)")
        end
    end
    g = get(rec, "liveness_grace_s", 0)
    g isa Real && g > 0 && println(io, "  liveness grace from measured loads: $(round(Int, g))s")
    _steps_text(io, get(rec, "steps", Any[]))
    return String(take!(io))
end
