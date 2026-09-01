# ── Named compute targets, kept with the machines rather than in a notebook ──────────────────
#
# A cluster definition — host, scheduler, partition, walltime, where its scratch is — describes a
# MACHINE. It was stored in each notebook's footer, which meant:
#
#   * two notebooks against the same cluster held two copies that drifted,
#   * a definition could not be reused without opening the notebook that had it, and
#   * the same facts were being configured twice, because a region on that cluster needs them too.
#
# So they live here, beside regions, in the same config directory: one definition per cluster, named,
# referenced by a sweep cell's `cluster=<name>` header and by a region's host.
#
# The name is the contract, not the address: a notebook says `cluster=hpc`, and each machine that
# opens it resolves that against its own registry. Which is what makes the same notebook run against
# a laptop's test cluster and a site's real one without editing a cell.

_clusters_path() = joinpath(_slate_config_dir(), "clusters.json")

const _CLUSTERS_LOCK = ReentrantLock()

"Every named compute target this machine knows, as plain dictionaries (the fields vary by kind)."
function clusters_all()::Vector{Dict{String,Any}}
    p = _clusters_path()
    isfile(p) || return Dict{String,Any}[]
    v = try; JSON.parsefile(p); catch; return Dict{String,Any}[]; end
    v isa AbstractVector || return Dict{String,Any}[]
    return Dict{String,Any}[Dict{String,Any}(String(k) => x for (k, x) in d)
                            for d in v if d isa AbstractDict && !isempty(String(get(d, "name", "")))]
end

"One target by name, or `nothing`."
function cluster_get(name::AbstractString)
    n = strip(String(name))
    for c in clusters_all(); String(get(c, "name", "")) == n && return c; end
    return nothing
end

function _write_clusters!(list)
    p = _clusters_path()
    mkpath(dirname(p))
    tmp = p * ".tmp"
    open(io -> JSON.print(io, list), tmp, "w")
    mv(tmp, p; force = true)      # atomic: a reader never sees half a registry
    return nothing
end

# A name is written into a cell header as `cluster=<name>`, so one with a dot or a space could not be
# referenced at all — better rejected here than silently unusable there.
const _CLUSTER_NAME = r"^[A-Za-z_][A-Za-z0-9_]*$"

"""
    cluster_set!(spec) -> Dict

Add or replace a target by its `name`. The spec is stored as given — the fields a SLURM target needs
are not the fields a PBS one does, and a schema here would have to be rewritten for every scheduler.
"""
function cluster_set!(spec::AbstractDict)
    n = strip(String(get(spec, "name", "")))
    isempty(n) && error("a cluster needs a name")
    occursin(_CLUSTER_NAME, n) ||
        error("cluster name `$n` must be a plain identifier — a cell references it as `cluster=$n`")
    d = Dict{String,Any}(String(k) => v for (k, v) in spec if !isempty(strip(string(v))))
    d["name"] = n
    return lock(_CLUSTERS_LOCK) do
        list = clusters_all()
        i = findfirst(c -> String(get(c, "name", "")) == n, list)
        i === nothing ? push!(list, d) : (list[i] = d)
        _write_clusters!(list)
        d
    end
end

"Forget a target. Returns whether one was removed."
function cluster_delete!(name::AbstractString)
    n = strip(String(name))
    return lock(_CLUSTERS_LOCK) do
        list = clusters_all()
        i = findfirst(c -> String(get(c, "name", "")) == n, list)
        i === nothing && return false
        deleteat!(list, i)
        _write_clusters!(list)
        true
    end
end
