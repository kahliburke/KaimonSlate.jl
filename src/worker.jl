# Per-notebook gate worker payload (Phase 2). Loaded *standalone* into a worker
# Julia process pinned to the notebook's project (`julia --project=<nb project>`,
# with KaimonGate on LOAD_PATH). It runs KaimonGate as a TCP gate exposing capture
# tools; the KaimonSlate extension drives it over the gate via `:tool_call`.
#
# This is NOT part of `using KaimonSlate` — the extension server never loads it,
# and KaimonSlate gains no KaimonGate dependency. Only the worker process loads it,
# via `include(".../worker.jl")` in its boot script. It shares `capture.jl` with
# the engine, so there is exactly one capture implementation.

module SlateWorker

import KaimonGate
import Pkg                                   # project dep listing for eager docs auto-index

# The enclosing/parent project dir stacked behind this notebook env on LOAD_PATH (set by
# the boot script; "" when the notebook is detached). Used to attribute package provenance
# — which deps are notebook-specific adds vs. inherited from the parent project.
const PARENT_PROJECT = Ref("")

# Minimal ECharts marker so notebooks can `echart(opt)`. Only the struct + helper
# live here (no JSON); the server JSON-encodes the option Dict. `capture.jl`
# detects `value isa EChart` and ships back the raw Dict.
struct EChart
    option::Any
end
echart(option::AbstractDict) = EChart(Dict{String,Any}(string(k) => v for (k, v) in option))

include(joinpath(@__DIR__, "echarts_dsl.jl")) # echart(:line,…)/series DSL (shared with the engine)
include(joinpath(@__DIR__, "animation.jl")) # animate(frames;…) → Animation (used by capture.jl; shared)
include(joinpath(@__DIR__, "reactive.jl"))  # reactive/@onclick/pause async primitives (shared with the engine)
include(joinpath(@__DIR__, "tables.jl"))    # SlateTable / slate_table — uses no deps; soft-detects Tables.jl
include(joinpath(@__DIR__, "trace.jl"))     # @trace / SlateTrace inline value tracing (engine + worker)
include(joinpath(@__DIR__, "paged.jl"))     # PagedProvider / SlatePagedTable / slate_query (provider registry)
include(joinpath(@__DIR__, "widgets.jl"))   # shared @bind widgets + namespace contract (engine + worker)
include(joinpath(@__DIR__, "docharvest.jl")) # shared docstring harvest (runs where the deps are loaded)
include(joinpath(@__DIR__, "demux.jl"))     # task-demux output capture (parallel evaluator I/O isolation)
include(joinpath(@__DIR__, "parsched.jl"))  # ParCell / par_blockers / run_scheduled — parallel batch scheduler
include(joinpath(@__DIR__, "macroexpand.jl")) # _expand_cell_source — macro-aware deps (engine + worker)
include(joinpath(@__DIR__, "capture.jl"))   # run_capture — uses EChart + SlateTable above
include(joinpath(@__DIR__, "completion.jl")) # slate_completions — REPLCompletions in the NB namespace

# Per-notebook execution namespace (warm; reset by replacing the module). Built by the
# SAME shared contract `_populate_notebook_ns!` as the in-process kernel, so the two
# namespaces are identical; only `slate_refresh` differs — here it PUBs on the gate
# stream (a cell's async task calls `slate_refresh(:data)`; the KaimonSlate server,
# subscribed, recomputes those vars' readers and pushes a live update).
function _new_ns()
    m = Module(:NB)
    _populate_notebook_ns!(m;
        echart = echart, EChart = EChart, slate_table = slate_table, SlateTable = SlateTable,
        slate_query = slate_query,
        slate_refresh = (vars...) -> KaimonGate._publish_stream("slate_refresh", join(string.(vars), ",")),
        # wire: "id|frac|done|msg" (id/frac/done are |-free; msg is the rest — split limit=4)
        slate_progress = (frac; msg = "", id = "", done = false) ->
            KaimonGate._publish_stream("slate_progress", string(id, "|", Float64(frac), "|", done === true ? 1 : 0, "|", msg)),
        # `@asset`/`readfile` resolve relative paths against the notebook's project dir (what
        # `pkgdir(...)` gives, and where a package notebook's assets live). Read at call time so a
        # provenance change is picked up; falls back to the active project when PARENT_PROJECT is unset.
        assetbase = () -> (p = PARENT_PROJECT[]; !isempty(p) ? p :
                           (ap = Base.active_project(); ap === nothing ? "" : dirname(ap))))
    return m
end
const _NS = Ref{Module}(_new_ns())

# ── Capture tools (invoked by the server via synchronous :tool_call) ───────────
# Each returns a serialization-friendly value that rides back binary in the gate
# response's `value` field.

# ── Durable cell-result memoization ───────────────────────────────────────────────────────────
# An expensive cell (measured runtime ≥ threshold) is cached to disk so a worker / extension restart
# RESTORES its result + the globals it defined instead of recomputing. The server passes a `memo_key`
# digesting the cell's source + its upstream cells' sources + relevant @bind values; here we fold in
# the Revise-tracked `src/` state and the resolved Manifest — making the key TOTAL, so a src edit or a
# package change invalidates the entry (no silent stale restore). See ANIMATION_PIPELINE_DESIGN.md.
# `Serialization` is the (only) codec today; `memostore.jl` (stdlib SHA/TOML, pure — see its
# header) is the content-addressed blob + manifest layer under it. Both inside the guard: if
# either is unavailable the worker degrades to memo-off, exactly as before — never fails to boot.
const _MEMO_OK = try
    @eval import Serialization
    include(joinpath(@__DIR__, "memostore.jl"))
    true
catch
    false
end
const _MEMO_DIR = Ref{String}("")
# On-disk ceiling for the durable memo store (LRU-evicted). Configurable — big-data notebooks
# legitimately cache multi-GB artifacts: `KAIMONSLATE_MEMO_CAP_GB` (forwarded into the worker's env
# by `_spawn_worker!` from the panel/slate.json setting, or set directly). Unset → an ADAPTIVE
# default: a quarter of the volume's free space, clamped to [2, 20] GB — a flat number is either
# too small for a workstation or eats a laptop's last gigabytes. Note a SINGLE entry larger than
# the cap can never stay cached — prefer caching artifact PATHS (DuckDB/parquet files) over giant
# in-memory values.
function _default_memo_cap()::Int
    free = try; Base.diskstat(dirname(_memo_dir())).available; catch; 0; end
    gb = 1024^3
    free <= 0 ? 10gb : clamp(round(Int, free ÷ 4), 2gb, 20gb)
end
const _MEMO_CAP = Ref{Int}(0)   # resolved lazily — _memo_dir must exist for diskstat
_memo_cap() = (_MEMO_CAP[] > 0 ? _MEMO_CAP[] : (_MEMO_CAP[] =
    (v = tryparse(Float64, get(ENV, "KAIMONSLATE_MEMO_CAP_GB", "")); v !== nothing && v > 0 ?
        round(Int, v * 1024^3) : _default_memo_cap())))
function _memo_dir()
    if _MEMO_DIR[] == ""
        d = joinpath(get(ENV, "HOME", tempdir()), ".cache", "kaimon", "slate-memo")
        try; mkpath(d); catch; d = joinpath(tempdir(), "kaimon-slate-memo"); mkpath(d); end
        _MEMO_DIR[] = d
    end
    return _MEMO_DIR[]
end

# The DEVELOPED source dirs whose edits should invalidate a memo entry: the parent project's `src/`
# plus any dev'd path-dependency's `src/` (from `path = "…"` lines in the active Manifest). Derived
# deterministically from disk + the Manifest — NOT Revise's `pkgdatas`.
function _memo_src_dirs()
    dirs = String[]
    p = PARENT_PROJECT[]
    isempty(p) || (d = joinpath(p, "src"); isdir(d) && push!(dirs, d))
    try
        proj = Base.active_project()
        if proj !== nothing
            base = dirname(proj); man = joinpath(base, "Manifest.toml")
            if isfile(man)
                for m in eachmatch(r"(?m)^\s*path\s*=\s*\"([^\"]+)\"", read(man, String))
                    pd = String(m.captures[1])
                    isabspath(pd) || (pd = normpath(joinpath(base, pd)))
                    d = joinpath(pd, "src"); isdir(d) && push!(dirs, d)
                end
            end
        end
    catch
    end
    return unique!(dirs)
end

# The deterministic, sorted `.jl` file set under those dirs.
function _memo_src_files()
    files = String[]
    for dir in _memo_src_dirs(), (root, _, fs) in walkdir(dir), f in fs
        endswith(f, ".jl") && push!(files, joinpath(root, f))
    end
    return sort!(unique!(files))
end

# Digest of the developed `src/` (def-name → body-hash) so an edit to a function a cell calls
# invalidates its memo entry. Read deterministically FROM DISK (fixed file set + def-body hashes) —
# NOT Revise's async `pkgdatas`, whose membership varied with load timing, so store-time and
# restore-time digests diverged and nearly every restart MISSED the cache (recompute, not restore).
# Cached by the newest src mtime so it costs one `stat` sweep per eval, not a full re-parse.
const _SRC_DIGEST_CACHE = Ref{Tuple{Float64,UInt}}((-1.0, UInt(0)))
function _src_digest()
    try; _seed_new_src_defs!(); catch; end          # keep seeding the hot-reload watcher's baseline
    files = _memo_src_files()
    isempty(files) && return UInt(0x53726300)        # nothing developed → a constant (deterministic)
    mt = try; maximum(mtime, files; init = 0.0); catch; 0.0; end
    _SRC_DIGEST_CACHE[][1] == mt && return _SRC_DIGEST_CACHE[][2]
    h = UInt(0x53726300)
    try
        for path in files
            h = hash(path, h); defs = _file_defs(path)
            for k in sort!(collect(keys(defs))); h = hash((k, defs[k]), h); end
        end
    catch
    end
    _SRC_DIGEST_CACHE[] = (mt, h)
    return h
end

# Digest of the resolved Manifest (package versions); cached by mtime.
const _MANIFEST_DIGEST = Ref{Tuple{Float64,UInt}}((-1.0, UInt(0)))
function _manifest_digest()
    try
        proj = Base.active_project(); proj === nothing && return UInt(0)
        man = joinpath(dirname(proj), "Manifest.toml"); isfile(man) || return UInt(0)
        mt = Float64(mtime(man))
        _MANIFEST_DIGEST[][1] == mt && return _MANIFEST_DIGEST[][2]
        d = hash(read(man)); _MANIFEST_DIGEST[] = (mt, d); return d
    catch; return UInt(0); end
end

# The FULL entry key: the server's memo_key (cell + upstream sources + binds + assets) with the
# worker-side src/ and Manifest digests folded in. Names the manifest in the store (fmt 3); the
# entry's DATA lives in content-addressed blobs the manifest references, so a re-key with
# unchanged values (e.g. any src/ edit restaling every entry) re-stores only ~1 KB of manifest —
# every data byte dedups against the blobs already on disk.
function _memo_fullkey(cellkey::AbstractString)
    sd = _src_digest(); md = _manifest_digest()
    # Opt-in diagnostic: log the two digests that complete the cache key, so a store-run vs a
    # restore-run can be compared to see which one drifts (→ near-total cache misses). KAIMONSLATE_MEMO_DEBUG=1.
    get(ENV, "KAIMONSLATE_MEMO_DEBUG", "") == "1" &&
        @info "slate memo key" cell = String(cellkey) src_digest = string(sd; base = 16) manifest_digest = string(md; base = 16)
    return string(hash((String(cellkey), sd, md)); base = 16)
end

# Bound the store to the cap: manifests are the LRU roots (restore touches them), blobs are
# refcount-swept once no surviving manifest references them — a blob shared by several entries
# outlives any one entry's eviction. Legacy fmt≤2 flat files are swept too. See MemoStore.gc.
function _memo_gc()
    _MEMO_OK || return
    try; MemoStore.gc(_memo_dir(); cap = _memo_cap()); catch; end
end

# Restore the entry for `cellkey`: decode every stored binding + the wire from the manifest's
# blobs, assign the globals into the namespace, return the wire. An entry snapshots exactly the
# globals the original run left defined (`_memo_store`), so assigning them all reproduces the
# post-run namespace faithfully — a declared write ABSENT from the entry was equally absent after
# the genuine run (a conditional assignment whose branch didn't fire). The manifest fmt gate
# (MemoStore, fmt 3) drops pre-manifest entries; those miss once, re-run, and re-store. Everything
# is DECODED before anything is ASSIGNED, so a missing/corrupt blob (partial gc, a concurrent
# worker's eviction) is a clean miss, never a half-mutated namespace. Returns nothing (miss) or the wire.
function _memo_restore(cellkey::String; unread::Vector{String} = String[])
    _MEMO_OK || return nothing
    root = _memo_dir(); key = _memo_fullkey(cellkey)
    mf = MemoStore.read_manifest(root, key)
    mf === nothing && return nothing
    # An entry that ELIDED a display object (stored the wire image, not the object — see
    # `_memo_store`) is only faithful while that name stays UNREAD. A reader added since means the
    # real object is needed → treat as a miss; the re-run re-stores WITH the object (its name is no
    # longer in `unread`). Self-healing, no key games.
    for e in get(mf, "elided", Any[])
        e isa AbstractDict || return nothing
        String(get(e, "name", "")) in unread || return nothing
    end
    decode(h) = try
        MemoStore.with_blob(io -> Serialization.deserialize(io), root, String(h))
    catch
        (false, nothing)
    end
    binds = Tuple{Symbol,Any}[]
    for b in get(mf, "bindings", Any[])
        b isa AbstractDict || return nothing
        ok, v = decode(get(b, "blob", ""))
        ok || return nothing
        push!(binds, (Symbol(String(get(b, "name", ""))), v))
    end
    w = get(mf, "wire", nothing)
    w isa AbstractDict || return nothing
    ok, wire = decode(get(w, "blob", ""))
    ok || return nothing
    m = _NS[]
    for (s, v) in binds
        try; Core.eval(m, :($s = $v)); catch; return nothing; end
    end
    MemoStore.touch_manifest(root, key)             # mark as recently used (LRU root)
    return wire
end

# Persist the entry: each defined global → its own content-addressed blob (+ one for the wire),
# tied together by a small TOML manifest under the full key. Per-name blobs mean an unserializable
# value is diagnosed BY NAME, identical data across entries/cells/notebooks stores once, and a
# consumer can fetch one binding without the rest (the region-transfer seam). Snapshots exactly
# the declared writes that ARE defined post-run. One that isn't (a conditional assignment whose
# branch didn't fire, or static over-approximation by the dataflow pass) is simply left out — a
# genuine re-run would leave it equally undefined, so the entry stays faithful. A DEFINED value
# that won't serialize aborts the whole entry (a restore missing it would NOT be faithful); its
# already-written sibling blobs are simply unreferenced and swept by a later gc.
# Display objects (Makie figures/scenes, Plots plots) are the pathological Serialization case:
# a 14 MB scene graph and seconds to serialize for a chart whose RENDERED image already rides the
# wire blob. When nothing downstream reads the binding, the object is pure dead weight — store the
# pixels, elide the object. Type check by ROOT MODULE NAME so the dep-light worker never needs a
# plotting package loaded to decide.
function _is_display_object(v)
    T = typeof(v)
    nameof(T) in (:Figure, :FigureAxisPlot, :Scene, :Plot) || return false
    mod = parentmodule(T)
    while parentmodule(mod) !== mod
        mod = parentmodule(mod)
    end
    return nameof(mod) in (:Makie, :CairoMakie, :GLMakie, :WGLMakie, :RPRMakie, :Plots, :PlotlyBase, :PlotlyJS)
end

function _memo_store(cellkey::String, names::Vector{String}, wire;
                     unread::Vector{String} = String[])
    _MEMO_OK || return false
    m = _NS[]
    root = _memo_dir(); key = _memo_fullkey(cellkey)
    entries = Dict{String,Any}[]
    elided = Dict{String,Any}[]
    # Read each declared write at the LATEST world age. A global the cell defines for the FIRST
    # time this run lives in a binding partition NEWER than this method's captured (older) world
    # age, so a naive `isdefined`/`getglobal` here would not observe it — and we'd wrongly skip
    # caching on every fresh-namespace run (a cold reopen defines all its globals anew), which is
    # exactly why the durable cache almost never populated. `invokelatest` re-dispatches the read
    # at the current world so the just-created binding is visible. (A later cell that reads the
    # global runs in its own newer world, which is why it saw the value while this guard didn't.)
    for nm in names
        s = Symbol(nm)
        if !Base.invokelatest(isdefined, m, s)
            @info "slate memo: a declared write is undefined post-run — cached without it" key = cellkey name = nm
            continue
        end
        v = Base.invokelatest(getglobal, m, s)
        if nm in unread && _is_display_object(v)
            push!(elided, Dict{String,Any}("name" => nm, "type" => string(typeof(v))))
            @info "slate memo: display object elided (wire image only)" cell = cellkey name = nm
            continue
        end
        h, n = try
            MemoStore.put_blob(io -> Serialization.serialize(io, v), root)
        catch e
            @info "slate memo: not cached — a binding won't serialize" cell = cellkey name = nm reason = first(split(sprint(showerror, e), '\n'))
            return false
        end
        push!(entries, Dict{String,Any}("name" => nm, "codec" => "jls", "blob" => h, "bytes" => n))
    end
    try
        wh, wn = MemoStore.put_blob(io -> Serialization.serialize(io, wire), root)
        mf = Dict{String,Any}(
            "srckey" => String(cellkey),            # the server half of the key (diagnostics)
            "created" => round(Int, time()),
            "julia" => string(VERSION),
            "bindings" => entries,
            "wire" => Dict{String,Any}("codec" => "jls", "blob" => wh, "bytes" => wn))
        isempty(elided) || (mf["elided"] = elided)  # restore checks these against CURRENT readers
        MemoStore.write_manifest(root, key, mf)
        _memo_gc()
        return true
    catch e
        @info "slate memo: not cached" cell = cellkey reason = first(split(sprint(showerror, e), '\n'))
        return false
    end
end

# Evaluate ONE cell's source in the warm namespace, returning its wire-form capture — the shared core
# of both the serial `__slate_eval` and the parallel `__slate_eval_batch`. Runs under a `DemuxCapture`
# so it's safe to call from a spawned task (each task captures its own task-local stdout/stderr/display;
# see demux.jl). `memo_*` enable durable caching: restore an expensive cell with no recompute, or persist
# it after a run exceeding `memo_threshold` ms. NOTE: assignment into the shared namespace `_NS[]` is the
# unavoidable shared-state write — the scheduler (`par_blockers`) guarantees two cells that read/write the
# same global are never in flight at once, so concurrent evals only ever touch disjoint globals.
function _eval_one(source::String, filename::String, memo_key::String,
                   memo_names::Vector{String}, memo_threshold::Float64,
                   memo_force::Bool = false, memo_always::Bool = false,
                   memo_unread::Vector{String} = String[])
    cid = replace(filename, r"^cell:" => "")
    # `memo_force` (the ▶ play button): an explicit run request — never satisfy it from the cache.
    # The fresh result still stores below, replacing the entry.
    if !isempty(memo_key) && !memo_force
        w = _memo_restore(memo_key; unread = memo_unread)
        if w !== nothing
            @info "slate memo: restored (no recompute)" cell = cid
            return merge(w, (memo = "restored",))   # tell the server this run came from the durable cache
        end
    end
    local r
    try
        r = run_capture(_NS[], source, filename; capture = DemuxCapture())
    catch e
        # Capture machinery itself threw (a worker/infra bug, NOT a normal cell error — those are
        # captured inside run_capture). Log it loudly and return an error wire so the cell shows the
        # failure and the worker keeps running, instead of the exception vanishing into the gate.
        @error "slate eval: capture machinery threw" cell = cid exception = (e, catch_backtrace())
        return (stdout = "", mime = Tuple{String,Vector{UInt8}}[], echarts = Any[], tables = Any[],
                binds = NamedTuple[], value_repr = "",
                exception = "internal capture error: " * sprint(showerror, e),
                backtrace = nothing, duration_ms = 0.0, trace = Any[], stderr = "", overflow = NamedTuple[],
                animations = Any[])
    end
    if r.exception !== nothing
        @warn "slate eval: cell errored" cell = cid error = first(split(String(r.exception), '\n'))
    else
        @info "slate eval: ran cell" cell = cid ms = round(r.duration_ms; digits = 1)
    end
    isempty(r.overflow) ||
        @info "slate eval: output truncated for display — full result saved" cell = cid items = [(String(e.kind), Int(e.bytes)) for e in r.overflow]
    # Cache error-free runs that are expensive (over the threshold) — or explicitly `cache`-tagged
    # (memo_always: a pipeline stage persisted regardless of runtime; cheap untagged cells never pay
    # the serialize cost).
    if !isempty(memo_key) && r.exception === nothing &&
       (memo_always || (memo_threshold > 0 && r.duration_ms >= memo_threshold))
        if _memo_store(memo_key, memo_names, r; unread = memo_unread)
            @info "slate memo: cached" cell = cid ms = round(r.duration_ms; digits = 1)
            return merge(r, (memo = "stored",))
        end
    end
    return r
end

"Evaluate a cell's source in the warm namespace; return the wire-form capture. `filename` (a
kwarg — GateTool drops optional positionals) becomes the parse/backtrace location, `cell:<id>`.
`memo_*` (when set) enable durable caching: restore an expensive cell's result on a cold start, or
persist it after a run that exceeds `memo_threshold` ms."
function __slate_eval(source::String; filename::String = "string",
                     memo_key::String = "", memo_names::Vector{String} = String[],
                     memo_threshold::Float64 = 0.0, memo_force::Bool = false,
                     memo_always::Bool = false, memo_unread::Vector{String} = String[])
    # Register this eval's task under its cell id so __slate_cancel can interrupt it (the server runs
    # parallel cells as concurrent __slate_eval calls; a stop throws InterruptException into them).
    cid = replace(filename, r"^cell:" => "")
    lock(_CANCEL_LOCK) do; _RUNNING_TASKS[cid] = current_task(); end
    try
        return _eval_one(source, filename, memo_key, memo_names, memo_threshold, memo_force,
                         memo_always, memo_unread)
    finally
        lock(_CANCEL_LOCK) do; delete!(_RUNNING_TASKS, cid); end
    end
end

# ── Parallel batch evaluation (inter-cell, in-process) ───────────────────────────────────────────
# Run a batch of stale cells CONCURRENTLY in this one worker, sharing the warm namespace. Each cell is
# a Dict from the server carrying its source + dataflow metadata (deps/reads/writes/opaque, already
# folding define-cells into `opaque` server-side for world-age safety). The pure scheduler
# (`run_scheduled`, parsched.jl) launches independent cells on spawned tasks while serialising any pair
# that conflicts, and streams each cell's wire result back the instant it finishes via the gate
# `slate_celldone` channel `(; run_id, id, wire)` — so a fast cell renders while a slow sibling is still
# running. Returns `(; run_id, ids)` (a small ack; the real payloads rode the stream).
_as_symset(v) = Set{Symbol}(Symbol(x) for x in (v === nothing ? () : v))
_as_strset(v) = Set{String}(String(x) for x in (v === nothing ? () : v))
_cell_get(c, k, default) = c isa AbstractDict ? get(c, k, get(c, Symbol(k), default)) : default

# Currently-running batch evaluator tasks (id → Task), so `__slate_cancel` can interrupt them. The
# runner is serial per notebook and this worker serves one notebook, so at most one batch is live and
# ids are unique within it. Guarded by a lock (mutated from the scheduler task + the cancel handler).
const _CANCEL_LOCK = ReentrantLock()
const _RUNNING_TASKS = Dict{String,Task}()
const _BATCH_CANCEL = Ref(false)          # set by __slate_cancel; checked by the batch evalfn

# The wire-form of a cancelled cell — an error result so the UI marks it interrupted (not stuck).
_interrupted_wire() = (stdout = "", mime = Tuple{String,Vector{UInt8}}[], echarts = Any[], tables = Any[],
                       binds = NamedTuple[], value_repr = "", exception = "InterruptException: run cancelled",
                       backtrace = nothing, duration_ms = 0.0, trace = Any[], stderr = "",
                       overflow = NamedTuple[], animations = Any[])

# Interrupt every running batch cell (a stop button). `schedule(t, InterruptException(); error=true)`
# delivers the throw at the task's next safepoint/yield — like every notebook's interrupt, a pure
# tight CPU loop with no allocation/yield can't be preempted (fall back to a worker restart for that).
# Each interrupted cell's `run_capture` catches the exception and returns an error wire, which streams
# back via `slate_celldone` — so the cell shows "interrupted" and the WARM NAMESPACE is preserved.
function __slate_cancel(; run_id::String = "")
    _BATCH_CANCEL[] = true             # short-circuit any cell that hasn't started yet (evalfn checks this)
    n = 0
    lock(_CANCEL_LOCK) do
        for (id, t) in collect(_RUNNING_TASKS)
            try
                istaskdone(t) || (schedule(t, InterruptException(); error = true); n += 1)
            catch
            end
        end
    end
    @info "slate cancel: interrupted cells" count = n
    return n
end

"Interrupt ONLY the named cells' in-flight evaluator tasks — superseded-edit preemption. An
edited/deleted cell's old-source run can only be discarded on completion (the server's src_hash
version guard), so stop burning worker time on it. Unknown/finished ids are no-ops; unlike
`__slate_cancel` this never touches `_BATCH_CANCEL` (unstarted siblings still run). Returns the
number interrupted. (`ids` is a KEYWORD arg — see `__slate_macroexpand`'s raw-Dict caveat.)"
function __slate_cancel_cells(; ids::Vector = Any[])
    n = 0
    lock(_CANCEL_LOCK) do
        for raw in ids
            t = get(_RUNNING_TASKS, String(raw), nothing)
            t === nothing && continue
            try
                istaskdone(t) || (schedule(t, InterruptException(); error = true); n += 1)
            catch
            end
        end
    end
    n > 0 && @info "slate cancel: preempted superseded cells" count = n
    return n
end

# `cells` is a Vector{Dict} (id/source/deps/reads/writes/opaque/memo fields per cell). NOTE: this
# currently depends on the gate delivering structured (non-scalar) tool-call arguments intact — see
# GATE_STRUCTURED_ARGS_ISSUE.md. Until that fabric fix lands, the batch arrives empty and the server
# falls back to the serial path (it guards on empty results).
function __slate_eval_batch(cells; run_id::String = "", npool::Int = 0)
    specs = ParCell[]
    meta = Dict{String,Any}()
    for c in cells
        id = String(_cell_get(c, "id", ""))
        isempty(id) && continue
        writes = _as_symset(_cell_get(c, "writes", Symbol[]))
        # Plotting cells share Makie's non-thread-safe globals (invisible to dataflow analysis): give
        # them a synthetic shared write so par_blockers serialises graphics-vs-graphics. See parsched.jl.
        _uses_shared_graphics(String(_cell_get(c, "source", ""))) && push!(writes, _GRAPHICS_SENTINEL)
        push!(specs, ParCell(id, _as_strset(_cell_get(c, "deps", String[])),
                             _as_symset(_cell_get(c, "reads", Symbol[])),
                             writes,
                             _cell_get(c, "opaque", false) === true))
        meta[id] = c
    end
    # Max concurrent evaluator TASKS — deliberately NOT tied to Threads.nthreads(): tasks interleave on
    # one OS thread at yield points (sleep / IO / async), so independent I/O-bound cells overlap even on
    # the safe single-compute-thread worker. (CPU-bound cells need real OS threads, which await the
    # world-age binding fix — see GATE/threads notes.) Bound it so a huge notebook doesn't spawn 100s.
    pool = npool > 0 ? npool : max(8, Threads.nthreads())
    _BATCH_CANCEL[] = false            # fresh batch — clear any prior cancel
    @info "slate batch: scheduling" run = run_id cells = length(specs) pool = pool

    evalfn = function (id)
        _BATCH_CANCEL[] && return _interrupted_wire()   # cancelled before this cell started → don't run it
        c = meta[id]
        _eval_one(String(_cell_get(c, "source", "")),
                  String(_cell_get(c, "filename", "cell:" * id)),
                  String(_cell_get(c, "memo_key", "")),
                  Vector{String}(String[String(x) for x in _cell_get(c, "memo_names", String[])]),
                  Float64(_cell_get(c, "memo_threshold", 0.0)),
                  _cell_get(c, "memo_force", false) === true,
                  _cell_get(c, "memo_always", false) === true,
                  Vector{String}(String[String(x) for x in _cell_get(c, "memo_unread", String[])]))
    end
    # Track each task so __slate_cancel can interrupt it; drop it once it finishes.
    onspawn = (id, t) -> lock(_CANCEL_LOCK) do; _RUNNING_TASKS[id] = t; end
    ondone = (id, _wire) -> lock(_CANCEL_LOCK) do; delete!(_RUNNING_TASKS, id); end

    local res
    try
        res = run_scheduled(specs, pool, evalfn, ondone; onspawn = onspawn)
    finally
        lock(_CANCEL_LOCK) do; empty!(_RUNNING_TASKS); end   # belt-and-suspenders: never leak handles
    end
    # Normalise each cell's result to a wire: an evaluator that threw OUTSIDE run_capture's own try
    # (e.g. an interrupt during capture setup) shows up here as an Exception — turn it into an error
    # wire so the cell renders the failure instead of vanishing. The whole map rides back binary in the
    # gate REQ/REP `value` field (the stream channel is string-only, so rich results can't ride it).
    results = Dict{String,Any}()
    for (id, r) in res
        results[id] = r isa Exception ? merge(_interrupted_wire(), (; exception = sprint(showerror, r))) : r
    end
    @info "slate batch: done" run = run_id cells = length(specs)
    return (; run_id = run_id, results = results)
end

"Apply a browser `@bind` value change: coerce against the widget, update the registry,
and assign the global — via the namespace's injected `__slate_set_bind`. Returns the
coerced value."
function __slate_set_bind(name::String, value)
    return Base.invokelatest(getfield(_NS[], :__slate_set_bind), Symbol(name), value)
end

"Discard the namespace (full rebuild)."
__slate_reset() = (@info "slate: namespace reset (fresh rebuild)"; _NS[] = _new_ns(); true)

# Flat scalar args only (the gate reflects the signature into an MCP schema — a
# nested-Dict argument doesn't validate, so we pass page params individually).
"Fetch one page of a registered paged table (server-paged tables / `slate_query`)."
__slate_table_page(table_id::String, page::Int, page_size::Int, sort_col::Int, sort_desc::Bool, search::String) =
    _provider_page(table_id, PageRequest(page, page_size, sort_col, sort_desc, search))

"Capture markdown `{{ }}` interpolation expressions (rich) — one wire-form each."
__slate_interp(exprs::Vector{String}) = [run_capture(_NS[], e; capture = DemuxCapture()) for e in exprs]

"Completion candidates in the warm namespace → `(; items, from, to)` (see `slate_completions`)."
__slate_complete(code::String, pos::Int) = slate_completions(_NS[], code, pos)

# A throwaway module to `import` packages into for harvesting, so eager indexing can
# load project deps the notebook hasn't `using`'d WITHOUT polluting the cell namespace.
const _DOC_SCAN = Ref{Module}()
_doc_scan() = (isassigned(_DOC_SCAN) || (_DOC_SCAN[] = Module(:_SlateDocScan)); _DOC_SCAN[])

"Harvest `{module,name,doc}` for the named modules (loading them if needed) — for docs search."
function __slate_harvest_docs(mod_names::Vector{String})
    m = _doc_scan()
    for nm in mod_names
        try; Core.eval(m, Meta.parse("import " * nm)); catch; end   # load if needed; no-op if already
    end
    return harvest_module_docs(m, mod_names)
end

"Resolve `name` (loading its head module if needed) and return its help record
`{name,module,doc,kind,exports}` — powers the docs palette's `?Module` drill-down."
function __slate_module_help(name::String)
    head = String(first(split(name, '.')))
    # Prefer the live notebook namespace: a `using`'d or cell-defined symbol (e.g. `damped_wave`)
    # resolves there WITH its docs. Only fall back to a throwaway module that imports the head
    # package for `?Module` drill-down on a package the notebook hasn't brought into scope.
    nb = _NS[]
    if isdefined(nb, Symbol(head))
        rec = try; module_help(nb, name); catch; nothing; end
        rec !== nothing && (get(rec, "kind", "unknown") != "unknown" || !isempty(strip(get(rec, "doc", "")))) && return rec
    end
    m = _doc_scan()
    try; Core.eval(m, Meta.parse("import " * head)); catch; end   # load the package if needed
    return module_help(m, name)
end

"Macro-expand cell sources in the live notebook namespace (recursive, NO evaluation) and return
id → expanded source string. A cell whose expansion yields nothing (parse failure, macro not yet
defined, expansion threw) is omitted — the server keeps its conservative static analysis for it.
NOTE: `cells` must be a KEYWORD arg — a single positional `::Dict` param triggers the gate
dispatcher's raw-Dict fast path, which hands the handler the WHOLE arguments dict instead."
function __slate_macroexpand(; cells::Dict = Dict{String,Any}())
    out = Dict{String,String}()
    nb = _NS[]
    for (id, src) in cells
        s = src isa AbstractString ? _expand_cell_source(nb, String(src)) : nothing
        s === nothing || (out[String(id)] = s)
    end
    return out
end

"The worker project's direct dependencies as `{name, version, uuid, source, origin}` (for eager docs
auto-index + the package viewer). `source` = \"registry\" | \"path\" (a dev'd local checkout) | \"git\"
(added from a URL); `origin` carries the path or `url#rev` for the non-registry ones — so the UI can flag
that a dep points at something machine-specific rather than a pinned registry release."
function __slate_project_deps()
    out = Dict{String,Any}[]
    try
        proj = Pkg.project()
        info = Pkg.dependencies()
        for (name, uuid) in proj.dependencies
            pi = get(info, uuid, nothing)
            ver = (pi === nothing || pi.version === nothing) ? "" : string(pi.version)
            source = "registry"; origin = ""
            if pi !== nothing
                try
                    if getfield(pi, :is_tracking_path)
                        source = "path"; origin = String(something(getfield(pi, :source), ""))
                    elseif getfield(pi, :is_tracking_repo)
                        source = "git"
                        url = ""; rev = ""
                        try; url = String(something(getfield(pi, :git_source), "")); catch; end
                        try; rev = String(something(getfield(pi, :git_revision), "")); catch; end
                        origin = isempty(rev) ? url : (isempty(url) ? rev : url * "#" * rev)
                    end
                catch
                end
            end
            push!(out, Dict{String,Any}("name" => name, "version" => ver, "uuid" => string(uuid),
                                        "source" => source, "origin" => origin))
        end
    catch
    end
    return out
end

"Read a project's direct deps as `[{name, version, uuid}]`. Versions come from the project's
own `Manifest.toml` when present (best-effort), so this works for a project that isn't the
active one (e.g. the parent). Returns `[]` on any failure."
function _project_deps_at(projdir::AbstractString)
    out = Dict{String,Any}[]
    try
        pf = joinpath(projdir, "Project.toml")
        isfile(pf) || return out
        proj = Pkg.TOML.parsefile(pf)
        deps = get(proj, "deps", Dict{String,Any}())
        # versions: parse the sibling Manifest if present (format differs across Julia, but
        # each dep entry is a 1-elt array of tables carrying `version`).
        vers = Dict{String,String}()
        mf = joinpath(projdir, "Manifest.toml")
        if isfile(mf)
            man = Pkg.TOML.parsefile(mf)
            mdeps = get(man, "deps", man)               # Julia ≥1.7 nests under "deps"
            for (nm, entries) in mdeps
                entries isa AbstractVector && !isempty(entries) && haskey(entries[1], "version") &&
                    (vers[nm] = string(entries[1]["version"]))
            end
        end
        for (name, uuid) in deps
            push!(out, Dict{String,Any}("name" => name, "version" => get(vers, name, ""), "uuid" => string(uuid)))
        end
    catch
    end
    return out
end

"Environment provenance for the package viewer: the notebook's own direct deps (the active
project — where `Pkg.add` lands) and, separately, the parent project's deps (inherited via
LOAD_PATH stacking). Shape: `{notebook:{path,deps}, parent:{path,deps}|nothing}`."
function __slate_env_info()
    nb = Dict{String,Any}("path" => "", "deps" => Dict{String,Any}[])
    try
        nb["path"] = dirname(Pkg.project().path)
        nb["deps"] = __slate_project_deps()
    catch
    end
    parent = nothing
    p = PARENT_PROJECT[]
    if !isempty(p)
        name = ""
        ppf = joinpath(p, "Project.toml")
        isfile(ppf) && (name = string(get(Pkg.TOML.parsefile(ppf), "name", "")))
        parent = Dict{String,Any}("path" => p, "name" => name, "deps" => _project_deps_at(p))
    end
    return Dict{String,Any}("notebook" => nb, "parent" => parent)
end

# Seed a forked notebook env from `parent`: copy the parent's deps + compat (NOT its package
# identity) and its Manifest as the resolution baseline, activate the env, then `dev` the
# parent package in so `using ParentModule` works — all preserving the parent's pinned
# versions, so anything already loaded in this worker stays valid. One consistent env.
function _seed_notebook_env!(envdir::AbstractString, parent::AbstractString)
    mkpath(envdir)
    pname = ""
    ppf = joinpath(parent, "Project.toml")
    if isfile(ppf)
        pt = Pkg.TOML.parsefile(ppf)
        seed = Dict{String,Any}()
        haskey(pt, "deps") && (seed["deps"] = pt["deps"])
        haskey(pt, "compat") && (seed["compat"] = pt["compat"])
        open(joinpath(envdir, "Project.toml"), "w") do io; Pkg.TOML.print(io, seed); end
        pmf = joinpath(parent, "Manifest.toml")
        isfile(pmf) && cp(pmf, joinpath(envdir, "Manifest.toml"); force = true)
        (haskey(pt, "name") && haskey(pt, "uuid")) && (pname = String(pt["name"]))
    else
        write(joinpath(envdir, "Project.toml"), "")
    end
    Pkg.activate(envdir)
    if !isempty(pname)
        try
            Pkg.develop(Pkg.PackageSpec(path = parent); preserve = Pkg.PRESERVE_ALL)
        catch
            try; Pkg.develop(Pkg.PackageSpec(path = parent)); catch; end
        end
    end
    return pname
end

"Fork this notebook off its parent: materialise + activate the notebook env (`envdir`) as a
single environment that extends the parent. Called the first time a package is added while
running in base mode. Returns `{ok, message}`."
function __slate_fork(envdir, parent)
    try
        _seed_notebook_env!(String(envdir), String(parent))
        return Dict{String,Any}("ok" => true)
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

"Re-resolve a forked notebook env against the CURRENT parent (called when the parent's
Manifest changed): re-seed from the parent, then re-add the notebook's own packages so the
two stay one consistent environment. Returns `{ok, adds}`."
function __slate_sync_parent(envdir, parent)
    try
        e = String(envdir); p = String(parent)
        fdeps = Set{String}()
        fpf = joinpath(e, "Project.toml")
        isfile(fpf) && (fdeps = Set(keys(get(Pkg.TOML.parsefile(fpf), "deps", Dict{String,Any}()))))
        pdeps = Set{String}(); pname = ""
        ppf = joinpath(p, "Project.toml")
        if isfile(ppf)
            pt = Pkg.TOML.parsefile(ppf)
            pdeps = Set(keys(get(pt, "deps", Dict{String,Any}())))
            pname = string(get(pt, "name", ""))
        end
        adds = sort(collect(setdiff(fdeps, pdeps, Set([pname, ""]))))   # the notebook's own packages
        _seed_notebook_env!(e, p)
        isempty(adds) || Pkg.add(adds; preserve = Pkg.PRESERVE_ALL)
        return Dict{String,Any}("ok" => true, "adds" => adds)
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

"Reconstruct a notebook env from its `.jl` footer: seed from the parent, then add the
notebook's own packages at the recorded versions. Called on open when the env dir is
absent (e.g. a fresh git clone) but the footer records a delta. `pkgs` is a list of
`{name, version, uuid}`. Returns `{ok, message}`."
function __slate_reconstruct(envdir, parent, pkgs)
    try
        _seed_notebook_env!(String(envdir), String(parent))
        specs = Pkg.PackageSpec[]
        for p in pkgs
            nm = String(get(p, "name", get(p, :name, "")))
            isempty(nm) && continue
            v = string(get(p, "version", get(p, :version, "")))
            push!(specs, isempty(v) ? Pkg.PackageSpec(name = nm) : Pkg.PackageSpec(name = nm, version = VersionNumber(v)))
        end
        isempty(specs) || Pkg.add(specs)
        return Dict{String,Any}("ok" => true)
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

"Filesystem coordinates for a self-contained export: the active project dir (its
Project.toml + Manifest.toml fully pin the env) and any path/dev dependencies' source dirs
(the local/parent module code to bundle). The server reads these paths directly (same
machine) to build the tarball. Shape: `{projectdir, pathdeps:[{name, source}]}`."
function __slate_bundle_info()
    out = Dict{String,Any}("projectdir" => "", "pathdeps" => Dict{String,Any}[])
    try
        out["projectdir"] = dirname(Pkg.project().path)
        for (_uuid, pi) in Pkg.dependencies()
            if pi.is_tracking_path && pi.source !== nothing && isdir(pi.source)
                push!(out["pathdeps"], Dict{String,Any}("name" => pi.name, "source" => String(pi.source)))
            end
        end
    catch
    end
    return out
end

"Add or remove package(s) in the worker's OWN active project (the notebook's deps).
`op` is \"add\" or \"rm\". `name` is one spec, or several separated by whitespace/commas — all applied
in a single resolve (one precompile). Each add-spec may be a registry name (`Foo` or `Foo@1.2`), a git
URL (`https://…​[.git][#rev]`, `git@…`) → `Pkg.add(url=…)`, or a LOCAL path (`/…`, `~/…`, `./…`, or an
existing dir) → `Pkg.develop(path=…)` (so it's a dev'd dep, hot-reloadable + carried to remote workers).
Returns `{ok, message}`."
# Classify each add-token into a registry/git spec (→ Pkg.add) or a local-path spec (→ Pkg.develop),
# with a human label. Shared by the notebook-env add and the parent-project add.
function _pkg_add_specs(tokens)
    adds = Pkg.PackageSpec[]; devs = Pkg.PackageSpec[]; labels = String[]
    for tok in tokens
        t = String(tok)
        if occursin(r"^(https?://|git://|git@|ssh://)"i, t) || endswith(t, ".git") || endswith(t, ".git/")
            parts = split(t, '#'; limit = 2)                      # url or url#rev (branch/tag/sha)
            url = String(parts[1]); rev = length(parts) == 2 ? String(parts[2]) : ""
            push!(adds, isempty(rev) ? Pkg.PackageSpec(url = url) : Pkg.PackageSpec(url = url, rev = rev))
        elseif startswith(t, "/") || startswith(t, "~/") || startswith(t, "./") ||
               startswith(t, "../") || isdir(expanduser(t))
            push!(devs, Pkg.PackageSpec(path = abspath(expanduser(t))))
        elseif occursin('@', t)                                   # name@version
            nm, ver = split(t, '@'; limit = 2)
            push!(adds, Pkg.PackageSpec(name = String(nm), version = String(ver)))
        else
            push!(adds, Pkg.PackageSpec(name = t))
        end
        push!(labels, t)
    end
    return (adds = adds, devs = devs, labels = labels)
end

function __slate_pkg(op, name)
    tokens = filter(!isempty, split(String(name), r"[\s,]+"))
    isempty(tokens) && return Dict{String,Any}("ok" => false, "message" => "empty package name")
    o = String(op)
    try
        if o == "rm"
            Pkg.rm(String.(tokens))
            return Dict{String,Any}("ok" => true, "message" => "removed $(join(tokens, ", "))")
        elseif o == "add"
            s = _pkg_add_specs(tokens)
            isempty(s.adds) || Pkg.add(s.adds)
            isempty(s.devs) || Pkg.develop(s.devs)
            return Dict{String,Any}("ok" => true, "message" => "added $(join(s.labels, ", "))")
        else
            return Dict{String,Any}("ok" => false, "message" => "unknown op '$o'")
        end
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

"Add/remove package(s) in the notebook's PARENT PROJECT (shared) rather than its own env, then
re-resolve the active notebook env so the change is visible. `parent` is the parent project dir.
Restores the active project even on error. Returns `{ok, message}`."
function __slate_pkg_parent(op, name, parent)
    isempty(String(parent)) && return Dict{String,Any}("ok" => false, "message" => "no parent project")
    tokens = filter(!isempty, split(String(name), r"[\s,]+"))
    isempty(tokens) && return Dict{String,Any}("ok" => false, "message" => "empty package name")
    cur = try; dirname(Pkg.project().path); catch; ""; end
    try
        Pkg.activate(String(parent))
        o = String(op)
        if o == "add"
            s = _pkg_add_specs(tokens)
            isempty(s.adds) || Pkg.add(s.adds)
            isempty(s.devs) || Pkg.develop(s.devs)
            msg = "added $(join(s.labels, ", ")) to the project"
        elseif o == "rm"
            Pkg.rm(String.(tokens)); msg = "removed $(join(tokens, ", ")) from the project"
        else
            isempty(cur) || Pkg.activate(cur)
            return Dict{String,Any}("ok" => false, "message" => "unknown op '$o'")
        end
        # Back to the notebook env and re-resolve so it picks up the parent's change (the fork dev-refs
        # the parent, so a resolve pulls the new dep through). Best-effort — the add already succeeded.
        if !isempty(cur)
            Pkg.activate(cur)
            try; Pkg.resolve(); catch; end
        end
        return Dict{String,Any}("ok" => true, "message" => msg)
    catch e
        isempty(cur) || (try; Pkg.activate(cur); catch; end)
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

# ── Hot-reload of the parent project's /src (Revise) ──────────────────────────
# Revise is loaded in Main by the boot script and tracks dev'd packages (the notebook's
# parent project). KaimonGate's serve() PUBs `files_changed` on each Revise.revision_event;
# the slate server then calls __slate_revise to APPLY the pending revisions and learn which
# definitions changed, so it can invalidate exactly the cells that read them.

# `_def_name` / `_sig_name` / `_name_str` / `findfirst_def` — the top-level-def name extractor,
# in a shared, dependency-free file so it's unit-tested directly (test/test_defname.jl).
include(joinpath(@__DIR__, "defname.jl"))

# Per-file snapshot of (def-name → body-hash), so we can report the names whose DEFINITION
# actually changed — not every name in the touched file. Keyed by the file's absolute path.
# Seeded lazily each watcher tick (`_seed_new_src_defs!`) so the first edit diffs against a
# baseline. We parse the file FROM DISK (not Revise's `mod_exs_infos`) because Revise parses a
# package's files lazily — only on the first revision — so before any edit `mod_exs_infos` is
# empty; the same disk parse for seed AND diff also keeps body-hashes directly comparable.
const _SRC_DEFS = Dict{String,Dict{String,UInt64}}()
_file_path(pd, rpath) = try; joinpath(pd.info.basedir, String(rpath)); catch; String(rpath); end

# (def-name → body-hash) for one source file, parsed fresh from disk.
function _file_defs(path::AbstractString)
    d = Dict{String,UInt64}()
    isfile(path) || return d
    src = try; read(path, String); catch; return d; end
    top = try; Meta.parseall(src); catch; return d; end
    return _collect_defs!(d, top)
end

# Baseline the defs of any tracked file we haven't seen yet, WITHOUT reporting — so the first
# edit diffs against a real snapshot. Idempotent (only fills missing keys), so it's safe to run
# every watcher tick: a package `using`'d after the worker booted gets seeded on the next tick,
# before its first edit (otherwise that edit would conservatively flag every reader in the file).
function _seed_new_src_defs!()
    R = Main.Revise
    (isdefined(R, :pkgdatas)) || return nothing
    try
        for pd in values(R.pkgdatas), rpath in pd.info.files
            path = _file_path(pd, rpath)
            haskey(_SRC_DEFS, path) && continue
            _SRC_DEFS[path] = _file_defs(path)
        end
    catch
    end
    return nothing
end

# Names whose DEFINITION changed (added / body-changed / removed) across a snapshot of
# (PkgData, relpath) revision entries — change-granular, so editing one method flags only the
# cells that read THAT method, not every cell reading anything in the file. Updates the snapshot.
function _changed_names(queue)
    changed = Set{String}()
    for item in queue
        try
            pd, rpath = item
            path = _file_path(pd, rpath)
            newdefs = _file_defs(path)
            olddefs = get(_SRC_DEFS, path, nothing)
            if olddefs === nothing
                union!(changed, keys(newdefs))                 # unseeded → report all (first edit)
            else
                for (nm, h) in newdefs                          # new or body-changed
                    get(olddefs, nm, nothing) == h || push!(changed, nm)
                end
                for nm in keys(olddefs)                         # removed
                    haskey(newdefs, nm) || push!(changed, nm)
                end
            end
            _SRC_DEFS[path] = newdefs
        catch
        end
    end
    return collect(changed)
end

# A Revise apply error → a short message (the file + reason), best-effort across Revise versions.
# Snapshot of the keys currently in Revise's (persistent) error queue.
_qe_keys(R) = try; isdefined(R, :queue_errors) ? Set(collect(keys(R.queue_errors))) : Set{Any}(); catch; Set{Any}(); end

# An error message IF this revise introduced one. `thrown` is a revise() throw; otherwise we
# compare queue_errors against `before` and only report errors NEW to this pass — `queue_errors`
# RETAINS old entries, so checking it absolutely would wedge us in the error branch forever
# (the bug behind "stopped notifying after a few edits").
function _revise_error_msg(R, thrown, before::Set)
    thrown === nothing || return first(sprint(showerror, thrown), 400)
    qe = try; isdefined(R, :queue_errors) ? R.queue_errors : nothing; catch; nothing; end
    qe === nothing && return ""
    newks = [k for k in keys(qe) if !(k in before)]
    isempty(newks) && return ""
    return try
        k = newks[1]; v = qe[k]; ex = v isa Tuple ? v[1] : v
        "$(basename(string(k))): $(first(sprint(showerror, ex), 300))"
    catch
        "Revise could not apply a source change."
    end
end

const _LAST_SRC_ERR = Ref{String}("")

# Resilient headless hot-reload. Revise's own file watchers populate `revision_queue`
# headlessly; we poll it, APPLY the revisions, and PUB either the changed def-names
# (`slate_revise`) or a parse/load error (`slate_revise_err`). Every iteration is wrapped so a
# bad/invalid save can NEVER kill the watcher — tracking resumes the instant the file parses
# again. Logs each pass so the worker log shows what hot-reload is doing.
function _start_src_watcher()
    if !isdefined(Main, :Revise)
        @info "slate hot-reload: Revise not loaded — disabled"
        return nothing
    end
    @info "slate hot-reload: watcher started"
    @async while true
        try
            sleep(0.4)
            R = Main.Revise
            _seed_new_src_defs!()             # baseline newly-loaded files so their first edit diffs cleanly
            (isdefined(R, :revision_queue) && !isempty(R.revision_queue)) || continue
            queue = collect(R.revision_queue)
            before = _qe_keys(R)
            thrown = nothing
            try; R.revise(); catch e; thrown = e; end
            emsg = _revise_error_msg(R, thrown, before)
            if !isempty(emsg)
                @warn "slate hot-reload: revise error" error = emsg
                if emsg != _LAST_SRC_ERR[]
                    _LAST_SRC_ERR[] = emsg
                    KaimonGate._publish_stream("slate_revise_err", emsg)
                end
            else
                _LAST_SRC_ERR[] = ""
                names = _changed_names(queue)
                @info "slate hot-reload: revised" files = length(queue) changed = names
                isempty(names) || KaimonGate._publish_stream("slate_revise", join(names, ","))
            end
        catch e
            try; @warn "slate hot-reload: watcher iteration failed" exception = e; catch; end
            try; sleep(0.5); catch; end
        end
    end
    return nothing
end

"Apply pending Revise revisions; return the changed top-level def names (manual / testing)."
function __slate_revise()
    isdefined(Main, :Revise) || return String[]
    queue = try; collect(Main.Revise.revision_queue); catch; Tuple[]; end
    try; Main.Revise.revise(); catch; end
    return _changed_names(queue)
end

"GateTools exposed to the KaimonSlate server."
function tools()
    return KaimonGate.GateTool[
        KaimonGate.GateTool("__slate_eval", __slate_eval),
        KaimonGate.GateTool("__slate_eval_batch", __slate_eval_batch),
        KaimonGate.GateTool("__slate_cancel", __slate_cancel),
        KaimonGate.GateTool("__slate_cancel_cells", __slate_cancel_cells),
        KaimonGate.GateTool("__slate_set_bind", __slate_set_bind),
        KaimonGate.GateTool("__slate_reset", __slate_reset),
        KaimonGate.GateTool("__slate_table_page", __slate_table_page),
        KaimonGate.GateTool("__slate_interp", __slate_interp),
        KaimonGate.GateTool("__slate_complete", __slate_complete),
        KaimonGate.GateTool("__slate_harvest_docs", __slate_harvest_docs),
        KaimonGate.GateTool("__slate_module_help", __slate_module_help),
        KaimonGate.GateTool("__slate_macroexpand", __slate_macroexpand),
        KaimonGate.GateTool("__slate_project_deps", __slate_project_deps),
        KaimonGate.GateTool("__slate_env_info", __slate_env_info),
        KaimonGate.GateTool("__slate_fork", __slate_fork),
        KaimonGate.GateTool("__slate_sync_parent", __slate_sync_parent),
        KaimonGate.GateTool("__slate_reconstruct", __slate_reconstruct),
        KaimonGate.GateTool("__slate_bundle_info", __slate_bundle_info),
        KaimonGate.GateTool("__slate_pkg", __slate_pkg),
        KaimonGate.GateTool("__slate_pkg_parent", __slate_pkg_parent),
        KaimonGate.GateTool("__slate_revise", __slate_revise),
    ]
end

"""
    start(; host="127.0.0.1", port, stream_port)

Run the worker gate over TCP, exposing the capture tools. Blocks (this is the
worker process's main loop).
"""
function start(; host::String = "127.0.0.1", port::Int, stream_port::Int,
               curve::Bool = false, allowed_clients::Vector{String} = String[])
    # Install the task-demux as stdout/stderr + a task-local capture display, so cell evaluators can
    # run CONCURRENTLY in this one process while each captures its own output (see demux.jl, capture.jl
    # DemuxCapture). Non-cell output falls through to the real streams (the worker log). Once installed,
    # all cell capture in this process MUST use DemuxCapture (RedirectCapture's restore can't redirect
    # back to the custom IO).
    try; install_demux!(); pushdisplay(_DemuxDisplay()); catch e; @warn "slate: demux install failed" exception = e; end
    # `curve`/`allowed_clients` are set for a REMOTE worker (host="0.0.0.0", :direct transport): the
    # hub pins THIS gate's CURVE server key (fetched over SSH) and the gate allow-lists the hub's client
    # key — proper mutual auth. Local + :ssh_tunnel workers leave them off (loopback / SSH-encrypted).
    KaimonGate.serve(; mode = :tcp, host = host, port = port, stream_port = stream_port,
                     tools = tools(), force = true, allow_mirror = false,
                     allow_restart = false, spawned_by = "slate",
                     curve = curve, allowed_clients = allowed_clients)
    _start_src_watcher()   # resilient /src hot-reload (Revise); no-op if Revise didn't load
    @info "slate worker: ready" port = port tools = length(tools()) revise = isdefined(Main, :Revise)
    # `serve` runs the message loop on a spawned thread and returns — but this is
    # a non-interactive `-e` process, so we must block to keep it alive until a
    # remote `:shutdown` (which calls `exit(0)` from the gate task). Flush each
    # tick so stdout/stderr (block-buffered when piped, not a TTY) reaches the
    # parent's log reader live rather than only on exit/crash.
    while true
        flush(stdout); flush(stderr)
        sleep(1)
    end
end

end # module SlateWorker
