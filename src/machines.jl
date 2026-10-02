# ── Machines ─────────────────────────────────────────────────────────────────────────────────
# A machine is an entry in the compute registry (`clusters.json`): what is true of a host whatever
# runs on it. Regions (interactive workers) and job cells (batch tasks) both name one, so a site's
# Julia, depot and shell setup are configured once and every Julia started there gets them.
#
# What a machine IS (its entry) is kept apart from what preparing it FOUND (its host facts). The facts
# describe the login host, so they are keyed by it: two entries for one cluster (its CPU and its GPU
# partitions, say) share them, as they share the machine.

struct Machine
    name::String       # "" for the implicit machine of a region that names a host directly
    host::String       # ssh alias of the login (or only) node
    kind::Symbol       # :slurm | :pbs | :exec (a plain host, no scheduler)
    account::String
    julia::String      # path to a julia binary; "" = juliaup at the hub's version, installed if missing
    depot::String      # Julia depot; "" = automatic (the site's scratch when preparing finds one)
    prologue::String   # the user's shell setup, run before every Julia here
end

_machine_kind(k) = (s = lowercase(strip(String(k))); s in ("slurm", "pbs") ? Symbol(s) : :exec)

machine_from(d::AbstractDict) = Machine(String(get(d, "name", "")), String(get(d, "host", "")),
    _machine_kind(get(d, "kind", "slurm")), String(get(d, "account", "")),
    String(strip(String(get(d, "julia", "")))), _home_tilde(strip(String(get(d, "depot", "")))),
    String(get(d, "prologue", "")))

# `$HOME/x` and `~/x` are the same place; the shell quoting used everywhere expands only `~/`.
_home_tilde(p::AbstractString) = startswith(p, "\$HOME/") ? "~/" * p[7:end] : String(p)

"The machine named `name`, or `nothing`."
function machine_get(name::AbstractString)
    d = cluster_get(name)
    return d === nothing ? nothing : machine_from(d)
end

# A region's scheduler, in the machine's terms and back.
_kind_of_scheduler(s::Symbol) = s === :none ? :exec : s
_scheduler_of_kind(k::Symbol) = k === :exec ? :none : k

"""
    region_machine(r) -> Machine

The machine region `r` runs on: the one it names, or, for a region that names a host directly, an
implicit machine on that host with every setting automatic.
"""
function region_machine(r)
    m = isempty(r.machine) ? nothing : machine_get(r.machine)
    m === nothing || return m
    return Machine("", r.host, _kind_of_scheduler(r.scheduler), r.account, "", "", "")
end

# ── What a machine asks the scheduler for ───────────────────────────────────────────────────
# Scheduler options as one structured map, the one a region carries: the entry's `options`, plus
# what an older entry wrote as free text (`directives`, a flag per line) or in its own `qos` field.
function machine_options(d::AbstractDict)
    out = _region_options_of(d)
    for line in split(String(get(d, "directives", "")), '\n')
        s = replace(strip(line), r"^#(SBATCH|PBS)\s+" => "")
        m = match(r"^--([A-Za-z0-9_-]+)(?:=(.*))?$", s)
        m === nothing && continue
        haskey(out, m.captures[1]) || (out[m.captures[1]] = something(m.captures[2], ""))
    end
    q = strip(String(get(d, "qos", "")))
    (isempty(q) || haskey(out, "qos")) || (out["qos"] = q)
    return out
end

# The shape fields a region takes from its machine when it leaves them empty.
const _SHAPE_FIELDS = ("partition", "walltime", "mem", "gpus", "account")

# A machine is a region of its own name: its shape, and every interactive setting at its default
# unless the entry gives one. Editing it saves a region that stores only what was changed.
const _MACHINE_REGION_KEYS = ("transport", "idle_release", "idle_warn", "liveness_grace", "data_root",
                              "threads", "sysimage", "warm")
_machine_region_dict(d::AbstractDict) =
    merge(Dict{String,Any}(k => d[k] for k in _MACHINE_REGION_KEYS if haskey(d, k)),
          Dict{String,Any}("name" => String(d["name"]), "machine" => String(d["name"])))

# A batch entry's shape for the cell that names it: scheduler options become the resource keys the
# job script spells (`constraint`, `qos`, `gres`, …), and anything the script has no key for goes in
# as a flag of its own. The entry's own fields win over an option naming the same setting.
function _shape_into_entry!(e::AbstractDict, opts::AbstractDict)
    flags = String[]
    for (k, v) in sort!(collect(opts); by = first)
        key = replace(String(k), '-' => '_')
        if Symbol(key) in Sweep._ATTR_RESOURCES && !isempty(strip(String(v)))
            isempty(strip(string(get(e, key, "")))) && (e[key] = String(v))
        else
            push!(flags, isempty(strip(String(v))) ? "--" * String(k) : "--" * String(k) * "=" * String(v))
        end
    end
    delete!(e, "options"); delete!(e, "qos")
    isempty(flags) ? delete!(e, "directives") : (e["directives"] = join(flags, "\n"))
    haskey(opts, "qos") && (e["qos"] = String(opts["qos"]))
    return e
end

"""
    clusters_resolved() -> Vector{Dict}

Every machine entry with what Julia started there needs added: `_setup`, the machine's shell
(`machine_setup`), and `_depot`. Entries go to a notebook's worker this way because a worker has no
registry or host facts of its own, and batch tasks it submits must start in the same shell.
"""
function clusters_resolved()
    out = Dict{String,Any}[_resolved_entry(d) for d in clusters_all()]
    # A region on a machine is a target too: the machine's entry with the region's shape over it, so
    # `cluster=gpu_shared` sends a sweep where `region=gpu_shared` sends a worker.
    have = Set(String(d["name"]) for d in out)
    for r in regions()
        (isempty(r.machine) || r.name in have) && continue
        base = cluster_get(r.machine); base === nothing && continue
        e = Dict{String,Any}(base)
        e["name"] = r.name
        for k in _SHAPE_FIELDS
            v = String(getfield(r, Symbol(k))); isempty(v) || (e[k] = v)
        end
        r.cpus > 0 && (e["cpus"] = string(r.cpus))
        # The region's options over the machine's, before they become fields: once one is a field,
        # an option naming the same setting no longer replaces it.
        push!(out, _resolved_entry(e; options = merge(machine_options(base), r.options)))
    end
    return out
end
cluster_get_resolved(name::AbstractString) = (d = cluster_get(name); d === nothing ? nothing : _resolved_entry(d))

function _resolved_entry(d::AbstractDict; options = machine_options(d))
    m = machine_from(d)
    isempty(m.host) && return Dict{String,Any}(d)            # this machine: nothing to set up
    e = _shape_into_entry!(Dict{String,Any}(d), options)
    return merge(e, Dict{String,Any}("_setup" => machine_setup(m), "_depot" => machine_depot(m),
        # The environments ready on this machine's nodes (`env_readiness`): a sweep submits only these.
        "_tested" => join(ready_envs(m.host; depot = machine_depot(m)), ",")))
end

# ── Environments tested on a machine ────────────────────────────────────────────────────────
# One record per project and kind of node, kept with the machine's host: what loaded the project's
# environment on those nodes, when, how long it took, and the fingerprint of the environment it
# loaded. A region's prepare writes it and so does a sweep's test task, because a region worker and a
# sweep task run in the same environment in the same shell. `env_readiness` reads it, and is the only
# thing that decides whether work may start there: a region's first worker, a sweep's submission, and
# the card that says a sweep is held.

"The kind of node a region's workers get (`Sweep.node_type`)."
region_node_type(r) = Sweep.node_type(r.partition, get(r.options, "constraint", ""))

"Every environment tested on `host`'s nodes: `Sweep.env_key` → record."
function tested_envs(host::AbstractString)
    _migrate_env_records!(host)
    e = get(host_facts(host), "envs", nothing)
    return e isa AbstractDict ? Dict{String,Any}(e) : Dict{String,Any}()
end

"""
    record_env_test!(host, project, nodetype; by, status, depot, kw...)

Record that `project`'s environment was loaded on `host`'s `nodetype` nodes, by a region's prepare
(`by` = its name) or a test task. `kw` are the measurements (`load_s`, `cuda`, `report`, …). Replaces
the earlier record for the same project and kind of node.
"""
function record_env_test!(host::AbstractString, project::AbstractString, nodetype::AbstractString;
                          by::AbstractString, status::AbstractString, depot::AbstractString, kw...)
    rec = Dict{String,Any}("project" => String(project), "node_type" => String(nodetype), "by" => String(by),
        "status" => String(status), "depot" => String(depot), "tested_at" => time(),
        "fingerprint" => _env_fingerprint(String(project), _infra_spec(); depot = String(depot)))
    for (k, v) in kw; rec[String(k)] = v; end
    lock(_HOST_FACTS_LOCK) do
        envs = tested_envs(host)
        envs[Sweep.env_key(project, nodetype)] = rec
        host_facts_merge!(host, Dict{String,Any}("envs" => envs))
    end
    return rec
end

"""
    env_readiness(host, project, nodetype; depot) -> String

`""` when `project`'s environment may start work on `host`'s `nodetype` nodes, with `depot` as the
depot it would load from; otherwise why not. The machine's site changed since it was prepared; the
project never loaded on that kind of node there, or failed to; or its packages, or the depot, changed
since it did. With no project, only whether the machine was ever prepared.
"""
function env_readiness(host::AbstractString, project::AbstractString, nodetype::AbstractString;
                       depot::AbstractString = "")
    hf = host_facts(host)
    stale = String(get(hf, "stale", ""))
    isempty(stale) || return stale
    isempty(project) && return isempty(hf) ? "not prepared" : ""
    e = get(tested_envs(host), Sweep.env_key(project, nodetype), nothing)
    e isa AbstractDict || return isempty(hf) ? "not prepared" : "not tested on " * _node_words(nodetype)
    get(e, "status", "") in ("ok", "warn") || return "its last test failed"
    env_unchanged(e; depot) || return "packages changed since tested"
    return ""
end

_node_words(nodetype) = (p = split(nodetype, '/'; limit = 2);
    join(filter(!isempty, [String(p[1]), length(p) > 1 ? String(p[2]) : ""]), " ") * (all(isempty, p) ? "its nodes" : " nodes"))

"The tested environments that are ready now on `host`, as `Sweep.env_key`s."
ready_envs(host::AbstractString; depot::AbstractString = "") =
    sort!([k for (k, e) in tested_envs(host)
           if e isa AbstractDict && env_readiness(host, String(get(e, "project", "")),
                                                  String(get(e, "node_type", "")); depot) == ""])

# Records written before there was one per machine: a region kept its own, keyed by project alone,
# and a test task kept another without a fingerprint. Moved here once; a test task's record takes the
# environment as it is now, which is the one it was built from.
const _ENV_MIGRATED = Set{String}()
const _ENV_MIGRATE_LOCK = ReentrantLock()
function _migrate_env_records!(host::AbstractString)
    lock(_ENV_MIGRATE_LOCK) do
        String(host) in _ENV_MIGRATED && return
        push!(_ENV_MIGRATED, String(host))
        hf = host_facts(host)
        envs = get(hf, "envs", nothing); envs = envs isa AbstractDict ? Dict{String,Any}(envs) : Dict{String,Any}()
        old = get(hf, "batch", nothing)
        had = [r for r in regions() if r.host == host && get(r.readiness, "envs", nothing) isa AbstractDict]
        (old isa AbstractDict || !isempty(had)) || return
        if old isa AbstractDict
            depot = String(get(hf, "depot", ""))
            for (k, v) in old
                (v isa AbstractDict && occursin('|', k)) || continue
                proj = String(get(v, "project", "")); isdir(proj) || continue
                envs[k] = Dict{String,Any}("project" => proj, "node_type" => String(last(split(k, '|'; limit = 2))),
                    "by" => "test task", "status" => get(v, "status", "ok"), "depot" => depot,
                    "tested_at" => get(v, "prepared_at", 0), "fingerprint" => _env_fingerprint(proj, _infra_spec(); depot),
                    "load_s" => get(v, "load_s", 0.0), "precompile_s" => get(v, "precompile_s", 0.0),
                    "cuda" => get(v, "cuda", nothing), "report" => get(v, "report", ""))
            end
        end
        for r in had, (pk, v) in r.readiness["envs"]
            v isa AbstractDict || continue
            k = String(pk) * "|" * region_node_type(r)
            haskey(envs, k) && continue
            envs[k] = merge(Dict{String,Any}(v), Dict{String,Any}("node_type" => region_node_type(r), "by" => r.name,
                "depot" => region_depot(r), "tested_at" => get(v, "prepared_at", 0)))
        end
        lock(_HOST_FACTS_LOCK) do
            cur = host_facts(host); delete!(cur, "batch"); cur["envs"] = envs
            host_facts_set!(host, cur)
        end
        for r in had
            rec = Dict{String,Any}(r.readiness); delete!(rec, "envs")
            try; region_set!(r.name; readiness = rec); catch; end
        end
    end
    return nothing
end

"""
    region_own(name) -> Dict

What region `name` sets itself, as stored (empty for a machine's own region that was never edited).
"""
function region_own(name::AbstractString)
    i = findfirst(x -> x.name == _fold_region(name), _regions_stored())
    i === nothing && return Dict{String,Any}()
    return Dict{String,Any}(_region_to_dict(_regions_stored()[i]))
end

"What region `r` takes from its machine when it sets nothing itself; empty for a region with none."
function region_inherits(r)
    isempty(r.machine) && return Dict{String,Any}()
    m = cluster_get(r.machine); m === nothing && return Dict{String,Any}()
    out = Dict{String,Any}(k => String(string(get(m, k, ""))) for k in _SHAPE_FIELDS)
    out["cpus"] = _asint(get(m, "cpus", 0))
    out["submit"] = _submit_of(get(m, "submit", ""))
    out["options"] = machine_options(m)
    return out
end

# ── Host facts ───────────────────────────────────────────────────────────────────────────────
# What preparing found on a login host: Julia, the default modules, a module that has to go before
# CUDA.jl loads, the scratch filesystem and the depot automatic resolves to there, and the steps that
# found them. A start compares the stamps with what the host reports and marks the facts stale when
# they differ. Kept apart from the registry, which is configuration the user writes.
_host_facts_path() = joinpath(_slate_config_dir(), "host_facts.json")
const _HOST_FACTS_LOCK = ReentrantLock()

function _host_facts_all()
    p = _host_facts_path()
    isfile(p) || return Dict{String,Any}()
    d = try; JSON.parsefile(p); catch; return Dict{String,Any}(); end
    return d isa AbstractDict ? Dict{String,Any}(d) : Dict{String,Any}()
end

"What preparing found on `host`; empty when it has not been prepared."
function host_facts(host::AbstractString)
    d = get(_host_facts_all(), String(host), nothing)
    return d isa AbstractDict ? Dict{String,Any}(d) : Dict{String,Any}()
end

"Merge `kv` into what is recorded for `host`."
host_facts_merge!(host::AbstractString, kv::AbstractDict) =
    lock(_HOST_FACTS_LOCK) do; host_facts_set!(host, merge(host_facts(host), Dict{String,Any}(kv))); end

"Replace what is recorded for `host` (an empty dict forgets it)."
function host_facts_set!(host::AbstractString, facts::AbstractDict)
    lock(_HOST_FACTS_LOCK) do
        all = _host_facts_all()
        isempty(facts) ? delete!(all, String(host)) : (all[String(host)] = Dict{String,Any}(facts))
        p = _host_facts_path(); mkpath(dirname(p))
        tmp = p * ".tmp"
        write(tmp, JSON.json(all, 2)); mv(tmp, p; force = true)
    end
    return nothing
end

# ── The depot ────────────────────────────────────────────────────────────────────────────────
# A shared home is slow to load packages from: every cache check is a metadata lookup on a network
# filesystem, warm or not. Scratch is not. Automatic means scratch when the site has one; until a
# prepare has looked, the host's default (`~/.julia`). A prepare records what it resolved as soon as it
# has, so the rest of that prepare already runs in it.

_is_default_depot(d::AbstractString) = rstrip(d, '/') in ("~/.julia", "\$HOME/.julia")

"The depot Julia on machine `m` uses; \"\" is the host's default."
function machine_depot(m::Machine)
    isempty(m.depot) || return _is_default_depot(m.depot) ? "" : m.depot
    return String(get(host_facts(m.host), "depot", ""))
end

# Where automatic puts the depot on a host whose scratch is `scratch`.
_auto_depot(scratch::AbstractString) = isempty(strip(scratch)) ? "" : rstrip(strip(scratch), '/') * "/.julia-slate"

# ── The shell every Julia on a machine starts in ─────────────────────────────────────────────
"""
    machine_setup(m) -> String

The shell run before any Julia on machine `m`, ready to prefix a command: the julia to use on PATH,
the depot, the module fix preparing found, and the user's prologue. Empty when there is nothing to set.
"""
function machine_setup(m::Machine)
    parts = String[]
    # juliaup's launcher, or the directory of the julia the machine names, first on PATH.
    push!(parts, isempty(m.julia) ? "export PATH=\"\$HOME/.juliaup/bin:\$PATH\"" :
                 "export PATH=" * Sweep.shq_path(dirname(m.julia)) * ":\"\$PATH\"")
    d = machine_depot(m)
    # The trailing `:` keeps the bundled depots after it, where the standard library's caches are;
    # without it every stdlib is compiled again into `d`. juliaup keeps its own installs under the
    # first depot unless told otherwise, so it is pointed back home.
    isempty(d) || push!(parts, "export JULIA_DEPOT_PATH=" * Sweep.shq_path(d) *
                               ": JULIAUP_DEPOT_PATH=\"\$HOME/.julia\"")
    pre = filter(!isempty, [String(strip(String(get(host_facts(m.host), "site_prologue", "")))),
                            String(strip(m.prologue))])
    s = join(parts, "; ") * "; "
    return isempty(pre) ? s : s * "{ " * join(pre, " ; ") * " ; } && "
end
