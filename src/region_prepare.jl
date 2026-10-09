# ── Preparing a region ───────────────────────────────────────────────────────────────────────
# Setting a machine up for workers, done once and on purpose rather than inside a notebook run: sign
# in, put Julia and the worker runtime in place, read what the site is like, and, for a cluster, try a
# worker on a real node. What it finds is kept in the region (`Region.readiness`), and a run uses it:
# the prologue a site needs, the patience its package loads need, and the fingerprints a start checks
# to notice the site has changed since.
#
# The notebook's own environment is not prepared here. It changes during a session, so it stays with
# provisioning, which a matching fingerprint makes free.

# The loaded modules, or nothing on a site without a module system. Asked of the shell first: the
# error a missing `module` prints names the shell's path, which differs between the login node and a
# compute node, and a stamp made of it reads as a changed site on every start.
const _MODULES_LINE = raw"echo \"modules=$(type module >/dev/null 2>&1 && module -t list 2>&1 | grep -v ':$' | sort | tr '\n' ' ')\""

# Whether Julia's preferences on this site tell CUDA.jl to use the system CUDA toolkit: some
# directory on JULIA_LOAD_PATH holds a project whose `[preferences.CUDA_Runtime_jll]` sets
# `local = "true"`. Cluster module systems set this up on purpose, by loading a module that adds
# such a directory and a module that puts the toolkit's libraries on LD_LIBRARY_PATH.
const _CUDALOCAL_LINE = String(strip(raw"""
echo "cudalocal=$(for d in $(echo "$JULIA_LOAD_PATH" | tr ':' ' '); do for f in "$d"/Project.toml "$d"/JuliaProject.toml "$d"/LocalPreferences.toml "$d"/JuliaLocalPreferences.toml; do [ -f "$f" ] && awk '/^\[preferences\.CUDA_Runtime_jll\]/{s=1;next} /^\[/{s=0} s && /^local[ \t]*=[ \t]*"?true"?/{print "yes"; exit}' "$f"; done; done | head -1)"
"""))

# Each loaded CUDA module by name, with whether the site lets it be unloaded: `ok`, or `fails` when
# another loaded module requires it. The unload is tried in a subshell, so the probe keeps every
# module.
const _CUDAMODS_LINE = String(strip(raw"""
echo "cudamods=$(type module >/dev/null 2>&1 && for m in $(module -t list 2>&1 | grep -iE '^(cudatoolkit|cuda)(/|$)'); do n=${m%%/*}; if ( module unload "$n" >/dev/null 2>&1 ); then v=ok; else v=fails; fi; printf '%s:%s ' "$n" "$v"; done)"
"""))

# What the probe reads. One line per fact, `key=value`, so a site that lacks one tool loses one fact.
const _PROBE_SCRIPT = replace(raw"""
echo "arch=$(uname -m)"
echo "cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')"
echo "cores=$(nproc 2>/dev/null)"
echo "home=$HOME"
MODULES_LINE
echo "cudalibs=$(echo "$LD_LIBRARY_PATH" | tr ':' '\n' | grep -i cuda | tr '\n' ' ')"
CUDALOCAL_LINE
CUDAMODS_LINE
echo "julia=$(PATH="$HOME/.juliaup/bin:$PATH" julia --version 2>/dev/null)"
echo "gpus=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')"
echo "gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
echo "scratch=${SCRATCH:-${PSCRATCH:-}}"
""", "MODULES_LINE" => _MODULES_LINE, "CUDALOCAL_LINE" => _CUDALOCAL_LINE,
    "CUDAMODS_LINE" => _CUDAMODS_LINE)

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
#
# That premise fails on a site that points CUDA.jl at the system toolkit on purpose, through Julia
# preferences (`cudalocal`): unloading the toolkit's module would remove the libraries CUDA.jl was
# told to use. Nothing is unloaded there. Elsewhere, only a module that the site lets go is unloaded
# (`cudamods`), because an unload that fails stops every worker from starting. A record from before
# these facts existed falls back to the module names alone, leaving out a module whose version names
# Julia.
function _site_prologue(facts::AbstractDict, own_prologue::AbstractString = "")
    isempty(get(facts, "cudalibs", "")) && return ""
    get(facts, "cudalocal", "") == "yes" && return ""
    mods = split(get(facts, "modules", ""))
    shadow = [String(m) for m in mods if occursin(r"^(cudatoolkit|cuda)(/|$)"i, m) && !occursin(r"julia"i, m)]
    names = unique([first(split(m, '/')) for m in shadow])
    if haskey(facts, "cudamods")
        verdicts = Dict(String(first(p)) => String(last(p)) for p in
                        (split(w, ':'; limit = 2) for w in split(facts["cudamods"])) if length(p) == 2)
        names = filter(n -> get(verdicts, n, "") == "ok", names)
    end
    names = filter(n -> !occursin(Regex("unload\\s+(\\S+\\s+)*" * n * "\\b"), own_prologue), names)
    return isempty(names) ? "" : "module unload " * join(names, " ")
end

# How long a worker here may be silent before its wire is dropped: the time it took to load the
# runtime and the environment, with room for a slower node and a busy filesystem. Never below the
# hub's default, which still covers the ordinary pause.
_grace_for(load_s::Real; floor_s::Real = 45) = max(Int(floor_s), ceil(Int, 2 * load_s + 30))

# The fingerprints a start compares against the record. A start reads them as part of `_host_state`.
const _STAMP_SCRIPT = replace(raw"""
echo "julia=$(PATH="$HOME/.juliaup/bin:$PATH" julia --version 2>/dev/null)"
MODULES_LINE
""", "MODULES_LINE" => _MODULES_LINE)

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

# The environment a reference project stands for, as a start would install it (`_region_kernel!`): a
# notebook's own environment when it has one, else the project it sits in, else none, which leaves the
# worker runtime as all there is to test. A folder is taken as a project. Returns
# `(origin_env, parent_project)`, empty where there is none.
function _reference_env(p::AbstractString)
    isempty(strip(p)) && return ("", "")
    path = abspath(expanduser(strip(p)))
    if isfile(path)
        proj = Base.current_project(dirname(path))
        parent = proj === nothing ? "" : dirname(proj)
        envdir = notebook_env_dir(path)
        isfile(joinpath(envdir, "Project.toml")) && return (envdir, parent)
        return (parent, parent)
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
`worker` is that notebook's own worker, as `(start = fresh -> started, run = code -> stdout)` (`fresh` replaces a running one;
`start` returns `false` when the worker was already up, so its earlier start and load times stand): when given, the
packages are loaded in it rather than in a throwaway process, and it stays up for the notebook's cells.
Returns the readiness record, which is
also stored in the region. Runs to the end even when a step fails, recording each step's outcome, so
one problem does not hide the next. Blocking; callers that cannot wait spawn it.
"""
function prepare_region!(name::AbstractString; node::Union{Nothing,Bool} = nothing,
                         project::AbstractString = "", keep_node::Bool = false, worker = nothing,
                         rebuild_sysimage::Bool = false)
    r = region_get(name)
    r === nothing && error("no region '$name'")
    isempty(r.host) && error("region '$(r.name)' has no host")
    ref = _reference_env(isempty(strip(project)) ? r.preload : project)   # checked before anything runs
    host = r.host
    m = region_machine(r)
    facts = Dict{String,Any}()
    measured = Dict{String,Any}()
    finish = function (ok, state)
        hostf = get(facts, "host", Dict{String,String}())
        nodef = get(facts, "node", Dict{String,String}())
        prev = region_get(r.name)
        old = prev === nothing ? Dict{String,Any}() : prev.readiness
        # No start was timed when the worker was already up: the last one timed stands.
        rt = Float64(get(measured, "runtime_load_s", get(get(old, "measured", Dict()), "runtime_load_s", 0.0)))
        isempty(hostf) || _record_site!(host, hostf, nodef, m.prologue * "\n" * r.prologue, state["id"])
        # The region's part: the node, the loads timed there, and each project tested.
        rec = Dict{String,Any}(
            "prepared_at" => time(), "ok" => ok, "steps" => deepcopy(state["steps"]),
            "facts" => isempty(nodef) ? Dict{String,Any}() : Dict{String,Any}("node" => nodef),
            "measured" => rt > 0 ? Dict{String,Any}("runtime_load_s" => rt) : Dict{String,Any}(),
            "liveness_grace_s" => rt > 0 ? _grace_for(rt) : 0,
            "report" => state["id"])   # the full log is in the report, not here
        # The project's load is the machine's to keep: a sweep on the same kind of node runs in it too.
        if haskey(measured, "env_load_s")
            el = Float64(measured["env_load_s"])
            try
                record_env_test!(host, ref[1], region_node_type(r); by = r.name,
                    status = String(get(measured, "env_status", "ok")), depot = machine_depot(m),
                    load_s = el, liveness_grace_s = _grace_for(rt + el), cuda = get(measured, "cuda", nothing),
                    report = state["id"])
            catch e
                _rlog("prepare[$(r.name)]: could not record the environment's test — $(sprint(showerror, e))")
            end
        end
        # The image its workers boot from, when this prepare built one or found it current; an earlier
        # one stands otherwise.
        m = get(measured, "sysimage", nothing)
        if m isa AbstractDict && get(m, "result", "") in ("built", "current")
            rec["sysimage"] = _sysimage_record(m)
        elseif haskey(old, "sysimage")
            rec["sysimage"] = old["sysimage"]
        end
        # A prepare that reached no node keeps what an earlier node stage found.
        if isempty(nodef) && !isempty(old)
            if rt == 0 && haskey(old, "measured")
                rec["measured"] = old["measured"]
                rec["liveness_grace_s"] = get(old, "liveness_grace_s", 0)
            end
            of = get(old, "facts", nothing)
            (of isa AbstractDict && haskey(of, "node")) && (rec["facts"]["node"] = of["node"])
        end
        try; region_set!(r.name; readiness = rec); catch e
            _rlog("prepare[$(r.name)]: could not store the record — $(sprint(showerror, e))")
        end
        return rec
    end
    return _run_prepare(r.name, host, ref[1]; finish) do step, note
        signed = _site_steps!(step, host, m, facts; own = r.prologue)
        signed == "fail" && return
        step("Worker runtime on $host") do
            ("ok", _provision_runtime!(host; numbered = false))
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
                # `rebuild` also tests that the depot still holds what the stamp says was built, and
                # fetches only what it lost (`_env_action`).
                measured["env_action"] = provision_remote!(t, ref[2]; precompile = false, rebuild = true)
                measured["downloaded"] = true
                ("ok", "")
            end
        end
        run_node = node === nothing ? (r.scheduler !== :none && isempty(r.readiness)) : node
        if r.scheduler === :none
            _prepare_env!(r, step, measured, ref, host, _region_prologue(r.name); worker, rebuild_sysimage)
        elseif run_node
            _prepare_on_node!(r, step, facts, measured, ref; keep_node, note, worker, rebuild_sysimage)
        end
    end
end

# What a launch needs to know of a built image (`sysimage_plan`), kept in the region's readiness.
_sysimage_record(m) = Dict{String,Any}(k => m[k] for k in ("key", "dir", "cpu", "image", "bytes", "packages",
                                                           "spec", "listed", "built_at") if haskey(m, k))
function _record_sysimage!(name, m)
    r = region_get(name); r === nothing && return nothing
    try
        region_set!(r.name; readiness = merge(r.readiness, Dict{String,Any}("sysimage" => _sysimage_record(m))))
    catch e
        _rlog("prepare[$name]: could not record the sysimage — $(sprint(showerror, e))")
    end
    return nothing
end

# The machine's part of what a prepare found: what any worker or task on this host meets. Its stamps
# and module fix are read on a node when one was, since a start compares them there; a prepare that
# reached no node keeps what an earlier one read on a node.
function _record_site!(host, hostf, nodef, own::AbstractString, id)
    oldh = host_facts(host)
    hf = Dict{String,Any}("prepared_at" => time(), "facts" => hostf, "report" => id, "stale" => "")
    if !isempty(nodef)
        merge!(hf, Dict{String,Any}("stamps" => _stamps_of(nodef), "stamps_from" => "node",
                                    "site_prologue" => _site_prologue(nodef, own)))
    elseif get(oldh, "stamps_from", "") == "node"
        for k in ("stamps", "stamps_from", "site_prologue"); hf[k] = oldh[k]; end
    else
        merge!(hf, Dict{String,Any}("stamps" => _stamps_of(hostf), "stamps_from" => "host",
                                    "site_prologue" => _site_prologue(hostf, own)))
    end
    try; host_facts_merge!(host, hf); catch e
        _rlog("prepare: could not store what it found on $host — $(sprint(showerror, e))")
    end
    return nothing
end

# The machinery every prepare shares. Its progress is kept in `_PREPARING` under `key`, step by step;
# everything logged while it runs lands in `key`'s trace, which the page shows as its activity; and a
# report is written when it starts and after every step, so one cut off mid-way still says how far it
# got. `body(step, note)` runs the steps; `finish(ok, state)` stores what they found and returns the
# record. Both run when a step fails, and `finish` runs when the body throws.
function _run_prepare(body, key::AbstractString, host::AbstractString, project::AbstractString; finish)
    key = String(key)
    state = Dict{String,Any}("region" => key, "running" => true, "started" => time(),
                             "steps" => Any[], "host" => host, "project" => project,
                             "id" => Dates.format(Dates.now(Dates.UTC), "yyyymmddTHHMMSS"))
    lock(_PREPARING_LOCK) do
        cur = get(_PREPARING, key, nothing)
        (cur !== nothing && cur["running"] === true) && error("'$key' is already being prepared")
        _PREPARING[key] = state
    end
    ok_all = Ref(true)
    region_trace_reset!(key)
    lock(_REGION_TRACE_LOCK) do; _REGION_FULL_LOG[key] = String[]; end
    was_region = _current_rlog_region()
    task_local_storage(:slate_rlog_region, key)
    _write_report!(key, state)
    function step(f, title)
        s = Dict{String,Any}("step" => title, "status" => "running", "detail" => "", "secs" => 0.0,
                             "started" => time())
        lock(_PREPARING_LOCK) do; push!(state["steps"], s); end
        _write_report!(key, state)
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
        _rlog("prepare[$key]: $title — $status" * (isempty(detail) ? "" : ": $(first(detail, 300))"))
        _write_report!(key, state)
        return status
    end
    # What a long step is doing now, shown under it while it runs and logged to the activity.
    function note(text)
        lock(_PREPARING_LOCK) do
            isempty(state["steps"]) || (state["steps"][end]["detail"] = String(text))
        end
        _rlog("prepare[$key]: $text")
        return nothing
    end
    rec = Dict{String,Any}()
    try
        body(step, note)
    catch e
        step(() -> ("fail", first(sprint(showerror, e), 600)), "Prepare")
    finally
        rec = try
            finish(ok_all[], state)
        catch e
            _rlog("prepare[$key]: could not store the record — $(sprint(showerror, e))")
            Dict{String,Any}("prepared_at" => time(), "ok" => false, "steps" => deepcopy(state["steps"]),
                             "report" => state["id"])
        end
        lock(_PREPARING_LOCK) do; state["running"] = false; state["record"] = rec; state["ended"] = time(); end
        _write_report!(key, state)
        lock(_REGION_TRACE_LOCK) do; delete!(_REGION_FULL_LOG, key); end
        task_local_storage(:slate_rlog_region, was_region)
    end
    return rec
end

# The steps every prepare of a machine starts with: sign in, Julia, read the site, settle the depot.
# What the site read calls for is recorded as soon as it is known, since the steps after these start
# Julia there. Returns the sign-in's status; nothing else can run when it failed.
function _site_steps!(step, host::AbstractString, m, facts; own::AbstractString = "")
    signed = step("Sign in to $host") do
        Sweep.connected(host) && return ("ok", "session already open")
        ok, why = Sweep.connect_waiting!(host)
        ok ? ("ok", "signed in with a key") :
            ("fail", "could not sign in without a prompt" * (isempty(why) ? "" : ": " * first(strip(why), 300)) *
                     " — use the padlock, then prepare again")
    end
    signed == "fail" && return signed
    step("Julia on $host") do
        # A machine that names its own julia is used as it is; otherwise juliaup at the hub's, installed
        # only when there is none, and asked for its version again only after an install.
        ok, out = _run_on(host, machine_setup(m) * "julia --version")
        if isempty(m.julia)
            _ensure_julia!(host; version = ok ? out : "") || return ("fail", "no working julia after the install; see remote.log")
            ok || ((ok, out) = _run_on(host, machine_setup(m) * "julia --version"))
        end
        ok || return ("fail", strip(out))
        v = match(r"(\d+\.\d+\.\d+)", out)
        (v === nothing || v.captures[1] == string(VERSION)) ? ("ok", strip(out)) :
            ("warn", "$(strip(out)), the hub runs $VERSION: results and environments may not carry across")
    end
    step("Read the site") do
        ok, out = _run_on(host, _PROBE_SCRIPT)
        ok || return ("fail", first(strip(out), 300))
        merge!(facts, Dict("host" => _parse_probe(out)))
        h = facts["host"]
        # Recorded now, not at the end: the rest of this prepare starts Julia here, and has to
        # start it with the module fix in place.
        host_facts_merge!(host, Dict{String,Any}("site_prologue" => _site_prologue(h, m.prologue * "\n" * own),
                                                 "scratch" => get(h, "scratch", "")))
        ("ok", join(filter(!isempty, [get(h, "cpu", ""), get(h, "julia", ""),
                                     isempty(get(h, "modules", "")) ? "" : "modules: " * h["modules"]]), " · "))
    end
    step("Depot") do
        d = isempty(m.depot) ? _auto_depot(get(get(facts, "host", Dict{String,String}()), "scratch", "")) :
            (_is_default_depot(m.depot) ? "" : m.depot)
        if !isempty(d)
            q = Sweep.shq_path(d)
            ok, out = _run_on(host, "mkdir -p $q && test -w $q && echo ok")
            (ok && occursin("ok", out)) ||
                return ("fail", "cannot create or write $d: " * first(strip(out), 200))
        end
        # Automatic is resolved here, once, and every Julia on the machine runs in it from now.
        isempty(m.depot) && host_facts_merge!(host, Dict{String,Any}("depot" => d))
        ("ok", isempty(d) ? "~/.julia (no scratch filesystem found)" :
               d * (isempty(m.depot) ? " (scratch)" : ""))
    end
    return signed
end

# The shell a prepare's own Julia runs in on a host of `r`: the machine's setup, which already carries
# what reading the site found, then the region's prologue.
_prepare_shell(r::Region) = machine_setup(region_machine(r)) * _region_prologue(r.name)

# The node stage: a granted node, read the same way the host was, and a worker runtime loaded there
# the way a worker loads it, timed. The region's preload environment, when it has one, is provisioned
# and loaded too, which is where CUDA is checked. The node is given back at the end.
function _prepare_on_node!(r::Region, step, facts, measured, ref; keep_node::Bool = false, note = _ -> nothing,
                           worker = nothing, rebuild_sysimage::Bool = false)
    # A node held before the prepare started belongs to whoever is using it, and stays theirs.
    held_before = _region_holds_node(r)
    got = step("Get a node from $(r.scheduler)") do
        deadline = time() + 30 * 60
        t0 = time(); shown = ""; gave_back = 0.0
        # The prepare installs, precompiles and starts a worker, which can take many minutes, so an
        # allocation found under the region's name near the end of its walltime would end part way
        # through. One it found is given back for a fresh one; one already in use stays its user's.
        need = min(15 * 60.0, 0.5 * _sched_seconds(_alloc_walltime(r)))
        while time() < deadline
            nodehost, a = region_place!(r; wait_s = 30)
            if !isempty(nodehost)
                p0 = _placement(r)
                left = p0 === nothing ? Inf : p0.until - time()
                if left < need
                    if held_before
                        note("the node in use has only $(Sweep.format_duration(left)) of walltime left, " *
                             "which the prepare may outlast")
                    else
                        note("job $(p0.job) has only $(Sweep.format_duration(left)) of walltime left; " *
                             "giving it back for a fresh node")
                        region_release!(r); gave_back = time()
                        continue
                    end
                end
                # A node the region already held comes back without its allocation; its route has the job.
                if a === nothing
                    v = via(nodehost); job = v === nothing ? "" : v.job
                    return ("ok", nodehost * (isempty(job) ? "" : " (job $job)") * ", already held")
                end
                p = placement_note(r, a)
                return (p.grown ? "warn" : "ok", p.text)
            end
            p = placement_note(r, a; waited = time() - t0)
            # Just after a give-back the scheduler can still list the job it is ending; ask again.
            if p.state !== :queued && time() - gave_back < 60
                sleep(5); continue
            end
            p.state === :queued || return ("fail", p.text)
            p.text == shown || note(p.text)   # a line when something changed, not one per poll
            shown = p.text
        end
        ("fail", "no node within 30 minutes; the request was left queued")
    end
    got == "ok" || return nothing
    node = region_host(r)
    pro = _region_prologue(r.name)
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
        # With the notebook's worker to start, its start is the runtime's load, timed for real. A node
        # with a different CPU from the one that built the package images recompiles them here.
        worker === nothing && step("Load the worker runtime") do
            t0 = time()
            ok, out = _run_on(node, _prepare_shell(r) * _julia_sh("julia --startup-file=no --project=\$HOME/$_REMOTE_KGATE_ENV " *
                                                    "-e 'using KaimonGate, Revise'"); timeout = 1800.0)
            secs = round(time() - t0; digits = 1)
            ok || return ("fail", first(strip(out), 400))
            measured["runtime_load_s"] = secs
            ("ok", "$(secs)s")
        end
        # A node that sees the login node's home finds the environment just downloaded there, so it
        # only has to compile it; one that does not installs its own.
        installed = get(facts, "home_shared", false) === true && get(measured, "downloaded", false) === true
        _prepare_env!(r, step, measured, ref, node, pro; worker, rebuild_sysimage, rebuild = !installed)
    finally
        if keep_node
            step(() -> ("ok", region_host(r) * (haskey(measured, "worker_start_s") ? " · its worker is up" : "")),
                 "Keep the node for the notebook")
        elseif held_before
            step(() -> ("ok", "$(region_host(r)) was held before the prepare"), "Leave the node as it was")
        else
            step("Give the node back") do
                region_release!(r) ? ("ok", "") : ("warn", "nothing to release")
            end
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
println("pid=", getpid(), " on ", gethostname())
println("image=", unsafe_string(Base.JLOptions().image_file))
if isdefined(Main, :CUDA)
    C = getfield(Main, :CUDA)
    println("cuda=", C.functional(), " devices=", C.functional() ? length(C.devices()) : 0)
    sys = filter(l -> occursin("cuda", lowercase(l)) && startswith(l, "/opt"), Libdl.dllist())
    println("syscuda=", join(sys, " "))
end
"""

# What a prepare's compile was for, kept beside the environment's stamp (`mark`): the environment (its
# stamp without the "compiled" suffix a compile adds), the node's CPU, the options its workers boot
# with (the sysimage among them), and the sources of the packages it develops (`_dev_sources_digest`,
# and Slate's worker package and SDK, which every worker environment develops).
# Before Julia starts, the shell compares them and stops when they match; after a compile, Julia writes
# them. Both read `$SLATE_PC`, which the check sets.
function _precompiled_check_sh(t, mark::AbstractString; sources::AbstractString = "")
    q(p) = (startswith(p, "/") || startswith(p, "~/")) ? Sweep.shq_path(p) : "\"\$HOME/\"" * Sweep.shq(p)
    # A match also marks the stamp compiled, as the compile would have, so a start finds the
    # environment complete rather than building it again.
    st = q(_env_stamp_path(t))
    return _SYSIMAGE_CPU_SH * "; R=\$(cat " * st * " 2>/dev/null); S=\${R%+pc}; " *
           "export SLATE_PC=\"\$S|\$CPU|\$JOPT|" * sources * "\"; " *
           "if [ -n \"\$S\" ] && [ \"\$(cat " * q(mark) * " 2>/dev/null)\" = \"\$SLATE_PC\" ]; then " *
           "[ \"\$R\" = \"\$S\" ] && printf '%s' \"\$S+pc\" > " * st * "; " *
           "echo '@@PRECOMPILED current'; exit 0; fi; "
end
_precompiled_mark_snippet(mark::AbstractString) = """
    let f = raw"$mark"
        f = startswith(f, "/") ? f : joinpath(homedir(), startswith(f, "~/") ? f[3:end] : f)
        write(f, get(ENV, "SLATE_PC", ""))
    end
    """

# Install the reference project's environment where its workers will run, load every package in it
# with timing, and check CUDA when it is among them. On a scheduler region `host` is the granted node;
# elsewhere it is the host itself. The environment stays installed, stamped, for the project's start.
function _prepare_env!(r::Region, step, measured, ref, host, pro; worker = nothing, rebuild_sysimage::Bool = false,
                       rebuild::Bool = true)
    isempty(ref[1]) && return nothing
    name = basename(ref[1])
    t = _region_target(r; origin_env = ref[1])
    rel = startswith(t.project, "~/") ? t.project[3:end] : t.project
    # Installed without compiling: the step below compiles it, once, where the workers run. A node that
    # shares the login node's home finds it there already, sources included.
    got = step("Install $name") do
        rebuild || return ("ok", "downloaded on the login node, which shares its home")
        a = provision_remote!(t, ref[2]; rebuild, precompile = false)
        a === :build && (measured["env_action"] = a)
        ("ok", "")
    end
    got == "fail" && return nothing
    # A region that boots its workers from a sysimage gets it built here, on the node type its workers
    # run on and in their shell, before the packages are compiled against it and the worker starts.
    (r.sysimage || rebuild_sysimage) && step("Build the sysimage") do
        status, detail, m = build_sysimage!(r, t, host; prologue = pro, force = rebuild_sysimage)
        measured["sysimage"] = m
        # Recorded now, not when the prepare ends: the compile, the load and the worker start boot from it.
        get(m, "result", "") in ("built", "current") && _record_sysimage!(r.name, m)
        (status, detail * (r.sysimage ? "" : " · the region does not boot from it until sysimage is on"))
    end
    # Compiled here, where the workers run, against the image they boot, and timed apart from loading:
    # the load time below is what every start pays, which is what the liveness grace is made from. Not
    # run again for the node type, image and environment it last compiled.
    step("Precompile $name") do
        mark = _env_stamp_path(t) * ".pc"
        ok, out = _ssh_julia!(host, "import Pkg; Pkg.activate(joinpath(homedir(), raw\"$rel\")); Pkg.precompile(); " *
                                    "println(\"@@JULIA julia version \", VERSION)\n" * _precompiled_mark_snippet(mark),
                              "precompile $name on $host"; stream = true, jopt = true,
                              setup = t.setup * pro * _sysimage_jopt_sh(t) * "; " *
                                      _precompiled_check_sh(t, mark; sources = _dev_sources_digest(ref[1]) *
                                                                         "." * _payload_sha() * "." * _seb_sha()))
        ok || return ("fail", first(strip(out), 400))   # the step shows its own time
        occursin("@@PRECOMPILED current", out) && return ("ok", "compiled already for this node, image and environment")
        # Compiled now, so a start finds the environment complete and builds nothing.
        m = match(r"@@JULIA (julia version \S+)", out)
        m === nothing || stamp_env_precompiled!(t, ref[2], m.captures[1]) ||
            _rlog("prepare[$(r.name)]: could not record the environment as compiled on $host")
        ("ok", "")
    end
    worker === nothing || return _prepare_in_worker!(step, measured, name, worker)
    step("Load $name") do
        ok, out = _run_on(host, t.setup * pro * _sysimage_jopt_sh(t) * "; " *
                                _julia_sh("julia \$JOPT --startup-file=no --project=\$HOME/$rel -e " * Sweep.shq(_LOAD_CODE));
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
    # Which process loaded them: for a notebook's prepare, the worker its cells then run on.
    pid = get(f, "pid", "")
    isempty(pid) || (measured["worker_pid"] = pid)
    # Whether the process booted from a built sysimage rather than Julia's own.
    img = get(f, "image", "")
    measured["booted_sysimage"] = !isempty(img) && !(basename(img) in ("sys.so", "sys.dylib", "sys.dll"))
    return (status, "loaded in $(measured["env_load_s"])s" * (measured["booted_sysimage"] ? " from the sysimage" : "") *
                    (isempty(pid) ? "" : " · process $pid") *
                    (isempty(cuda) ? "" : " · CUDA functional=$cuda") *
                    (isempty(sys) ? "" : " · CUDA libraries from the system: $(first(sys, 200))"))
end

# The notebook's own worker: started the way its cells would start it, and the packages loaded in it,
# so the first run after preparing finds both done. Its start is the runtime's load time.
function _prepare_in_worker!(step, measured, name, worker)
    # A worker already running booted from whatever image there was then: when this prepare built a new
    # one, the notebook's worker is replaced so it boots from it.
    # So is one whose environment this prepare built anew: it loaded the packages it had.
    fresh = get(get(measured, "sysimage", Dict()), "result", "") == "built" || get(measured, "env_action", :keep) === :build
    # A worker that was already up says nothing about how long a start or a load takes, so the
    # measurements from when it started stand.
    reused = false
    up = step("Start the notebook's worker") do
        t0 = time()
        reused = worker.start(fresh) === false
        reused && return ("ok", "already up")
        measured["worker_start_s"] = measured["runtime_load_s"] = round(time() - t0; digits = 1)
        ("ok", "up in $(measured["worker_start_s"])s")
    end
    up == "ok" || return nothing
    step("Load $name in it") do
        # In a module of its own: the code imports at top level, and its names must not land in the
        # notebook's namespace.
        st, msg = _load_result!(measured, worker.run("Core.eval(Module(:SlatePrepare), Meta.parseall(" * repr(_LOAD_CODE) * "))"))
        reused || return (st, msg)
        delete!(measured, "env_load_s")
        (st, replace(msg, r"^loaded in [0-9.]+s" => "already loaded"))
    end
    return nothing
end

"""
    readiness_check!(t::RemoteTarget; seen = nothing)

On a start, compare what preparing recorded about the region's machine with what its host reports
now, and mark the machine stale when they differ. `seen` is the host's state when the caller already read
it (`_host_state`); otherwise one command reads the stamps. Never blocks the start.
"""
function readiness_check!(t::RemoteTarget; seen = nothing)
    isempty(t.region) && return nothing
    r = region_get(t.region)
    r === nothing && return nothing
    hf = host_facts(r.host)
    want = get(hf, "stamps", nothing)
    (want isa AbstractDict && !isempty(want)) || return nothing
    if seen === nothing
        ok, out = _run_on(t.ssh_host, _STAMP_SCRIPT)
        ok || return nothing
        seen = _parse_probe(out)
    end
    now = _stamps_of(seen)
    diffs = [k for k in keys(now) if String(get(want, k, "")) != String(now[k])]
    stale = isempty(diffs) ? "" : "changed since prepared: " * join(sort(diffs), ", ")
    stale == String(get(hf, "stale", "")) && return nothing
    host_facts_merge!(r.host, Dict{String,Any}("stale" => stale))
    isempty(stale) || _rlog("$(r.host): $stale — prepare it again")
    return nothing
end

# ── Reading it back ──────────────────────────────────────────────────────────────────────────
"The machine's record of `origin_env`'s environment on the kind of node region `r` gets, or `nothing`."
function env_report(r::Region, origin_env::AbstractString)
    isempty(origin_env) && return nothing
    e = get(tested_envs(r.host), Sweep.env_key(origin_env, region_node_type(r)), nothing)
    return e isa AbstractDict ? e : nothing
end

"The machine's tested environments on region `r`'s kind of node, each marked `changed` when it is no longer the one tested."
function region_envs(r::Region)
    depot = region_depot(r); nt = region_node_type(r)
    Dict{String,Any}(k => merge(Dict{String,Any}(e), Dict{String,Any}("changed" => !env_unchanged(e; depot)))
                     for (k, e) in tested_envs(r.host) if e isa AbstractDict && get(e, "node_type", "") == nt)
end

# Whether a tested project's environment is still the one that was tested, in the depot it is in now.
env_unchanged(e::AbstractDict; depot::AbstractString = "") = isdir(String(get(e, "project", ""))) &&
    _env_fingerprint(String(e["project"]), _infra_spec(); depot) == String(get(e, "fingerprint", ""))

"The depot region `r`'s workers use."
region_depot(r::Region) = machine_depot(region_machine(r))

# The record as the page shows it. The machine's part comes along as `site`, with the depot in use, and
# `envs` are the environments tested on this region's kind of node, by it or by anything else there.
function readiness_view(r::Region)
    rec = copy(r.readiness)
    hf = host_facts(r.host)
    isempty(hf) || (delete!(hf, "envs"); rec["site"] = merge(hf, Dict{String,Any}("depot" => region_depot(r))))
    envs = region_envs(r)
    isempty(envs) || (rec["envs"] = envs)
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
    hf = host_facts(r.host)
    stale = String(get(hf, "stale", ""))
    depot = region_depot(r)
    println(io, "prepared $at — ", get(rec, "ok", false) === true ? "ok" : "with failures",
            isempty(stale) ? "" : " — STALE ($stale)")
    pro = String(get(hf, "site_prologue", ""))
    isempty(pro) || println(io, "  site prologue: $pro")
    println(io, "  depot: ", isempty(depot) ? "~/.julia" : depot)
    envs = region_envs(r)
    if !isempty(envs)
        for (_, e) in sort!(collect(envs); by = first)
            c = get(e, "cuda", nothing)
            by = String(get(e, "by", ""))
            println(io, "  tested with $(e["project"])", by == r.name ? "" : " (by $by)", ": loads in $(get(e, "load_s", 0))s",
                    c isa AbstractDict ? ", CUDA functional=$(c["functional"])" : "",
                    e["changed"] ? " (its environment has changed since)" : "")
        end
    end
    g = get(rec, "liveness_grace_s", 0)
    g isa Real && g > 0 && println(io, "  liveness grace from measured loads: $(round(Int, g))s")
    _steps_text(io, get(rec, "steps", Any[]))
    return String(take!(io))
end
