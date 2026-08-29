# The batch-fabric task runner: the process a scheduler actually starts on a compute node.
#
# It is deliberately stateless. Given a CAS root and a chunk key it reads a descriptor, restores
# each shard's inputs from the store, runs the shard, and writes the result back as an ORDINARY
# memo entry. There is no gate, no ZMQ, no port, no tunnel, and no connection back to the hub: a
# task communicates only through the shared filesystem. That is what lets a sweep survive the hub
# being closed for a day.
#
# Shard results are written in the SAME manifest schema the worker's memoization uses, so they are
# not a parallel universe: `MemoStore.gc` refcounts their blobs, `pack`/`unpack` carry them into a
# standalone notebook, pins protect them, and `entry_bytes` prices them, all with no batch-specific
# code. Extra keys (status, ms, ran_on, artifacts) ride alongside and are ignored by readers that
# do not know about them.
#
# Idempotence is the whole design. A shard whose manifest already exists is skipped, so re-running
# a chunk is free, a requeued or preempted job resumes rather than repeats, and re-submitting a
# whole sweep costs nothing for the shards that already landed.

# `Base.include(@__MODULE__, …)` rather than a bare `include`: this file is loaded into a notebook's
# module as well as into Main, and a module built programmatically (as a notebook's is) has no
# `include` of its own.
if !isdefined(@__MODULE__, :MemoStore)
    Base.include(@__MODULE__, joinpath(@__DIR__, "memostore.jl"))
end

module SlateTask

import Serialization
import TOML
import Dates

const MemoStore = parentmodule(@__MODULE__).MemoStore

# The same value↔bytes codecs the memo layer uses. `raw` writes an isbits array as a
# self-describing header plus its bytes: the blob mmaps, so a slice reads only the pages it touches,
# and the header answers "what is in here?" without opening the data at all. Stdlib-only (`Mmap`;
# Arrow is soft-detected), so it loads in a runner that carries no dependencies.
Base.include(@__MODULE__, joinpath(@__DIR__, "memocodecs.jl"))

# Everything a task process needs beside it. Declared here, next to the includes it mirrors, so
# provisioning a cluster cannot silently ship a runner without one of its own parts.
const PAYLOAD_FILES = ("memostore.jl", "memocodecs.jl", "slatetask.jl")

const KIND_CHUNK = "slate-chunk"
const KIND_SHARD = "slate-shard"

# ── Artifacts ────────────────────────────────────────────────────────────────────────────────
# A shard may produce FILES as well as a return value: a solver's output, a NetCDF, a plot. Those
# go into the CAS like any other blob and are recorded on the shard's manifest, which is what keeps
# them alive through `gc` (see `_manifest_blobs`). The value comes back to the notebook eagerly;
# artifacts stay on the cluster as references until something asks for them.
const _ARTIFACTS = Ref{Union{Nothing,Vector{Dict{String,Any}}}}(nothing)
const _ROOT = Ref{String}("")

"""
    artifact!(path; name = basename(path)) -> String

Register a file this shard produced into the store, returning its content hash. Callable only from
inside a running shard.
"""
function artifact!(path::AbstractString; name::AbstractString = basename(path))
    acc = _ARTIFACTS[]
    acc === nothing && error("artifact!() called outside a running shard")
    isfile(path) || error("artifact!(): no such file: $path")
    h, n = MemoStore.put_blob(io -> open(p -> write(io, p), path, "r"), _ROOT[])
    push!(acc, Dict{String,Any}("name" => String(name), "blob" => h, "bytes" => n))
    return h
end

# ── Descriptor construction ──────────────────────────────────────────────────────────────────

_put_jls(root, v) = MemoStore.put_blob(io -> Serialization.serialize(io, v), root)
_put_txt(root, s) = MemoStore.put_blob(io -> write(io, s), root)

function _get_jls(root, h)
    found, v = MemoStore.with_blob(io -> Serialization.deserialize(io), root, h)
    found || error("blob missing from store: $h")
    return v
end

function _get_txt(root, h)
    found, s = MemoStore.with_blob(io -> read(io, String), root, h)
    found || error("blob missing from store: $h")
    return s
end

"""
    write_chunk!(root, chunk; fn_src, params, keys, setup_src = "", captures = Dict()) -> chunk

Write the descriptor for one chunk of a sweep. `params` and `keys` are parallel: `keys[i]` is the
shard key that `params[i]` produces under `fn_src`.

The closure travels as SOURCE, not as a serialized function. A serialized closure can only be
revived by a process that already has its defining code loaded, which a fresh batch job does not.
Source plus explicitly serialized captures is also what makes the shard key honest: the same text
and the same captured values give the same key on any machine.
"""
function write_chunk!(root::AbstractString, chunk::AbstractString;
                      fn_src::AbstractString, params::AbstractVector,
                      keys::AbstractVector, setup_src::AbstractString = "",
                      captures::AbstractDict = Dict{String,Any}(),
                      summary_src::AbstractString = "")
    length(params) == length(keys) ||
        throw(ArgumentError("params and keys must be the same length"))
    fn_h, _ = _put_txt(root, fn_src)
    setup_h = isempty(setup_src) ? "" : first(_put_txt(root, setup_src))
    # Travels as SOURCE for the same reason the body does — a fresh process cannot revive a closure.
    sum_h = isempty(summary_src) ? "" : first(_put_txt(root, summary_src))
    caps = Dict{String,Any}[]
    for (name, v) in captures
        h, n = _put_jls(root, v)
        push!(caps, Dict{String,Any}("name" => String(name), "blob" => h, "bytes" => n))
    end
    shards = Dict{String,Any}[]
    for (k, p) in zip(keys, params)
        h, _ = _put_jls(root, p)
        push!(shards, Dict{String,Any}("key" => String(k), "arg" => h))
    end
    MemoStore.write_manifest(root, chunk, Dict{String,Any}(
        "kind" => KIND_CHUNK,
        "created" => round(Int, time()),
        "julia" => string(VERSION),
        "fn" => fn_h,
        "setup" => setup_h,
        "summary" => sum_h,
        "captures" => caps,
        "shards" => shards))
    return chunk
end

# ── Status ───────────────────────────────────────────────────────────────────────────────────
# One small file per chunk, written by temp-plus-rename. The hub lists ONE directory to learn the
# state of a whole sweep, which is a single metadata operation regardless of shard count. Appending
# to a log instead would be invisible to a reader under NFS close-to-open consistency, and one file
# per shard would put a metadata storm on a filesystem shared by the whole site.
status_dir(root::AbstractString) = joinpath(root, "status")
status_path(root::AbstractString, chunk::AbstractString) =
    joinpath(status_dir(root), chunk * ".toml")

function write_status!(root::AbstractString, chunk::AbstractString, d::AbstractDict)
    dir = status_dir(root)
    mkpath(dir)
    tmp = tempname(dir)
    try
        open(io -> TOML.print(io, Dict{String,Any}(String(k) => v for (k, v) in d)), tmp, "w")
        mv(tmp, status_path(root, chunk); force = true)
    catch
        try; rm(tmp; force = true); catch; end
        rethrow()
    end
    return nothing
end

read_status(root::AbstractString, chunk::AbstractString) =
    (p = status_path(root, chunk); isfile(p) ? (try; TOML.parsefile(p); catch; nothing; end) : nothing)

# Where this task is running, for the DAG's provenance badges. SLURM exports the job and array
# element; without them (a local ExecLauncher run) the hostname alone is the answer.
function _ran_on()
    host = try; gethostname(); catch; "?"; end
    jid = get(ENV, "SLURM_JOB_ID", "")
    aid = get(ENV, "SLURM_ARRAY_TASK_ID", "")
    isempty(jid) && return host
    return isempty(aid) ? "$host/$jid" : "$host/$jid[$aid]"
end

# ── Running ──────────────────────────────────────────────────────────────────────────────────

"A shard is done when its manifest is present. The store is the source of truth, not a job record."
is_done(root::AbstractString, key::AbstractString) = MemoStore.read_manifest(root, key) !== nothing

# What a result IS, recorded beside it so the question can be answered without reading it: the
# concrete type, the dimensions, and the stored size. This is what lets a notebook describe a sweep's
# output — and decide whether it wants to fetch any of it — at the cost of a manifest read.
function _shape_of(v, bytes::Integer)
    d = Dict{String,Any}("type" => string(typeof(v)), "bytes" => Int(bytes))
    if v isa AbstractArray
        d["dims"] = collect(Int, size(v))
        d["eltype"] = string(eltype(v))
        d["length"] = length(v)
    end
    return d
end

# A summary rides in every manifest read, so it holds facts rather than results: a number, a bool, a
# short string, a small vector, or a named group of those (`(; loss, acc, converged)`). Anything
# larger is dropped rather than truncated — a half-written value is worse than an absent one.
_toml_scalar(x) = x isa Real || x isa Bool || x isa AbstractString
_toml_value(x) = _toml_scalar(x) ? (x isa AbstractString ? String(x) : x) :
                 (x isa AbstractVector && length(x) <= 64 && all(_toml_scalar, x)) ? collect(x) :
                 nothing

function _summarize(f, value)
    v = f === nothing ? value : (try; Base.invokelatest(f, value); catch; return nothing; end)
    flat = _toml_value(v)
    flat === nothing || return flat
    # A NamedTuple or Dict of facts — the shape a run naturally reports (loss, accuracy, a flag).
    pairs = v isa NamedTuple ? zip(string.(keys(v)), values(v)) :
            v isa AbstractDict ? zip(string.(keys(v)), values(v)) : nothing
    pairs === nothing && return nothing
    out = Dict{String,Any}()
    for (k, x) in pairs
        y = _toml_value(x)
        y === nothing || (out[k] = y)
    end
    return isempty(out) ? nothing : out
end

"""
    run_chunk(root, chunk; force = false) -> NamedTuple

Run every shard in `chunk` that is not already in the store. Returns
`(; total, ran, skipped, failed)`.

A shard that throws is recorded as a failed entry and the chunk continues: with thousands of
shards, some failing is the normal case, and one bad parameter must not cost the whole chunk.
"""
function run_chunk(root::AbstractString, chunk::AbstractString; force::Bool = false)
    d = MemoStore.read_manifest(root, chunk)
    d === nothing && error("no chunk descriptor for key $chunk under $root")
    get(d, "kind", "") == KIND_CHUNK || error("manifest $chunk is not a $KIND_CHUNK")

    shards = get(d, "shards", Any[])
    total = length(shards)
    ran = 0; skipped = 0; failed = 0
    started = round(Int, time())

    status(cur) = write_status!(root, chunk, Dict{String,Any}(
        "chunk" => chunk, "total" => total, "done" => ran + skipped + failed,
        "ran" => ran, "skipped" => skipped, "failed" => failed,
        "current" => cur, "ran_on" => _ran_on(), "started" => started,
        "ts" => round(Int, time())))

    status("")

    # One fresh module per chunk holds the setup and the closure. Shards share it, so a `using` or
    # an expensive constant is paid once per chunk rather than once per shard, which is much of the
    # point of chunking in the first place.
    mod = Module(:SlateShard)
    Core.eval(mod, :(using Base))
    # The shard module starts empty, so anything a closure needs has to be put there explicitly:
    # its captures, whatever `setup_src` defines, and the runner's own API. Without this a shard
    # calling `artifact!` just raises UndefVarError and is recorded as a failed shard, which is
    # a confusing way to learn that a name is missing.
    Core.eval(mod, Expr(:(=), :SlateTask, @__MODULE__))
    Core.eval(mod, Expr(:(=), :artifact!, artifact!))
    setup_h = String(get(d, "setup", ""))
    if !isempty(setup_h)
        Core.eval(mod, Meta.parseall(_get_txt(root, setup_h)))
    end
    for c in get(d, "captures", Any[])
        c isa AbstractDict || continue
        Core.eval(mod, Expr(:(=), Symbol(c["name"]), _get_jls(root, String(c["blob"]))))
    end
    fn = Core.eval(mod, Meta.parse(_get_txt(root, String(d["fn"]))))
    # The per-unit SUMMARY: a small value recorded in the manifest beside `ms` and `status`, so the
    # notebook's live view can plot progress WITHOUT reading a single result blob. Computed here, on
    # the compute node, because the whole point is that the big thing never travels — a sweep whose
    # units return gigabyte fields must still cost only its manifests to watch.
    sum_h = String(get(d, "summary", ""))
    summarize = isempty(sum_h) ? nothing : Core.eval(mod, Meta.parse(_get_txt(root, sum_h)))

    for s in shards
        s isa AbstractDict || continue
        key = String(get(s, "key", ""))
        isempty(key) && continue
        if !force && is_done(root, key)
            skipped += 1
            status(key)
            continue
        end
        arg = _get_jls(root, String(s["arg"]))
        _ARTIFACTS[] = Dict{String,Any}[]
        _ROOT[] = root
        t0 = time()
        local ok, value, err
        try
            value = Base.invokelatest(fn, arg)
            ok = true
        catch e
            # The traceback matters more than the exception here: the user is looking at one of
            # thousands of shards and needs to know where it went wrong, not just that it did.
            err = sprint(showerror, e, catch_backtrace())
            ok = false
        end
        ms = (time() - t0) * 1000
        arts = _ARTIFACTS[]
        _ARTIFACTS[] = nothing

        m = Dict{String,Any}(
            "kind" => KIND_SHARD, "created" => round(Int, time()), "julia" => string(VERSION),
            "chunk" => chunk, "ms" => ms, "ran_on" => _ran_on(),
            "status" => ok ? "ok" : "error", "artifacts" => arts)
        if ok
            # The summary rides in every manifest read, so it is limited to small TOML-carryable
            # values; anything else is dropped rather than stringified.
            sv = _summarize(summarize, value)
            sv === nothing || (m["summary"] = sv)
            codec = _codec_pick(value)
            h, n = MemoStore.put_blob(io -> _codec_encode(io, codec, value), root)
            m["bindings"] = [Dict{String,Any}("name" => "result", "codec" => codec,
                                              "blob" => h, "bytes" => n)]
            m["shape"] = _shape_of(value, n)
            ran += 1
        else
            m["bindings"] = Any[]
            m["error"] = err
            failed += 1
        end
        MemoStore.write_manifest(root, key, m)
        status(key)
    end

    status("")
    return (; total, ran, skipped, failed)
end

"""
    result(root, key) -> (found, status, value)

Read one shard back. `status` is "ok", "error", or "" when the shard has not run.
"""
function result(root::AbstractString, key::AbstractString)
    d = MemoStore.read_manifest(root, key)
    d === nothing && return (false, "", nothing)
    st = String(get(d, "status", ""))
    st == "ok" || return (true, st, get(d, "error", nothing))
    bs = get(d, "bindings", Any[])
    isempty(bs) && return (true, st, nothing)
    return (true, st, load_binding(root, bs[1]))
end

"""
    load_binding(root, binding; zc = false) -> value

Materialize one stored binding through the codec it was written with. `zc` mmaps the blob read-only
instead of copying — safe only while nothing mutates the result.
"""
function load_binding(root::AbstractString, b::AbstractDict; zc::Bool = false)
    codec = String(get(b, "codec", "jls"))
    path = MemoStore.blob_path(root, String(b["blob"]))
    return _codec_decode(codec, path, zc)
end

"Every artifact a shard registered, as `(name, blob, bytes)` rows. Blobs stay where they are."
function artifacts(root::AbstractString, key::AbstractString)
    d = MemoStore.read_manifest(root, key)
    d === nothing && return Dict{String,Any}[]
    return [x for x in get(d, "artifacts", Any[]) if x isa AbstractDict]
end

"""
    main(args = ARGS)

Entry point for the process a scheduler starts: `julia --project=<env> slatetask.jl <root> <chunk>`.
Exits nonzero only when the chunk itself could not run; individual shard failures are recorded in
the store and are not an error at this level.
"""
function main(args = ARGS)
    length(args) >= 2 ||
        (println(stderr, "usage: slatetask.jl <cas-root> <chunk-key>..."); return 2)
    root = String(args[1])
    # Several chunks per process, run one after another. A process is expensive (a whole Julia
    # start plus package loads), so the alternative — one process per chunk — is both slow and,
    # run locally, a fast route to exhausting memory.
    for chunk in args[2:end]
        r = run_chunk(root, String(chunk))
        println("chunk $(chunk): $(r.ran) ran, $(r.skipped) skipped, $(r.failed) failed of $(r.total)")
    end
    return 0
end

end # module SlateTask
