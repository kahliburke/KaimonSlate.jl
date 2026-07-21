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
import Serialization                         # slate_emit value → bytes (unconditional; memo re-imports under its guard)
import Base64                                # …then base64 so an arbitrary Julia value rides the string stream
import Logging, Dates                        # timestamped worker log (legible after a slow bring-up / eval)
import Sockets                               # TCP reachability probe for peer-route resolution

# Cold-boot phase timing: a module-load timer so the payload's heavy blocks (memo layer, ExpressionExplorer)
# and start()'s socket bring-up self-report into the worker log — same `[slate-boot]` prefix the boot script
# uses. Cheap prints; this timer starts ~0.5s into the include, so add that to correlate with boot markers.
const _BOOT_T0 = time()
_blog(m) = try; println("[slate-boot] payload +" * string(round(time() - _BOOT_T0; digits = 1)) * "s " * m); flush(stdout); catch; end

# The enclosing/parent project dir stacked behind this notebook env on LOAD_PATH (set by
# the boot script; "" when the notebook is detached). Used to attribute package provenance
# — which deps are notebook-specific adds vs. inherited from the parent project.
const PARENT_PROJECT = Ref("")

# SHA of the worker payload this process BOOTED with (set from the boot script; "" for a local worker
# that inherits the hub's version). The hub compares it against the current payload on reattach and
# reprovisions a worker running stale code — see remote.jl `_payload_sha` / `attached!`.
const PAYLOAD_SHA = Ref("")

# Minimal ECharts marker so notebooks can `echart(opt)`. Only the struct + helper
# live here (no JSON); the server JSON-encodes the option Dict. `capture.jl`
# detects `value isa EChart` and ships back the raw Dict.
struct EChart
    option::Any
end
echart(option::AbstractDict) = EChart(Dict{String,Any}(string(k) => v for (k, v) in option))

include(joinpath(@__DIR__, "echarts_dsl.jl")) # echart(:line,…)/series DSL (shared with the engine)
include(joinpath(@__DIR__, "slate_look.jl")) # slate_theme()/use_slate_theme! — shared ECharts/Makie palette
include(joinpath(@__DIR__, "animation.jl")) # animate(frames;…) → Animation (used by capture.jl; shared)
include(joinpath(@__DIR__, "reactive.jl"))  # reactive/@onclick/pause async primitives (shared with the engine)
include(joinpath(@__DIR__, "tables.jl"))    # SlateTable / slate_table — uses no deps; soft-detects Tables.jl
include(joinpath(@__DIR__, "slate_matrix.jl")) # slate_matrix — auto-render for AbstractMatrix (used by capture.jl)
include(joinpath(@__DIR__, "trace.jl"))     # @trace / SlateTrace inline value tracing (engine + worker)
include(joinpath(@__DIR__, "paged.jl"))     # PagedProvider / SlatePagedTable / slate_query (provider registry)
include(joinpath(@__DIR__, "widgets.jl"))   # shared @bind widgets + namespace contract (engine + worker)
include(joinpath(@__DIR__, "envprep.jl"))   # shared notebook-env prep policy (seed/dev-path/staleness; engine + worker + remote)
include(joinpath(@__DIR__, "docharvest.jl")) # shared docstring harvest (runs where the deps are loaded)
include(joinpath(@__DIR__, "demux.jl"))     # task-demux output capture (parallel evaluator I/O isolation)
include(joinpath(@__DIR__, "parsched.jl"))  # ParCell / par_blockers / run_scheduled — parallel batch scheduler
include(joinpath(@__DIR__, "macroexpand.jl")) # _expand_cell_source — macro-aware deps (engine + worker)
include(joinpath(@__DIR__, "capture.jl"))   # run_capture — uses EChart + SlateTable above
include(joinpath(@__DIR__, "completion.jl")) # slate_completions — REPLCompletions in the NB namespace
include(joinpath(@__DIR__, "prepare.jl"))   # PrepareTracker — classify precompile output into structured status (shared w/ engine)

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
        # slate_emit(channel, value): push ANY Julia value to a browser handler (slateOnStream) — no
        # hand-built JSON. The gate stream frames are strings, so the value is Serialization-serialized
        # then base64'd and wired as `channel\x1fb64` (unit separator — absent from identifiers and from
        # base64's alphabet); the hub deserializes it back to a Julia value and JSON-encodes it for the
        # `cellstream:` frame. (In-process notebooks skip this and pass the value straight through.) Bulk
        # data belongs on the blob channel, not here — base64+serialize suits small streaming payloads.
        # A SlateBinary rides a raw binary frame on the `slate_emit_bin` channel (encode_binary_frame packs
        # channel+meta+dtype+shape+raw bytes) — published via `_publish_stream_raw` (multipart, NO
        # Serialization envelope: the frame moves by reference, copied only once at the wire) → forwarded as
        # a binary WS frame → a TypedArray in the browser. Any other value takes the string path
        # (Serialization+base64; the hub deserializes + JSON-encodes it).
        slate_emit = (channel, value) -> value isa SlateExtensionsBase.SlateBinary ?
            KaimonGate._publish_stream_raw("slate_emit_bin", SlateExtensionsBase.encode_binary_frame(string(channel), value)) :
            KaimonGate._publish_stream("slate_emit",
                string(channel) * "\x1f" * Base64.base64encode(Serialization.serialize, value)),
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
const _MEMO_ERR = Ref{Any}(nothing)   # why the memo layer failed to load (surfaced at boot + in traces)
const _MEMO_OK = try
    @eval import Serialization
    include(joinpath(@__DIR__, "memostore.jl"))
    include(joinpath(@__DIR__, "memocodecs.jl"))   # value↔bytes: jls fallback + raw/arrow fast paths
    include(joinpath(@__DIR__, "blobchannel.jl"))  # the blob data channel (server + direct-pull client)
    true
catch e
    _MEMO_ERR[] = e
    false
end

# Prefer a vendored, version-pinned OpenSSL (SHA-NI) for CAS content hashing when it's in the worker
# env; otherwise MemoStore falls back to the system libcrypto, then SHA.jl. Best-effort and isolated
# from the memo load above — a missing OpenSSL_jll must never disable memoization. `@eval` runs the
# import + path read in one latest-world step (no world-age on the fresh binding).
_MEMO_OK && try
    p = @eval begin
        import OpenSSL_jll
        if isdefined(OpenSSL_jll, :libcrypto_path)      # JLLWrappers const path
            String(OpenSSL_jll.libcrypto_path)
        else                                            # older String product / newer LazyLibrary
            lc = OpenSSL_jll.libcrypto
            lc isa AbstractString ? String(lc) : String(lc.path)
        end
    end
    MemoStore.set_libcrypto!(p)
catch
end
_blog("memo layer loaded (ok=$(_MEMO_OK))")   # memostore + codecs + blobchannel compiled
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
        # Resolve the cache HOME with the SAME precedence as SlateHome.cache_home() — a dedicated
        # `KAIMONSLATE_CACHE_HOME` (or the `KAIMONSLATE_HOME` shortcut) lets a worker pin its OWN
        # content store (e.g. a region isolating its CAS from co-located workers, which otherwise
        # share `~/.cache/kaimonslate/memo`) WITHOUT hijacking XDG_CACHE_HOME — that would relocate
        # every other tool's cache too. Falls back to XDG_CACHE_HOME, then ~/.cache. (SlateHome isn't
        # loaded in the worker, so its tiny resolver is inlined here.)
        cache = get(ENV, "KAIMONSLATE_CACHE_HOME", "")
        home  = get(ENV, "KAIMONSLATE_HOME", "")
        base = !isempty(cache) ? abspath(expanduser(cache)) :
               !isempty(home)  ? joinpath(abspath(expanduser(home)), "cache") :
               joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(get(ENV, "HOME", tempdir()), ".cache")), "kaimonslate")
        d = joinpath(base, "memo")
        try; mkpath(d); catch; d = joinpath(tempdir(), "kaimonslate-memo"); mkpath(d); end
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
                    # `_replicate_env!` rewrites remote dev paths as literal "~/…" — without
                    # expanduser the remote worker can't FIND the synced source it should digest,
                    # so its src_digest fell to the empty-constant while the local one didn't:
                    # divergent fullkeys, and every transferred memo entry missed (found live).
                    startswith(pd, "~") && (pd = expanduser(pd))
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
# HOST-PORTABLE: files are keyed by their path RELATIVE to their src root (never the absolute
# path — /Users/… locally vs ~/.cache/kaimonslate/remote/… on a host would fork the digest and
# make every transferred memo entry unfindable). rsync mirrors the tree, so relpaths + def-body
# hashes agree across hosts; entries sort by (relpath, defhash) so root ORDER can't matter either.
const _SRC_DIGEST_CACHE = Ref{Tuple{Float64,UInt}}((-1.0, UInt(0)))
function _src_digest()
    try; _seed_new_src_defs!(); catch; end          # keep seeding the hot-reload watcher's baseline
    files = _memo_src_files()
    isempty(files) && return UInt(0x53726300)        # nothing developed → a constant (deterministic)
    mt = try; maximum(mtime, files; init = 0.0); catch; 0.0; end
    _SRC_DIGEST_CACHE[][1] == mt && return _SRC_DIGEST_CACHE[][2]
    h = UInt(0x53726300)
    try
        entries = Tuple{String,UInt}[]
        for dir in _memo_src_dirs(), (root, _, fs) in walkdir(dir), f in fs
            endswith(f, ".jl") || continue
            p = joinpath(root, f)
            defs = _file_defs(p)
            dh = UInt(0)
            for k in sort!(collect(keys(defs))); dh = hash((k, defs[k]), dh); end
            push!(entries, (relpath(p, dir), dh))
        end
        sort!(entries)
        for e in entries; h = hash(e, h); end
    catch
    end
    _SRC_DIGEST_CACHE[] = (mt, h)
    return h
end

# Digest of the notebook env's DIRECT deps → resolved versions (Project [deps] minus the
# worker-infra adds KaimonGate/Revise). HOST-PORTABLE by construction: the remote worker env is
# the notebook env RESOLVED TOGETHER with that infra, so whole-Manifest bytes can never match
# across hosts (found live: local 4239… vs remote f48c… made every transferred entry miss).
# The user's own name→version/tree-sha pairs are the behavior-pinning, host-invariant core.
const _MANIFEST_DIGEST = Ref{Tuple{Float64,UInt}}((-1.0, UInt(0)))
const _INFRA_DEPS = ("KaimonGate", "Revise", "ExpressionExplorer")   # mirror _WORKER_INFRA_PKGS (server_history.jl)
function _manifest_digest()
    try
        proj = Base.active_project(); proj === nothing && return UInt(0)
        man = joinpath(dirname(proj), "Manifest.toml"); isfile(man) || return UInt(0)
        mt = Float64(mtime(man))
        _MANIFEST_DIGEST[][1] == mt && return _MANIFEST_DIGEST[][2]
        # Real TOML parsing (via MemoStore's stdlib import — the memo guard covers us): the
        # notebook's direct deps from Project [deps], each mapped to its resolved
        # version/tree-sha in the Manifest (format-2 layout: top-level "deps" → name → [entry]).
        pdeps = sort!([d for d in keys(get(MemoStore.TOML.parsefile(proj), "deps", Dict{String,Any}()))
                       if !(d in _INFRA_DEPS)])
        mdeps = get(MemoStore.TOML.parsefile(man), "deps", Dict{String,Any}())
        h = UInt(0x4d616e00)
        for dn in pdeps
            e = get(mdeps, dn, nothing)
            ver = (e isa Vector && !isempty(e) && e[1] isa AbstractDict) ?
                  string(get(e[1], "version", ""), get(e[1], "git-tree-sha1", "")) : ""
            h = hash((dn, ver), h)
        end
        _MANIFEST_DIGEST[] = (mt, h); return h
    catch; return UInt(0); end
end

# The FULL entry key: the server's memo_key (cell + upstream sources + binds + assets) with the
# worker-side src/ and Manifest digests folded in. Names the manifest in the store (fmt 3); the
# entry's DATA lives in content-addressed blobs the manifest references, so a re-key with
# unchanged values (e.g. any src/ edit restaling every entry) re-stores only ~1 KB of manifest —
# every data byte dedups against the blobs already on disk.
function _memo_key_parts(cellkey::AbstractString)
    sd = _src_digest(); md = _manifest_digest()
    return (fullkey = string(hash((String(cellkey), sd, md)); base = 16),
            src_digest = string(sd; base = 16), manifest_digest = string(md; base = 16))
end

function _memo_fullkey(cellkey::AbstractString)
    p = _memo_key_parts(cellkey)
    # Opt-in diagnostic: log the two digests that complete the cache key, so a store-run vs a
    # restore-run can be compared to see which one drifts (→ near-total cache misses). KAIMONSLATE_MEMO_DEBUG=1.
    get(ENV, "KAIMONSLATE_MEMO_DEBUG", "") == "1" &&
        @info "slate memo key" cell = String(cellkey) src_digest = p.src_digest manifest_digest = p.manifest_digest
    return p.fullkey
end

# ── Memo trace: the durable-cache decision record, per cell ──────────────────────────────────
# Every memoized eval leaves a small record of WHAT the memo layer did and WHY — action
# (restored/stored/recomputed/forced/off/unkeyed), the full key and its component digests, the
# per-binding blobs (name/codec/bytes/sha) it read or wrote, and the miss reason when it fell
# through to a recompute. This turns cache debugging from "mint a rand token and diff it across
# hosts" into one direct question: `slate.memo_trace(notebook, cell)`. Always on — it's a few
# strings per cell (the digests are mtime-cached), keyed by cell id, latest eval wins.
const _MEMO_TRACE = Dict{String,Dict{String,Any}}()
const _MEMO_TRACE_LOCK = ReentrantLock()

_trace_commit!(cid::String, tr::Dict{String,Any}) =
    (tr["ts"] = round(Int, time()); lock(_MEMO_TRACE_LOCK) do; _MEMO_TRACE[cid] = tr; end; nothing)

"Memo decision record for `cell` (or all cells when empty): what the durable cache did on the
latest eval — restored/stored/recomputed + why, the full key, its src/manifest digests, and the
blobs involved. The direct probe for 'why did this cell (not) restore?'. (`cell` is a kwarg —
GateTool drops optional positionals.)"
function __slate_memo_trace(; cell::String = "")
    lock(_MEMO_TRACE_LOCK) do
        isempty(cell) ? Dict{String,Any}(k => copy(v) for (k, v) in _MEMO_TRACE) :
        haskey(_MEMO_TRACE, cell) ? copy(_MEMO_TRACE[cell]) :
        Dict{String,Any}("action" => "none", "note" => "no memoized eval recorded for cell '$cell' this session")
    end
end

"Pin (`pin=true`) or release (`pin=false`) `key`'s CURRENT fullkey against `gc` eviction — the
`locked` cell tag's durability guarantee. No-op (`ok=false`) if the memo layer is off or `key` is
empty (an unkeyable cell has nothing to pin)."
function __slate_memo_pin(; key::String = "", pin::Bool = true)
    (_MEMO_OK && !isempty(key)) || return Dict{String,Any}("ok" => false)
    try
        MemoStore.set_pin!(_memo_dir(), _memo_fullkey(key), pin)
        return Dict{String,Any}("ok" => true)
    catch e
        return Dict{String,Any}("ok" => false, "message" => sprint(showerror, e))
    end
end

# Snapshot the CURRENT namespace values for the given memoizable cells into the durable store,
# BYPASSING the auto-store time threshold — so a standalone export can offer every memoizable
# result for embedding, not just the cells that happened to run slow. `cells` maps cell-id →
# {key (the server-side srckey), names, unread, safe, ms}. Reuses `_memo_store` (which reads the
# live namespace by name), so nothing recomputes — it just serialises what's already computed.
# Returns id → {fullkey, bytes, stored}: `stored=false` when a value wouldn't serialise; `bytes`
# is the entry's on-disk footprint (for the export UI's size/density ranking). For a DATA cell the
# stored wire is minimal (`duration_ms` + value_repr) — its VALUE blobs are what a restore injects,
# and rich display comes from the preview; a WIRE-ONLY display cell (a self-theming plot) instead
# reports the real-wire entry from its last interactive run, so its figure ships and restores on
# import. NOTE: `cells` MUST be a keyword arg (raw-Dict fast-path
# caveat — see __slate_macroexpand); nested dicts may arrive symbol-keyed, hence `_g` dual-lookup.
function __slate_memo_snapshot(; cells::Dict = Dict{String,Any}())
    out = Dict{String,Any}()
    _MEMO_OK || return out
    root = _memo_dir()
    _g(d, k, dv) = haskey(d, k) ? d[k] : get(d, Symbol(k), dv)
    _strs(x) = String[String(v) for v in (x isa AbstractVector ? x : Any[])]
    for (id, spec) in cells
        spec isa AbstractDict || continue
        key = String(_g(spec, "key", "")); isempty(key) && continue
        names = _strs(_g(spec, "names", Any[]))
        fk = _memo_fullkey(key)
        if isempty(names)
            # Wire-only (display) cell — a self-theming plot / pure figure. It has no data binding to
            # snapshot, and its figure wire can't be reconstructed here (it came from a real render).
            # Report the entry from the last interactive run if one exists, so export can embed the
            # cached figure (→ restores on import instead of re-rendering); skip if never run/stored.
            # Do NOT force-store: that would overwrite the real figure wire with a synthetic blank one.
            exists = try; MemoStore.read_manifest(root, fk) !== nothing; catch; false; end
            out[String(id)] = Dict{String,Any}("fullkey" => fk, "stored" => exists,
                                               "bytes" => MemoStore.entry_bytes(root, fk))
            continue
        end
        unread = _strs(_g(spec, "unread", Any[])); safe = _strs(_g(spec, "safe", Any[]))
        ms = try; Float64(_g(spec, "ms", 0.0)); catch; 0.0; end
        vrepr = String(_g(spec, "value_repr", ""))
        # A VALID wire in the same shape a real run produces (empty display + the cell's value repr).
        # The per-binding VALUE blobs are what a restore injects; the rich display (charts/figures)
        # comes from the embedded preview. A minimal `(; duration_ms)` wire crashes the restore path,
        # which accesses `wire.mime` — that must never happen (see _memo_restore's shape guard).
        wire = (stdout = "", mime = Tuple{String,Vector{UInt8}}[], echarts = Any[], tables = Any[],
                binds = NamedTuple[], value_repr = vrepr, exception = nothing, backtrace = nothing,
                duration_ms = ms, trace = Any[], stderr = "", overflow = NamedTuple[], animations = Any[])
        ok = try
            _memo_store(key, names, wire; unread = unread, safe = safe)
        catch
            false
        end
        out[String(id)] = Dict{String,Any}("fullkey" => fk, "stored" => (ok === true),
                                           "bytes" => MemoStore.entry_bytes(root, fk))
    end
    return out
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
function _memo_restore(cellkey::String; unread::Vector{String} = String[],
                       trace::Union{Nothing,Dict{String,Any}} = nothing)
    # `trace` (when given) receives the decision detail — a hit's per-binding blobs, or the exact
    # miss reason. `miss(why)` centralizes the fall-through so no exit forgets to explain itself.
    miss(why) = (trace === nothing || (trace["miss"] = why); nothing)
    _MEMO_OK || return miss("memo layer disabled (see worker boot log)")
    root = _memo_dir(); key = _memo_fullkey(cellkey)
    mf = MemoStore.read_manifest(root, key)
    mf === nothing && return miss("no manifest for fullkey $key")
    # An entry that ELIDED a display object (stored the wire image, not the object — see
    # `_memo_store`) is only faithful while that name stays UNREAD. A reader added since means the
    # real object is needed → treat as a miss; the re-run re-stores WITH the object (its name is no
    # longer in `unread`). Self-healing, no key games.
    for e in get(mf, "elided", Any[])
        e isa AbstractDict || return miss("malformed manifest (elided entry)")
        nm = String(get(e, "name", ""))
        nm in unread || return miss("elided display object '$nm' now has a reader — re-run stores the real object")
    end
    binds = Tuple{Symbol,Any}[]
    restored = Dict{String,Any}[]
    for b in get(mf, "bindings", Any[])
        b isa AbstractDict || return miss("malformed manifest (binding entry)")
        h = String(get(b, "blob", "")); nm = String(get(b, "name", ""))
        p = MemoStore.blob_path(root, h)
        isfile(p) || return miss("binding '$nm' blob missing on disk ($(first(h, 12))…)")
        # Codec-dispatched decode (path-based: raw/arrow mmap the blob file in place). A codec
        # whose package isn't loaded yet, or any decode failure, is a clean miss → recompute.
        codec = String(get(b, "codec", "jls"))
        v = try
            _codec_decode(codec, p, get(b, "zc", false) === true)
        catch e
            return miss("binding '$nm' $codec decode failed: $(first(sprint(showerror, e), 120))")
        end
        push!(binds, (Symbol(nm), v))
        push!(restored, Dict{String,Any}("name" => nm, "codec" => codec,
                                         "bytes" => get(b, "bytes", 0), "blob" => first(h, 12)))
    end
    w = get(mf, "wire", nothing)
    w isa AbstractDict || return miss("malformed manifest (no wire)")
    ok, wire = try
        MemoStore.with_blob(io -> Serialization.deserialize(io), root, String(get(w, "blob", "")))
    catch
        (false, nothing)
    end
    ok || return miss("wire blob missing or undeserializable")
    # Wire shape guard: the wire must look like a run capture (has `mime`) — the server accesses
    # `wire.mime`/`.echarts`/… on it. An entry written by an incompatible/older store (e.g. a
    # bad-shape snapshot wire) would crash the cell on restore; treat it as a MISS so the cell
    # recomputes and RE-STORES a valid entry, self-healing the store. Checked BEFORE any binds are
    # assigned, so a rejected entry never half-mutates the namespace.
    hasproperty(wire, :mime) || return miss("incompatible wire shape (stale entry) — recomputing")
    m = _NS[]
    for (s, v) in binds
        try; Core.eval(m, :($s = $v)); catch; return miss("assigning restored global '$s' failed"); end
    end
    MemoStore.touch_manifest(root, key)             # mark as recently used (LRU root)
    if trace !== nothing
        trace["bindings"] = restored
        trace["stored_ms"] = get(mf, "ms", 0.0)      # what the entry originally cost to compute
        trace["created"] = get(mf, "created", 0)
    end
    return wire
end

# The leaf name of a call's callee: `set_theme!` → :set_theme!, `CairoMakie.set_theme!` → :set_theme!.
_call_leaf(f) = f isa Symbol ? f :
                (f isa Expr && f.head === :. && length(f.args) == 2 && f.args[2] isa QuoteNode) ?
                    f.args[2].value : nothing
# Collect every theme-setter CALL expression (`_THEME_CALL_NAMES` — see graphics_detect.jl)
# anywhere in `ex` (they're typically nested inside a plot cell's `let … end`, so a top-level
# scan misses them).
function _collect_theme_calls!(acc::Vector{Any}, ex)
    ex isa Expr || return acc
    (ex.head === :call && _call_leaf(ex.args[1]) in _THEME_CALL_NAMES) && push!(acc, ex)
    for a in ex.args; _collect_theme_calls!(acc, a); end
    return acc
end

# Re-execute a restored cell's cheap GLOBAL side effects — its top-level `using`/`import` statements
# and any theme-setter call (`_THEME_CALL_NAMES`) — so the process state matches what the skipped run
# would have left, for any downstream cell that later RE-RUNS. `using`: keeps imported names +
# method tables in scope (a NOVEL `using X`, the sole importer of X, is re-established here). Theme:
# re-applies the global Makie theme (the rendered figure itself rides the cached wire image; this
# just fixes the ambient theme a re-running sibling would render against). Both effects are pure
# functions of (source, environment), so replaying reproduces the real run. Returns false if any
# replay throws (→ caller distrusts the restore and recomputes) — e.g. a `set_theme!(local_var)`
# referencing a cell-local, or a package that stored fine but won't `using` now (a real env change).
function _replay_scaffold!(m::Module, source::AbstractString)
    top = try; Meta.parseall(String(source)); catch; return true; end   # unparseable → nothing to replay
    stmts = (top isa Expr && top.head === :toplevel) ? top.args : Any[top]
    for s in stmts                                   # top-level using/import — bring names into scope
        s isa LineNumberNode && continue
        (s isa Expr && s.head in (:using, :import)) || continue
        try; Base.invokelatest(Core.eval, m, s)
        catch e; @info "slate memo: import replay failed on restore — recomputing" reason = first(split(sprint(showerror, e), '\n')); return false; end
    end
    for s in stmts                                   # top-level `@bind name W(…)` — RE-REGISTER the widget
        s isa LineNumberNode && continue             # (assign the control global) without running the cell's
        # compute. `@bind` expands to `name = __slate_bind(:name, W)`, so evaluating it re-establishes the
        # per-namespace registry entry + the global; `_do_bind` reconciles the value against the registry
        # (seeded with the host's current value on a fresh namespace), NOT the widget default. Runs AFTER
        # the imports above so a data-dependent widget (`Select(sort(keys(d)))`) sees its upstream names.
        (s isa Expr && s.head === :macrocall && s.args[1] === Symbol("@bind")) || continue
        try; Base.invokelatest(Core.eval, m, s)
        catch e; @info "slate memo: @bind replay failed on restore — recomputing" reason = first(split(sprint(showerror, e), '\n')); return false; end
    end
    for call in _collect_theme_calls!(Any[], top)    # set_theme!/update_theme! — restore the ambient theme
        try; Base.invokelatest(Core.eval, m, call)
        catch e; @info "slate memo: theme replay failed on restore — recomputing" reason = first(split(sprint(showerror, e), '\n')); return false; end
    end
    return true
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
# a large scene graph and seconds to serialize for a chart whose RENDERED image already rides the
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
                     unread::Vector{String} = String[], safe::Vector{String} = String[],
                     trace::Union{Nothing,Dict{String,Any}} = nothing)
    fail(why) = (trace === nothing || (trace["store_fail"] = why); false)
    _MEMO_OK || return fail("memo layer disabled (see worker boot log)")
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
        # A NOTEBOOK-DEFINED function (or closure) can't be faithfully cached: jls serialises it by
        # its defining module + name, and on RESTORE in a reconstructed notebook that module has a
        # different name (`Main.<rebuilt>` vs the original), so the decode throws `UndefVarError`.
        # These are cheap to recompute anyway (a def), so ABORT the whole entry rather than embed a
        # value that can't come back — restoring the cell's other bindings without this one would be
        # unfaithful (the function would be undefined downstream). Package functions (parentmodule ≠
        # the notebook module) serialise fine and are kept.
        if v isa Function && parentmodule(v) === m
            return fail("cell defines the notebook-local function '$nm' — not cacheable (restores unfaithfully)")
        end
        # A live process-state handle (DB/socket/file — a non-null Ptr) serialises to a dangling pointer,
        # so a restore hands back a dead handle. Refuse to cache it (this is what `:resource` DECLARES;
        # the user just hasn't tagged it) and record a hint so the UI can SUGGEST the tag — the author-
        # time advisory, caught here before a stale restore or a region transfer bites.
        let why = _unportable_reason(v)
            if !isempty(why)
                trace === nothing || (trace["handle_hint"] =
                    Dict{String,Any}("name" => nm, "type" => string(typeof(v)), "reason" => why))
                @info "slate memo: not cached — live handle; tag the cell `resource`" cell = cellkey name = nm type = string(typeof(v))
                return fail("'$nm' is a live handle ($(string(typeof(v)))) — not cacheable; tag the cell `resource`")
            end
        end
        if nm in unread && _is_display_object(v)
            push!(elided, Dict{String,Any}("name" => nm, "type" => string(typeof(v))))
            @info "slate memo: display object elided (wire image only)" cell = cellkey name = nm
            continue
        end
        codec = try; _codec_pick(v); catch; "jls"; end
        h, n = try
            try
                MemoStore.put_blob(io -> _codec_encode(io, codec, v), root)
            catch e1
                # A fast codec choking on an exotic value (e.g. Arrow vs a custom column type)
                # must not cost the entry — demote THIS NAME to jls and keep going.
                codec == "jls" && rethrow()
                @info "slate memo: $(codec) encode failed — falling back to jls" name = nm reason = first(split(sprint(showerror, e1), '\n'))
                codec = "jls"
                MemoStore.put_blob(io -> _codec_encode(io, "jls", v), root)
            end
        catch e
            @info "slate memo: not cached — a binding won't serialize" cell = cellkey name = nm codec = codec reason = first(split(sprint(showerror, e), '\n'))
            return fail("binding '$nm' won't serialize ($codec): $(first(sprint(showerror, e), 120))")
        end
        # `zc`: the graph proved (at store time) that nothing downstream MUTATES this name, so
        # restore may hand back a read-only mmap / arrow-backed view instead of a copy. A mutator
        # added later throws ReadOnlyMemoryError (safe), and one producer re-run re-stores zc=false.
        push!(entries, Dict{String,Any}("name" => nm, "codec" => codec, "blob" => h, "bytes" => n,
                                        "zc" => (nm in safe)))
    end
    try
        wh, wn = MemoStore.put_blob(io -> Serialization.serialize(io, wire), root)
        mf = Dict{String,Any}(
            "srckey" => String(cellkey),            # the server half of the key (diagnostics)
            # what this entry COST to compute — the transfer-vs-recompute heuristic's key input
            # (bytes are per-binding below; bandwidth comes from the data channel measuring itself)
            "ms" => (hasproperty(wire, :duration_ms) ? round(Float64(wire.duration_ms); digits = 1) : 0.0),
            "created" => round(Int, time()),
            "julia" => string(VERSION),
            "bindings" => entries,
            "wire" => Dict{String,Any}("codec" => "jls", "blob" => wh, "bytes" => wn))
        isempty(elided) || (mf["elided"] = elided)  # restore checks these against CURRENT readers
        MemoStore.write_manifest(root, key, mf)
        _memo_gc()
        if trace !== nothing
            trace["bindings"] = [Dict{String,Any}("name" => e["name"], "codec" => e["codec"],
                                                  "bytes" => e["bytes"], "blob" => first(String(e["blob"]), 12))
                                 for e in entries]
            isempty(elided) || (trace["elided"] = [String(e["name"]) for e in elided])
        end
        return true
    catch e
        @info "slate memo: not cached" cell = cellkey reason = first(split(sprint(showerror, e), '\n'))
        return fail("manifest/wire write failed: $(first(sprint(showerror, e), 120))")
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
                   memo_unread::Vector{String} = String[], memo_safe::Vector{String} = String[];
                   slate_ctx = nothing)
    cid = replace(filename, r"^cell:" => "")
    # The decision record for this eval (see _MEMO_TRACE): filled in as the memo layer acts,
    # committed at every exit — `slate.memo_trace` reads it back.
    tr = Dict{String,Any}("srckey" => memo_key)
    if !isempty(memo_key) && _MEMO_OK
        p = _memo_key_parts(memo_key)
        tr["fullkey"] = p.fullkey; tr["src_digest"] = p.src_digest; tr["manifest_digest"] = p.manifest_digest
    end
    # `memo_force` (the ▶ play button): an explicit run request — never satisfy it from the cache.
    # The fresh result still stores below, replacing the entry.
    if !isempty(memo_key) && !memo_force
        w = _memo_restore(memo_key; unread = memo_unread, trace = tr)
        # A restored cell is memoized WITHOUT running its source, so its cheap global side effects —
        # `using X` (a provider's imported names) and `set_theme!` (the ambient Makie theme) — are
        # replayed here so any downstream cell that later re-runs sees the right scope + theme. A
        # replay failure (env changed under us) distrusts the entry → fall through to a full
        # recompute rather than serve a half-scoped restore.
        if w !== nothing && _replay_scaffold!(_NS[], source)
            @info "slate memo: restored (no recompute)" cell = cid
            tr["action"] = "restored"
            _trace_commit!(cid, tr)
            return merge(w, (memo = "restored",))   # tell the server this run came from the durable cache
        end
    elseif !isempty(memo_key) && memo_force
        tr["miss"] = "explicit ▶ run (memo_force) — restore skipped, fresh result re-stores"
    end
    local r
    try
        r = run_capture(_NS[], source, filename; capture = DemuxCapture(), slate_ctx = slate_ctx)
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
        if _memo_store(memo_key, memo_names, r; unread = memo_unread, safe = memo_safe, trace = tr)
            @info "slate memo: cached" cell = cid ms = round(r.duration_ms; digits = 1)
            tr["action"] = "stored"; tr["ms"] = round(r.duration_ms; digits = 1)
            _trace_commit!(cid, tr)
            return merge(r, (memo = "stored",))
        end
        tr["action"] = "recomputed"                  # ran fine but the store itself failed (see store_fail)
    elseif isempty(memo_key)
        tr["action"] = "unkeyed"
        tr["note"] = "no memo key — cell not memoizable (markdown/using/binds/volatile) or memo off hub-side"
    elseif r.exception !== nothing
        tr["action"] = "recomputed"; tr["note"] = "cell errored — errors are never cached"
    else
        tr["action"] = "recomputed"
        tr["note"] = "below threshold ($(round(r.duration_ms; digits = 1))ms < $(memo_threshold)ms) and no `cache` tag"
    end
    tr["ms"] = round(r.duration_ms; digits = 1)
    _trace_commit!(cid, tr)
    # A cell that writes a live handle can't be cached (and shouldn't cross a region) — surface it as a
    # `handle` memo status (reusing the existing memo field) so the UI can nudge the `resource` tag; the
    # binding name/type live in the memo trace (`slate_memo_trace`). This is the author-time advisory.
    haskey(tr, "handle_hint") && return merge(r, (memo = "handle", memo_why = String(get(tr, "store_fail", ""))))
    # A keyed, expensive cell whose STORE failed for another reason (defines a notebook-local function,
    # an unserializable global, a manifest write error) — surface it as `uncacheable` WITH the reason so
    # the badge explains why it won't persist. `store_fail` is set only when a store was actually
    # attempted (keyed + over threshold), so an unkeyed / below-threshold cell never lands here.
    (haskey(tr, "store_fail") && !isempty(memo_key)) &&
        return merge(r, (memo = "uncacheable", memo_why = String(tr["store_fail"])))
    return r
end

"Evaluate a cell's source in the warm namespace; return the wire-form capture. `filename` (a
kwarg — GateTool drops optional positionals) becomes the parse/backtrace location, `cell:<id>`.
`memo_*` (when set) enable durable caching: restore an expensive cell's result on a cold start, or
persist it after a run that exceeds `memo_threshold` ms."
function __slate_eval(source::String; filename::String = "string",
                     memo_key::String = "", memo_names::Vector{String} = String[],
                     memo_threshold::Float64 = 0.0, memo_force::Bool = false,
                     memo_always::Bool = false, memo_unread::Vector{String} = String[],
                     memo_safe::Vector{String} = String[],
                     ctx_region::String = "", ctx_notebook::String = "",
                     ctx_regions::Vector{String} = String[])
    # Register this eval's task under its cell id so __slate_cancel can interrupt it (the server runs
    # parallel cells as concurrent __slate_eval calls; a stop throws InterruptException into them).
    cid = replace(filename, r"^cell:" => "")
    lock(_CANCEL_LOCK) do; _RUNNING_TASKS[cid] = current_task(); end
    # Rebuild the Slate execution context from the hub's `ctx_*` args, adding this worker's own
    # `slate_emit` (which PUBs on the gate stream) — cell code reads it via `slate_context()`.
    ctx = _build_slate_ctx(_NS[], ctx_notebook, ctx_region, ctx_regions)
    try
        return _eval_one(source, filename, memo_key, memo_names, memo_threshold, memo_force,
                         memo_always, memo_unread, memo_safe; slate_ctx = ctx)
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
const _WARM_STATUS = Ref{String}("")     # pool worker's preload/precompile progress → telemetry → pool UI
const _LAST_HUB_REQ = Ref(time())        # wall time of the last hub heartbeat (__slate_running) — the spin-guard's orphan signal
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

# JS→Julia CALL — the `window.slateCall` counterpart to `slate_emit`'s one-way push. Look up the
# handler a cell registered with `slate_on(channel, …)` in the LIVE namespace and invoke it with the
# caller's (already-decoded) args. Dispatched off the page WebSocket over the gate's REQ/REP, so it
# rides the interactive path and stays responsive even while a compute batch runs. Returns
# `(; ok, value)` (the hub JSON-encodes `value` for the socket) or `(; ok=false, error)` — a missing
# channel or a throwing handler is a clean error, never a hang.
function __slate_call(channel::String, args; call_id::String = "")
    m = _NS[]
    hs = try; Base.invokelatest(getglobal, m, :__slate_handlers); catch; nothing; end
    (hs isa AbstractDict) || return (; ok = false, error = "call handlers unavailable on this worker")
    f = get(hs, String(channel), nothing)
    f === nothing && return (; ok = false, error = "no slate_on handler registered for channel '$channel'")
    # A 2-arg handler `(args, progress) -> …` gets a `progress` closure: it streams a frame on the reserved
    # `__slate_call_progress` emit channel carrying THIS call's id, which the browser routes to the call's
    # onProgress (no user-visible token). Reuses the slate_emit transport (publish → poller → WS).
    progress = isempty(call_id) ? (p -> nothing) :
        (p -> (try
            KaimonGate._publish_stream("slate_emit", "__slate_call_progress\x1f" *
                Base64.base64encode(Serialization.serialize, (id = call_id, data = p)))
        catch; end; nothing))
    try
        # Establish the per-cell execution context for the handler task, so a package that STREAMS from its
        # `slate_on` action — `slate_emit`/`slate_effect` via SlateExtensionsBase's ctx accessors — works the
        # same inside a handler as inside a cell eval. Without this, `slate_emit` in a handler is a silent
        # no-op (its `_ctx_field(:emit)` is unset). A browser call is main-side, so no region/notebook needed.
        ctx = _build_slate_ctx(m, "", "", String[])
        return task_local_storage(:slate_ctx, ctx) do
            (; ok = true, value = _invoke_slate_handler(f, _slate_args(args), progress))   # Dict → NamedTuple so the handler reads `args.field`
        end
    catch e
        return (; ok = false, error = first(sprint(showerror, e), 400))
    end
end

"Discard the namespace (full rebuild)."
__slate_reset() = (@info "slate: namespace reset (fresh rebuild)"; _NS[] = _new_ns(); true)

"Encode the namespace global `name` into this worker's content-addressed store and return its
address — `(; hash, codec, bytes)` (or `(; error)`). One half of cross-kernel value transport
(region runner): the hub moves the blob to the other worker's CAS over the data channel (or the
filesystem, when that worker is local) and calls `__slate_bind_blob` there. Codec-picked like
the memo store (arrow/raw/jls), so a DataFrame crosses as mmap-ready Arrow IPC."
function __slate_blob_of(name::String; cellkey::String = "")
    _MEMO_OK || return (; error = "memo/blob layer disabled on this worker")
    m = _NS[]
    s = Symbol(name)
    if !Base.invokelatest(isdefined, m, s)
        # The live global is gone — this worker was SWAPPED (fresh namespace) after the value was produced,
        # yet the producing cell's result is durable in the memo store. Restore it from there so the
        # cross-region transfer succeeds instead of erroring "no global named". The hub supplies the
        # producing cell's `cellkey` (the worker's own name→cell index doesn't survive the swap that caused
        # this). A non-memoized producer has no entry to restore → the cell must re-run on its side first.
        restored = !isempty(cellkey) && (try; _memo_restore(cellkey) !== nothing; catch; false; end)
        m = _NS[]
        (restored && Base.invokelatest(isdefined, m, s)) || return (; error = "no global named '$name'" *
            (isempty(cellkey) ? "" : " (absent from the live namespace and no memo entry restores it — its cell must re-run on its side)"))
    end
    v = Base.invokelatest(getglobal, m, s)
    codec = try; _codec_pick(v); catch; "jls"; end
    h, n = try
        try
            MemoStore.put_blob(io -> _codec_encode(io, codec, v), _memo_dir())
        catch
            codec == "jls" && rethrow()
            codec = "jls"
            MemoStore.put_blob(io -> _codec_encode(io, "jls", v), _memo_dir())
        end
    catch e
        return (; error = "'$name' won't serialize: " * first(sprint(showerror, e), 160))
    end
    return (; hash = h, codec = codec, bytes = n)
end

"Decode the CAS blob `hash` (already present in THIS worker's store) with `codec` and assign it
to the namespace global `name` — the other half of cross-kernel value transport. `zc=true`
allows a zero-copy (mmap/arrow-view) materialization when the graph proved nothing mutates it."
function __slate_bind_blob(name::String, hash::String, codec::String; zc::Bool = false)
    _MEMO_OK || return (; error = "memo/blob layer disabled on this worker")
    p = MemoStore.blob_path(_memo_dir(), hash)
    isfile(p) || return (; error = "blob $hash not in this worker's store")
    v = try
        _codec_decode(codec, p, zc)
    catch e
        return (; error = "decode failed ($codec): " * first(sprint(showerror, e), 160))
    end
    s = Symbol(name)
    try
        Core.eval(_NS[], :($s = $v))
    catch e
        return (; error = "assign failed: " * first(sprint(showerror, e), 160))
    end
    return (; ok = true)
end

# ── Direct worker→worker blob transport (the brokered mesh — blobchannel.jl + WORKER_CHANNEL_SPIKE.md) ──
# The star path moves a cross-region value A→hub→B (`transfer_binding!` relays through the hub's CAS).
# These four tools let the HUB instead BROKER a direct A→B pull: it reads B's client key, authorises it
# on A's blob channel (`authorize_client!`), hands B A's data endpoint, and B pulls the blob straight
# from A into its own CAS — one leg, no hub relay. The hub drives each step via `_tool`; a worker never
# initiates on its own. Generic transport — no notebook/graph specifics.

"This worker's CURVE client PUBLIC key (Z85) — the hub reads it to authorise this worker as a puller on
a peer's blob channel. Public key only; the secret never leaves the process."
function __slate_client_key()
    try
        pub, _ = KaimonGate._load_or_create_client_keypair()
        return (; key = pub)
    catch e
        return (; error = "no client keypair: " * first(sprint(showerror, e), 120))
    end
end

"This worker's blob-channel CURVE server PUBLIC key (Z85) — the hub reads it to connect as a CURVE client
(pinning us as the server). The blob channel is ALWAYS CURVE (PEER_TUNNEL_PLAN §2); on a CURVE gate this
is the gate's server key, and on a plaintext-gate (`:tunnel`) worker it's the persisted `server.key`'s
public half (the same key the blob server binds with). Public key only; the secret never leaves the
process. Symmetric with `__slate_client_key`."
function __slate_server_key()
    try
        pub = try; KaimonGate._CURVE_SERVER_PUBLIC[]; catch; ""; end
        isempty(pub) && ((pub, _) = KaimonGate._load_or_create_server_keypair())
        return (; key = pub)
    catch e
        return (; error = "no server keypair: " * first(sprint(showerror, e), 120))
    end
end

"The two auxiliary ports THIS worker bound, so the hub owns only the gate port (its first-contact anchor)
and LEARNS the rest over the gate — no `gate+1`/`gate+2` assumption (PEER_TUNNEL_PLAN §2). `stream` is the
telemetry/output PUB port (hub-assigned today); `blob` is the data-channel port, which a `:tunnel` worker
picks as a VERIFIED-FREE port (never `gate+2`) so a co-tenant holding `gate+2` on a shared host can't stall
it. `blob = 0` until the (boot-deferred) blob server has bound. Never throws."
function __slate_ports()
    return (; stream = _STREAM_PORT[], blob = _BLOB_DATA_PORT[])
end

"Authorise `pubkey` (a peer worker's Z85 client public key) on THIS worker's BLOB-channel allow-list so
it may connect to this worker's blob server — blob-pull rights ONLY, never the control gate (the blob
channel has its own ZAP handler + allow-file; PEER_TUNNEL_PLAN §2). Hub-brokered; takes effect on the
peer's next handshake (the handler re-reads the list per handshake). Returns (; status) — \"added\"/\"already\"."
function __slate_authorize_client(pubkey::String)
    try
        return (; status = String(_authorize_blob_client!(pubkey)))
    catch e
        return (; error = first(sprint(showerror, e), 140))
    end
end

"Revoke a previously-authorised peer client `pubkey` from THIS worker's blob-channel allow-list
(post-transfer cleanup). Returns (; status) — \"removed\"/\"absent\"."
function __slate_revoke_client(pubkey::String)
    try
        return (; status = String(_revoke_blob_client!(pubkey)))
    catch e
        return (; error = first(sprint(showerror, e), 140))
    end
end

# Peer-pull tuning for potentially-SLOW links (cross-cloud direct, or the ssh bridge). The default 8 MB
# chunk × 20 s recv timeout fails below ~400 KB/s — a real cross-cloud rate. A smaller chunk bounds the
# time each REQ/REP round-trip needs (so a thin link doesn't blow the recv timeout AND progress is visible
# more often), and a generous per-chunk timeout tolerates a slow-but-progressing transfer. Env-overridable.
_peer_pull_chunk()      = max(65_536, round(Int, 2^20 * something(tryparse(Float64, get(ENV, "KAIMONSLATE_BLOB_PULL_CHUNK_MB", "")), 4.0)))
_peer_pull_timeout_ms() = round(Int, 1000 * something(tryparse(Float64, get(ENV, "KAIMONSLATE_BLOB_PULL_TIMEOUT_S", "")), 120.0))
# Max time a pull may make NO progress before failing fast (vs. burning the whole pull timeout on a wedged
# link — e.g. an ssh forward stuck on a since-changed grant). Generous enough for one slow chunk to land;
# a failure drops the forward so the next attempt relaunches clean. Env-overridable.
_peer_pull_stall_ms()   = round(Int, 1000 * something(tryparse(Float64, get(ENV, "KAIMONSLATE_BLOB_PULL_STALL_S", "")), 20.0))

"PULL the content-addressed blob `hash` DIRECTLY from a peer worker's blob server at `ip:port` into THIS
worker's CAS (the direct-transport data leg). CURVE is used when `server_key` is non-empty — this worker
presents its client keypair, which the hub must have authorised on the peer (`__slate_authorize_client`).
Streams, sha-verifies, atomic-lands; an already-present blob returns 0. Returns (; bytes) or (; error)."
function __slate_pull_blob(ip::String, port::Int, server_key::String, hash::String; on_progress = nothing)
    _MEMO_OK || return (; error = "memo/blob layer disabled on this worker")
    configure! = isempty(server_key) ? nothing : function (sock)
        cpub, csec = KaimonGate._load_or_create_client_keypair()
        KaimonGate.make_curve_client!(sock, server_key, cpub, csec)
    end
    try
        moved = pull_blob_into!(KaimonGate.ZMQ, ip, port, _memo_dir(), hash; configure! = configure!,
                                chunk = _peer_pull_chunk(), timeout_ms = _peer_pull_timeout_ms(),
                                stall_ms = _peer_pull_stall_ms(), on_progress = on_progress)
        return (; bytes = moved)
    catch e
        return (; error = first(sprint(showerror, e), 200))
    end
end

"Bounded NETWORK reachability probe: can THIS worker open a TCP connection to a peer's blob port at
`ip:port`? TCP-level ONLY — NOT the CURVE handshake, which needs this worker authorised on the peer's
blob channel (that happens inside the pull); routing just needs to know the network path exists
(PEER_TUNNEL_PLAN §3). Only the PULLER can test B→A, so the hub asks it here to choose direct-CURVE vs
the SSH bridge. A non-routable peer DROPS the SYN, so a timed-out connect is ABANDONED rather than
sitting on the ~75s OS TCP timeout. Never throws. Returns (; reachable::Bool, rtt_ms)."
function __slate_probe_peer(ip::String, port::Int)
    result = Threads.Atomic{Int}(0)              # 0 pending · 1 open · 2 refused/error
    t0 = time()
    Threads.@spawn begin
        r = try
            s = Sockets.connect(ip, port); close(s); 1
        catch
            2
        end
        Threads.atomic_cas!(result, 0, r)
    end
    while result[] == 0 && time() - t0 < 3.0      # abandon a SYN-dropped connect at 3s
        sleep(0.03)
    end
    reachable = result[] == 1
    return (; reachable = reachable, rtt_ms = reachable ? round((time() - t0) * 1000; digits = 1) : -1.0)
end

# An OS-assigned free local TCP port (bind :0, read it, release) — the local end of a worker-local ssh
# forward. Small race window between release and the ssh -L bind; acceptable for a short-lived pull.
function _free_local_port()
    srv = Sockets.listen(Sockets.localhost, 0)
    p = Int(Sockets.getsockname(srv)[2])
    close(srv)
    return p
end

# A local TCP connect probe — is `127.0.0.1:port` accepting? Used to confirm an ssh forward's local end
# is live before pulling (and before reusing a pooled one).
_port_open(port::Int) = (try; s = Sockets.connect("127.0.0.1", port); close(s); true; catch; false; end)

# ── Standing ssh-forward pool (peer-transfer overhead cut) ─────────────────────────────────────────
# Launching an `ssh -N -L` forward costs an SSH connect + handshake (~0.3-0.5s, up to a 5s worst case) —
# the dominant per-pull overhead when a region pulls the SAME peer repeatedly (small/rapid transfers).
# So keep the forward STANDING, keyed by (ssh_target, blob_port), and reuse it across pulls; relaunch
# only when it died (source reaped / link dropped). `busy` guards a forward from the idle reaper mid-pull
# (a slow transfer can outlast the idle window); the reaper releases idle forwards so a pair that stops
# transferring doesn't hold an SSH connection open forever. Serial with the transfer executor (one puller
# at a time), so the lock is uncontended — held across a launch (≤5s) only blocks the background reaper.
mutable struct _SshFwd
    proc::Base.Process
    lport::Int
    last::Float64        # last-use wall time (idle reaping)
    busy::Bool           # a pull is using it right now — never reap
end
const _SSH_FWDS = Dict{Tuple{String,Int},_SshFwd}()
const _SSH_FWD_LOCK = ReentrantLock()
_ssh_fwd_idle_s() = something(tryparse(Float64, get(ENV, "KAIMONSLATE_SSH_FWD_IDLE_S", "")), 90.0)

# Get (or launch) the standing forward for (ssh_target → 127.0.0.1:blob_port) and MARK it busy. Returns
# (; lport, err): lport>0 and empty err on success. The caller MUST `_ssh_fwd_release!` when done.
function _ensure_ssh_fwd(ssh_target::String, key_path::String, known_hosts::String, blob_port::Int)
    key = (ssh_target, blob_port)
    lock(_SSH_FWD_LOCK) do
        f = get(_SSH_FWDS, key, nothing)
        if f !== nothing
            if !process_exited(f.proc) && _port_open(f.lport)
                f.busy = true; f.last = time()             # reuse — the whole point
                return (; lport = f.lport, err = "")
            end
            try; kill(f.proc); catch; end                  # dead/stale forward — drop and relaunch
            delete!(_SSH_FWDS, key)
        end
        lport = _free_local_port()
        kp = expanduser(key_path); kh = expanduser(known_hosts)
        # -L lport → (from A) 127.0.0.1:blob_port (A binds 0.0.0.0, so its loopback works). ExitOnForwardFailure
        # so a blocked permitopen/auth fails fast instead of hanging; least-privilege key is `permitopen`-scoped.
        cmd = `ssh -i $kp -o IdentitiesOnly=yes -o UserKnownHostsFile=$kh -o StrictHostKeyChecking=yes
                  -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ConnectTimeout=10 -o BatchMode=yes
                  -N -L $(lport):127.0.0.1:$(blob_port) $ssh_target`
        proc = try
            run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false)
        catch e
            return (; lport = 0, err = "ssh forward launch failed: " * first(sprint(showerror, e), 140))
        end
        up = false
        for _ in 1:100                                     # wait ≤5s for the forward to accept
            process_exited(proc) && break
            if _port_open(lport); up = true; break; end
            sleep(0.05)
        end
        if !up
            exited = process_exited(proc)
            try; kill(proc); catch; end
            return (; lport = 0, err = exited ?
                "ssh forward exited before coming up (auth / host key / permitopen?)" :
                "ssh forward did not come up on 127.0.0.1:$lport within 5s")
        end
        _SSH_FWDS[key] = _SshFwd(proc, lport, time(), true)
        return (; lport = lport, err = "")
    end
end

# Release a forward after a pull. `drop=true` (the pull errored) tears it down unconditionally: a failed
# pull can mean a forward that's "up" (proc alive, local port binds) yet useless — e.g. it authenticated
# under a since-changed grant, so its channel-opens are refused. Dropping guarantees the next pull relaunches
# a fresh one (deterministic recovery, matching the old per-pull teardown). A clean pull keeps it for reuse,
# still dropping if the tunnel silently died.
function _ssh_fwd_release!(ssh_target::String, blob_port::Int; drop::Bool = false)
    key = (ssh_target, blob_port)
    lock(_SSH_FWD_LOCK) do
        f = get(_SSH_FWDS, key, nothing); f === nothing && return
        if drop || process_exited(f.proc) || !_port_open(f.lport)
            try; kill(f.proc); catch; end
            delete!(_SSH_FWDS, key)
        else
            f.busy = false; f.last = time()
        end
    end
    return nothing
end

# Reap forwards that are idle (not busy, unused past the idle window) or dead. Runs on a background timer
# (started in `start`) so a pair that stops transferring releases its held SSH connection.
function _ssh_fwd_reap_idle!()
    idle = _ssh_fwd_idle_s()
    lock(_SSH_FWD_LOCK) do
        for (k, f) in collect(_SSH_FWDS)
            if !f.busy && (process_exited(f.proc) || time() - f.last > idle)
                try; kill(f.proc); catch; end
                delete!(_SSH_FWDS, k)
            end
        end
    end
    return nothing
end

# Kill every pooled forward — atexit hook (registered in `start`) so worker shutdown doesn't orphan the
# standing ssh child processes.
_ssh_fwd_killall!() = lock(_SSH_FWD_LOCK) do
    for (_, f) in _SSH_FWDS; try; kill(f.proc); catch; end; end
    empty!(_SSH_FWDS)
end

"SSH-BRIDGED pull (PEER_TUNNEL_PLAN §4): A's blob port is firewalled from THIS worker, but A is reachable
on SSH — so tunnel the blob port over a worker-local `ssh -N -L` forward and CURVE-pull through the local
end. The forward is POOLED and STANDING (`_ensure_ssh_fwd`): launched once per (ssh_target, blob_port) and
reused across pulls — relaunched only if it died — so a rapid stream of pulls to the same peer pays the
SSH connect once, not every time. Explicit flags, no ~/.ssh/config dependency: `key_path` + slate-owned
`known_hosts` come from the friend-group intro (§5); `ssh_target` = A's `user@peer-ip`. Never throws.
Returns (; bytes, via) or (; error)."
function __slate_pull_blob_ssh(ssh_target::String, key_path::String, known_hosts::String,
                               blob_port::Int, server_key::String, hash::String; on_progress = nothing)
    _MEMO_OK || return (; error = "memo/blob layer disabled on this worker")
    fw = _ensure_ssh_fwd(ssh_target, key_path, known_hosts, blob_port)
    isempty(fw.err) || return (; error = fw.err)
    ok = false
    try
        configure! = isempty(server_key) ? nothing : function (sock)
            cpub, csec = KaimonGate._load_or_create_client_keypair()
            KaimonGate.make_curve_client!(sock, server_key, cpub, csec)
        end
        moved = pull_blob_into!(KaimonGate.ZMQ, "127.0.0.1", fw.lport, _memo_dir(), hash; configure! = configure!,
                                chunk = _peer_pull_chunk(), timeout_ms = _peer_pull_timeout_ms(),
                                stall_ms = _peer_pull_stall_ms(), on_progress = on_progress)
        ok = true
        return (; bytes = moved, via = "ssh")
    catch e
        return (; error = first(sprint(showerror, e), 200))
    finally
        _ssh_fwd_release!(ssh_target, blob_port; drop = !ok)   # keep it for reuse on success; drop it on any error
    end
end

# ── Transfer-control plane (peer-to-peer pulls, OFF the gate) — TRANSFER_CONTROL_PLAN Mode A ──────────
# The hub (or, later, a peer) sends a transfer REQUEST over the blob channel (verb `X`) instead of a gate
# `:tool_call`. We mint a job id, enqueue it, and reply immediately; a dedicated executor task pumps the
# pull (reusing __slate_pull_blob[_ssh]) on a DEFAULT-pool thread — off the gate loop (so liveness never
# starves) AND off the blob serve loop (so peers keep getting served). Status is polled with verb `S`.
struct _XferJob
    id::String
    run::Function      # (on_progress) -> NamedTuple: the pull, (; bytes[, via]) or (; error)
end
mutable struct _XferRec
    via::String        # "direct" | "ssh"
    hash::String       # short blob id
    done::Int          # bytes pulled so far (fed by on_progress)
    total::Int         # blob size (known once the first chunk lands; -1 until then)
    started::Float64
    result::Any        # nothing = running | (:done, bytes) | (:err, msg)
end
const _XFER_QUEUE = Channel{_XferJob}(256)
const _XFER_JOBS  = Dict{String,_XferRec}()
const _XFER_LOCK  = ReentrantLock()
const _XFER_SEQ   = Threads.Atomic{Int}(0)

# Drop terminal jobs started >120s ago — keep recent ones for the `transfers` view, bound memory.
_xfer_prune!() = lock(_XFER_LOCK) do
    for (id, r) in collect(_XFER_JOBS)
        (r.result !== nothing && time() - r.started > 120) && delete!(_XFER_JOBS, id)
    end
end

# Dedicated executor: serial per worker (concurrency = more executor tasks later). Wires an on_progress
# callback into the pull so `S`/`Q` report live bytes-moved (→ throughput).
function _xfer_executor!()
    for job in _XFER_QUEUE
        rec = lock(_XFER_LOCK) do; get(_XFER_JOBS, job.id, nothing); end
        rec === nothing && continue
        prog = (off, total) -> lock(_XFER_LOCK) do; rec.done = off; rec.total = total; end
        res = try; job.run(prog); catch e; (; error = first(sprint(showerror, e), 200)); end
        err = try; getproperty(res, :error); catch; nothing; end
        lock(_XFER_LOCK) do
            rec.result = err === nothing ? (:done, Int(getproperty(res, :bytes))) : (:err, String(err))
        end
    end
end

# The blob-channel control handler (injected into blob_server!). FAST — mint id + enqueue (`X`), read
# status (`S`), or list all transfers (`Q`); never runs the transfer inline. Framing (newline-separated
# after the verb byte):
#   X<hash>\ndirect\n<ip>\n<port>\n<server_key>
#   X<hash>\nssh\n<ssh_target>\n<key_path>\n<known_hosts>\n<blob_port>\n<server_key>
# `S<jobid>` → "running <done> <total>" | "done <bytes> <via>" | "err <msg>".
# `Q`        → one `\x1f`-delimited record per line: id·via·hash·done·total·elapsed_ms·state.
function _xfer_control(cmd::Char, data::Vector{UInt8})
    _MEMO_OK || return "err: memo/blob layer disabled"
    if cmd == 'X'
        lines = split(String(data)[2:end], '\n')
        length(lines) >= 2 || return "err: bad X request"
        hash = String(lines[1]); kind = String(lines[2])
        run = if kind == "direct" && length(lines) >= 5
            ip = String(lines[3]); port = something(tryparse(Int, lines[4]), 0); skey = String(lines[5])
            (prog) -> __slate_pull_blob(ip, port, skey, hash; on_progress = prog)
        elseif kind == "ssh" && length(lines) >= 7
            tgt = String(lines[3]); kp = String(lines[4]); kh = String(lines[5])
            bp = something(tryparse(Int, lines[6]), 0); skey = String(lines[7])
            (prog) -> __slate_pull_blob_ssh(tgt, kp, kh, bp, skey, hash; on_progress = prog)
        else
            return "err: bad X spec"
        end
        _xfer_prune!()
        id = "x" * string(Threads.atomic_add!(_XFER_SEQ, 1))
        lock(_XFER_LOCK) do; _XFER_JOBS[id] = _XferRec(kind, first(hash, 12), 0, -1, time(), nothing); end
        try; put!(_XFER_QUEUE, _XferJob(id, run)); catch; return "err: queue closed"; end
        return id
    elseif cmd == 'S'
        id = String(data)[2:end]
        r = lock(_XFER_LOCK) do; get(_XFER_JOBS, id, nothing); end
        r === nothing && return "err: no job $id"
        r.result === nothing && return "running $(r.done) $(r.total)"
        r.result[1] === :done && return "done $(r.result[2]) $(r.via)"
        return "err: $(r.result[2])"
    elseif cmd == 'Q'
        return lock(_XFER_LOCK) do
            join([let state = r.result === nothing ? "running" : (r.result[1] === :done ? "done" : "err")
                      "$(id)\x1f$(r.via)\x1f$(r.hash)\x1f$(r.done)\x1f$(r.total)\x1f$(round(Int, (time() - r.started) * 1000))\x1f$(state)"
                  end for (id, r) in _XFER_JOBS], "\n")
        end
    end
    return "err: unknown control cmd '$cmd'"
end

"Cheap size estimate for the namespace global `name` — `(; bytes, type)` via Base.summarysize
(walks the object, no serialization), or `(; error)`. The transfer-preview input: for numeric
columns summarysize tracks the arrow/raw blob size closely, so how much a read will move can be
answered BEFORE paying the encode."
function __slate_sizeof(name::String)
    m = _NS[]
    s = Symbol(name)
    Base.invokelatest(isdefined, m, s) || return (; error = "no global named '$name'")
    v = Base.invokelatest(getglobal, m, s)
    b = try; Base.summarysize(v); catch e; return (; error = first(sprint(showerror, e), 120)); end
    return (; bytes = b, type = string(typeof(v)))
end

# Why a value can't survive being serialized and reconstructed in ANOTHER process: it holds a live
# `Ptr` — a DB / socket / file handle, i.e. process state — which deserializes to a dangling address
# on the far side. Same reason such a value can't be memo-restored on a fresh worker. Bounded,
# cycle-safe walk over STRUCT FIELDS (and small non-bits containers) — never array elements of a
# bits-eltype array (a `Vector{Float64}` can't hide a handle, and walking a huge frame would be
# absurd). Returns "" when portable, else a human-readable reason. Conservative: unseen exotic
# wrappers pass (we only flag a definite live pointer), so it never blocks legitimate data.
function _unportable_reason(v)
    seen = Base.IdSet{Any}(); found = Ref("")
    function walk(x, path, depth)
        (depth > 6 || !isempty(found[])) && return
        if x isa Ptr
            x != C_NULL && (found[] = string(isempty(path) ? "it" : path, " is a live ",
                                             typeof(x), " (a process-local handle)"))
            return
        end
        (x === nothing || x isa Symbol || x isa AbstractString || x isa Number ||
         x isa Char || x isa Function || x isa Type) && return
        (x in seen) && return
        push!(seen, x)
        if x isa Tuple || x isa AbstractArray
            (isbitstype(eltype(x)) || length(x) > 64) && return
            for (i, el) in pairs(x)
                walk(el, string(path, "[", i, "]"), depth + 1); isempty(found[]) || return
            end
            return
        end
        isstructtype(typeof(x)) || return
        for f in fieldnames(typeof(x))
            isdefined(x, f) || continue
            walk(getfield(x, f), string(path, ".", f), depth + 1); isempty(found[]) || return
        end
    end
    try; walk(v, "", 0); catch; end   # never let a walk error block a transfer — default to portable
    return found[]
end

"Is the namespace global `name` safe to serialize + reconstruct in another process — i.e. can it
CROSS a region boundary (or be restored on a fresh worker)? `(; portable, reason, type)`. `false`
means it holds a live handle (process state); tag its cell `resource` so each side opens its own."
function __slate_portable(name::String)
    m = _NS[]; s = Symbol(name)
    Base.invokelatest(isdefined, m, s) || return (; portable = true, reason = "", type = "")
    v = Base.invokelatest(getglobal, m, s)
    reason = _unportable_reason(v)
    return (; portable = isempty(reason), reason = reason, type = string(typeof(v)))
end

"Adopt this worker for a notebook (warm-pool handoff): point `PARENT_PROJECT` at the remote
project dir and swap in a fresh namespace. Loaded packages + the memo store survive — that is
the warmth a pool worker exists to hold; only the (empty) namespace is discarded. `datadir` is
the adopting REGION's declared data root (`datadir()`/`@sfile`): set-or-clear so a generic pool
worker takes on this region's root — or falls back to `<parent>/data` when the region has none
(clearing a prior region's root). Optional args are kwargs (the gate strips optional positionals)."
function __slate_adopt(parent::String; datadir::AbstractString = "")
    PARENT_PROJECT[] = parent
    if isempty(strip(String(datadir)))
        haskey(ENV, "KAIMONSLATE_DATADIR") && delete!(ENV, "KAIMONSLATE_DATADIR")
    else
        ENV["KAIMONSLATE_DATADIR"] = String(datadir)
    end
    _NS[] = _new_ns()
    @info "slate: adopted by a notebook" parent = parent datadir = datadir
    return true
end

# Flat scalar args only (the gate reflects the signature into an MCP schema — a
# nested-Dict argument doesn't validate, so we pass page params individually).
"Fetch one page of a registered paged table (server-paged tables / `slate_query`)."
__slate_table_page(table_id::String, page::Int, page_size::Int, sort_col::Int, sort_desc::Bool, search::String) =
    _provider_page(table_id, PageRequest(page, page_size, sort_col, sort_desc, search))

"Capture markdown `{{ }}` interpolation expressions (rich) — one wire-form each."
__slate_interp(exprs::Vector{String}) = [run_capture(_NS[], e; capture = DemuxCapture()) for e in exprs]

# Re-render a native (server-side, e.g. Makie) figure cell under a specific Slate PALETTE, for a themed
# PDF export that OVERRIDES the notebook's live theme. Makie bakes its theme when the figure is built,
# so the only way to re-theme a figure is to re-render it: we re-run the cell's `source` in the live
# namespace inside `with_theme(slate_theme(theme=…))` so the figure is BUILT under that palette, then
# return the richest export representation — `(; ok, ext, b64)` with `ext ∈ ("pdf","svg","png")`, or
# `ok=false` if Makie isn't loaded, the cell yielded no figure, or anything threw. Export-only; the
# result rides back as bytes (base64) and never touches the live cell output. `with_theme` restores the
# prior default theme on exit, so a cell that relies on the ambient theme picks up the palette while one
# that sets its OWN styling still wins (its code runs last).
function __slate_rerender_fig(; source::String = "", theme::String = "", raster::Bool = false,
                             filename::String = "cell:export")
    Mk = _loaded_makie()
    Mk === nothing && return (; ok = false)
    thm = try; slate_theme(theme = theme); catch; return (; ok = false); end
    wire = nothing
    themed = () -> (wire = run_capture(_NS[], source, filename; capture = DemuxCapture()))
    try
        Base.invokelatest(Mk.with_theme, themed, thm)
    catch
        return (; ok = false)
    end
    wire === nothing && return (; ok = false)
    # PDF export wants VECTOR (pdf/svg); HTML can't embed pdf, so `raster` prefers svg/png instead.
    prefs = raster ? (("image/svg+xml", "svg"), ("image/png", "png")) :
                     (("application/pdf", "pdf"), ("image/svg+xml", "svg"), ("image/png", "png"))
    for (mime, ext) in prefs
        for (m, bytes) in wire.mime
            m == mime && return (; ok = true, ext = ext, b64 = Base64.base64encode(bytes))
        end
    end
    return (; ok = false)
end

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
    # resolves there WITH its docs. Try it ALWAYS — `module_help` resolves a bare name
    # case-insensitively (a wrong-case `regionplan` finds `RegionPlan`), so gating on an exact
    # `isdefined(nb, head)` would skip that path. Accept the record only if it actually found docs.
    nb = _NS[]
    rec = try; module_help(nb, name); catch; nothing; end
    rec !== nothing && (get(rec, "kind", "unknown") != "unknown" || !isempty(strip(get(rec, "doc", "")))) && return rec
    # Fall back to a throwaway module that imports the head package for `?Module` drill-down on a
    # package the notebook hasn't brought into scope.
    m = _doc_scan()
    try; Core.eval(m, Meta.parse("import " * head)); catch; end   # load the package if needed
    return module_help(m, name)
end

# ExpressionExplorer for macro-aware analysis, delivered by the slate-owned `worker_infra` env on
# LOAD_PATH (after the notebook project — a notebook's own EE wins). Guarded like Serialization:
# absent (env build failure, offline first-instantiate) → no macro recovery, the server keeps its
# conservative analysis; never a boot failure.
const _EE_OK = try
    @eval import ExpressionExplorer
    true
catch e
    @warn "slate: ExpressionExplorer unavailable — macro-aware dependency recovery disabled" error = sprint(showerror, e)
    false
end
_blog("ExpressionExplorer loaded (ok=$(_EE_OK))")

"Macro-expand cell sources in the live notebook namespace (recursive, NO evaluation) and ANALYZE
them right here, where the macros live — returns id → {reads, writes} name lists. A cell whose
expansion/analysis yields nothing (parse failure, macro not yet defined) is omitted — the server
keeps its conservative static analysis for it.
NOTE: `cells` must be a KEYWORD arg — a single positional `::Dict` param triggers the gate
dispatcher's raw-Dict fast path, which hands the handler the WHOLE arguments dict instead."
function __slate_macroexpand(; cells::Dict = Dict{String,Any}())
    out = Dict{String,Any}()
    _EE_OK || return out
    nb = _NS[]
    for (id, src) in cells
        src isa AbstractString || continue
        b = _expanded_bindings_of(ExpressionExplorer, _expand_cell_statements(nb, String(src)))
        b === nothing || (out[String(id)] = Dict{String,Any}(
            "reads" => String[string(s) for s in b[1]],
            "writes" => String[string(s) for s in b[2]]))
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
    return Dict{String,Any}("notebook" => nb, "parent" => parent, "payload_sha" => PAYLOAD_SHA[])
end

# Seed a forked notebook env from `parent`: write the env's Project/Manifest from the parent (the
# shared `seed_env_project!` policy — deps/compat/sources with dev paths made absolute — from
# envprep.jl), stamp the parent fingerprint (so a later parent change is detected stale), then
# activate + `dev` the parent package in so `using ParentModule` works, preserving the parent's
# pinned versions. One consistent env.
function _seed_notebook_env!(envdir::AbstractString, parent::AbstractString)
    pname = seed_env_project!(envdir, parent)   # shared policy (envprep.jl)
    stamp_env!(envdir, parent)
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

"The worker's SlateExtensionsBase extension manifest — what its loaded packages registered for the
page to mirror: `{frontend:[{id, js, esm, kind}]}` (widget renderers + editor extensions declared from
`__init__`; `esm` ⇒ ES module; a non-empty `kind` ⇒ a component whose default export Slate wraps). The
server pulls this once per run drain and injects the scripts into the page. Empty when no such package
is loaded."
function __slate_extension_manifest()
    out = Dict{String,Any}("frontend" => Dict{String,Any}[])
    try
        m = inprocess_extension_manifest(_NS[])
        out["frontend"] = Dict{String,Any}[Dict{String,Any}(
            "id" => String(e.id), "js" => String(e.js), "esm" => e.esm, "kind" => String(e.kind))
            for e in m.frontend]
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

# Revise applies method changes but NEVER re-runs a package's `__init__`. So a dev package that GAINS or
# CHANGES its `__init__` — e.g. to install a host-integration hook, register something, set up global
# state — would silently miss it under Slate's hot-reload; a pool-adopted worker that first loaded the
# package's OLDER source (before the `__init__` existed) has the same gap (`using` on an already-loaded
# module is a no-op, so it never fires either). When a revise pass (re)defines an `__init__`, run it — but
# ONLY for the packages actually revised in this pass (mapped from the queue), so we never blanket-re-run
# unrelated inits. `__init__` is expected idempotent; a throw is logged, never fatal.
function _run_revised_inits!(queue, changed)
    ("__init__" in changed) || return nothing
    ran = String[]; seen = Set{Module}()
    for item in queue
        try
            pd = item[1]
            id = pd.info.id                                   # Revise PkgData → PkgId
            m = get(Base.loaded_modules, id, nothing)
            (m isa Module && !(m in seen) && isdefined(m, :__init__)) || continue
            push!(seen, m)
            try
                Base.invokelatest(getfield(m, :__init__))
                push!(ran, String(nameof(m)))
            catch e
                @warn "slate hot-reload: package __init__ threw on re-run" pkg = string(m) exception = e
            end
        catch
        end
    end
    isempty(ran) || @info "slate hot-reload: re-ran package __init__ after a revise that (re)defined one" packages = ran
    return nothing
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

# ── Background precompile (keep the warm environment hot after a source edit) ─────────────────────
# After a src edit, Revise carries THIS session, but the on-disk precompile cache is stale — a fresh
# or warm worker would pay the precompile on its boot path. So refresh it here, in the warm worker,
# off the interactive path: `Pkg.precompile()` on a spawned thread. The per-package compile JOBS fork
# regardless (Julia's model) — this just ORCHESTRATES them, so there's no extra orchestrator process,
# and it logs to THIS worker's log. Debounced + coalesced: a burst of saves collapses to one trailing
# precompile; a save mid-run schedules exactly one re-run. Only rebuilds what's stale (the edited pkg).
const _BGPC_LOCK = ReentrantLock()
const _BGPC_RUN = Ref(false)
const _BGPC_PENDING = Ref(false)
function _kick_bg_precompile!()
    start = lock(_BGPC_LOCK) do
        _BGPC_RUN[] ? (_BGPC_PENDING[] = true; false) : (_BGPC_RUN[] = true; true)
    end
    start && @async _bg_precompile_loop!()
    return nothing
end
function _bg_precompile_loop!()
    while true
        try; sleep(1.5); catch; end                       # debounce a burst of saves
        t0 = time()
        @info "slate precompile: refreshing the env in the background — fresh workers will boot hot"
        try
            # In a SUBPROCESS, NOT in-process: `Pkg.precompile()` inside a live worker crashes it. The
            # per-package compile jobs fork regardless (Julia's model), so this only adds a thin
            # orchestrator; `run` on @async yields on the subprocess I/O, so interactive cells stay
            # responsive. The worker still owns + logs it (worker log), off the interactive path.
            root = dirname(Base.active_project()::String)
            run(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$root -e "using Pkg; Pkg.precompile()"`;
                         stdout = devnull, stderr = devnull))
            @info "slate precompile: env warm — fresh workers boot hot" seconds = round(time() - t0; digits = 1)
        catch e
            @warn "slate precompile: failed" reason = first(split(sprint(showerror, e), '\n'))
        end
        again = lock(_BGPC_LOCK) do
            _BGPC_PENDING[] ? (_BGPC_PENDING[] = false; true) : (_BGPC_RUN[] = false; false)
        end
        again || break
    end
    return nothing
end

# ── Proactive, NARRATED precompile on boot (the slow-Makie-open fix) ───────────────────────────────
# A notebook whose env isn't precompiled pays that cost lazily, under the first cell's `using` — and
# because cell output is capture-redirected, Julia's "Precompiling…" progress lands in the cell buffer,
# INVISIBLE, so the topbar just shows a frozen "Running 0/N". Here we pay it up front instead: detect a
# cold env, precompile it in a SUBPROCESS (in-process `Pkg.precompile()` crashes a live worker — see
# `_bg_precompile_loop!`), and stream each package through the shared classifier onto `slate_prepare`, so
# the browser narrates "Preparing packages · precompiling k/N · <pkg>". Non-blocking: cells and edits
# proceed; a cell's own `using` that races this coordinates on Julia's per-package pidfile lock (it waits
# on our compile rather than duplicating it). A warm env is a near-instant no-op — no subprocess, no banner.
function _prepare_env!()
    projfile = try; Base.active_project(); catch; nothing; end
    projfile === nothing && return nothing
    proj = dirname(String(projfile))
    # Cheap warm-check: if every DIRECT dep is already precompiled, the whole closure is too (precompile
    # is bottom-up — a stale indirect dep leaves its dependents stale), so there's nothing to narrate.
    direct = try
        [Base.PkgId(uuid, name) for (name, uuid) in Pkg.project().dependencies
         if !(name in _PREP_SKIP)]
    catch; return nothing; end
    isempty(direct) && return nothing
    cold = any(pid -> !_pkg_ready(pid), direct)
    cold || return nothing
    @info "slate prepare: env cold — precompiling in the background (one-time; narrated to the notebook)"
    tr = PrepareTracker(time())
    # The subprocess computes the ACCURATE full-closure total (Base.isprecompiled over the manifest) and
    # emits it as a control marker, then precompiles — its combined stdout/stderr is what we classify.
    script = raw"""
        using Pkg
        try
            need = 0
            for (uuid, info) in Pkg.dependencies()
                info.name in ("KaimonGate", "Revise", "ExpressionExplorer") && continue
                pid = Base.PkgId(uuid, info.name)
                ready = (try; Base.in_sysimage(pid); catch; false; end) || (try; Base.isprecompiled(pid); catch; true; end)
                ready || (global need += 1)
            end
            println(stderr, "@@SLATE_PREP total=", need); flush(stderr)
        catch; end
        try
            Pkg.precompile()
        catch e
            println(stderr, "@@SLATE_PREP error ", first(split(sprint(showerror, e), '\n')))
        end
        println(stderr, "@@SLATE_PREP done"); flush(stderr)
    """
    out = Pipe()
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$proj -e $script`
    proc = try
        run(pipeline(cmd; stdout = out, stderr = out); wait = false)
    catch e
        @warn "slate prepare: precompile subprocess could not start" exception = e
        return nothing
    end
    close(out.in)
    for line in eachline(out)
        (prepare_feed!(tr, line) && prepare_active(tr)) &&
            (try; KaimonGate._publish_stream("slate_prepare", prepare_json(tr)); catch; end)
    end
    try; wait(proc); catch; end
    tr.phase == "error" || (tr.phase = "done")
    try; KaimonGate._publish_stream("slate_prepare", prepare_json(tr)); catch; end
    @info "slate prepare: precompile complete" pkgs = tr.done secs = round(Int, time() - tr.t0)
    return nothing
end
const _PREP_SKIP = ("KaimonGate", "Revise", "ExpressionExplorer")   # infra deps — never notebook-relevant
# "Available without compiling": a sysimage-baked stdlib (Libdl/LinearAlgebra/…) has NO separate cache, so
# `Base.isprecompiled` reports false for it — treat in-sysimage packages as ready, else a warm env always
# looks cold. `in_sysimage` is 1.9+; the guard degrades gracefully if it's ever absent.
_pkg_ready(pid::Base.PkgId) =
    (try; Base.in_sysimage(pid); catch; false; end) || (try; Base.isprecompiled(pid); catch; true; end)

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
                _run_revised_inits!(queue, names)   # a dev pkg that (re)defined __init__ → run it (Revise won't)
                @info "slate hot-reload: revised" files = length(queue) changed = names
                isempty(names) || KaimonGate._publish_stream("slate_revise", join(names, ","))
                _kick_bg_precompile!()   # the on-disk cache is now stale → refresh it in the background (worker log)
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
    names = _changed_names(queue)
    _run_revised_inits!(queue, names)   # a dev pkg that (re)defined __init__ → run it (Revise won't)
    return names
end

# GateTools exposed to the KaimonSlate server.
"The cells this worker is evaluating RIGHT NOW (keys of `_RUNNING_TASKS`) — the authoritative in-flight
set the hub reconciles its run-registry against. A cell the hub still marks `running` that is absent
here was orphaned (the worker bounced under it) and can be safely reset. Cheap: a snapshot under the lock."
function __slate_running()
    _LAST_HUB_REQ[] = time()   # the supervisor's heartbeat — proof the hub is still driving us; the spin-guard treats staleness as "orphaned"
    ids = lock(_CANCEL_LOCK) do; String[String(k) for k in keys(_RUNNING_TASKS)]; end
    return (; running = ids, ts = time())
end

# Materialize content-addressed blobs into THIS worker's data dir (`datadir()`) — the receiving half
# of the datadir sync. Reuses the CAS the memo/boundary transport already fills via `push_blob!`
# (`MemoStore.blob_path`); the only new concept vs `__slate_bind_blob` (blob → namespace var) is
# placing a blob at a FILE path (a portable `@sfile`). `files`: [{rel, hash}]. Path-escape guarded.
function __slate_materialize_datadir(; files = Any[])
    _MEMO_OK || return (; materialized = 0, error = "memo layer off")
    root = _memo_dir()
    # Same resolution as `datadir()`: a region-pinned root (`KAIMONSLATE_DATADIR`) wins, else <project>/data.
    _rr = strip(get(ENV, "KAIMONSLATE_DATADIR", ""))
    ddir = if !isempty(_rr)
        String(_rr)
    else
        base = PARENT_PROJECT[]
        isempty(base) && (ap = Base.active_project(); base = ap === nothing ? "" : dirname(ap))
        isempty(base) && return (; materialized = 0, error = "no project dir")
        joinpath(base, "data")
    end
    _g(d, k, dv) = haskey(d, k) ? d[k] : get(d, Symbol(k), dv)
    n = 0
    for f in (files isa AbstractVector ? files : Any[])
        f isa AbstractDict || continue
        rel = String(_g(f, "rel", "")); h = String(_g(f, "hash", ""))
        (isempty(rel) || isempty(h) || isabspath(rel) || occursin("..", rel)) && continue
        bp = MemoStore.blob_path(root, h); isfile(bp) || continue
        tgt = joinpath(ddir, rel)
        try
            (isfile(tgt) && filesize(tgt) == filesize(bp)) && (n += 1; continue)   # already present
            mkpath(dirname(tgt)); cp(bp, tgt; force = true)
            n += 1
        catch
        end
    end
    return (; materialized = n)
end

# Make a THROWAWAY random blob in the CAS (content-addressed, NO manifest → never a memo value): a probe
# payload for measuring peer transfer rate on demand. Random bytes ⇒ a unique hash that never dedups
# against a real value; the caller drops it right after the pull (`__slate_drop_blob`). Returns (; hash, bytes).
function __slate_make_probe_blob(bytes::Int)
    _MEMO_OK || return (; error = "memo/blob layer disabled on this worker")
    n = clamp(bytes, 1, 1 << 30)
    try
        h, moved = MemoStore.put_blob(io -> write(io, rand(UInt8, n)), _memo_dir())
        return (; hash = String(h), bytes = Int(moved))
    catch e
        return (; error = first(sprint(showerror, e), 200))
    end
end

# Delete a blob from this worker's CAS by hash (probe cleanup — a throwaway probe blob must never linger).
# Best-effort; a missing blob counts as success. Returns (; ok).
function __slate_drop_blob(hash::String)
    _MEMO_OK || return (; error = "memo/blob layer disabled on this worker")
    try
        p = MemoStore.blob_path(_memo_dir(), String(hash))
        isfile(p) && rm(p; force = true)
        return (; ok = true)
    catch e
        return (; error = first(sprint(showerror, e), 200))
    end
end

function tools()
    return KaimonGate.GateTool[
        KaimonGate.GateTool("__slate_eval", __slate_eval),
        KaimonGate.GateTool("__slate_rerender_fig", __slate_rerender_fig),
        KaimonGate.GateTool("__slate_eval_batch", __slate_eval_batch),
        KaimonGate.GateTool("__slate_running", __slate_running),
        KaimonGate.GateTool("__slate_cancel", __slate_cancel),
        KaimonGate.GateTool("__slate_cancel_cells", __slate_cancel_cells),
        KaimonGate.GateTool("__slate_set_bind", __slate_set_bind),
        KaimonGate.GateTool("__slate_call", __slate_call),
        KaimonGate.GateTool("__slate_reset", __slate_reset),
        KaimonGate.GateTool("__slate_adopt", __slate_adopt),
        KaimonGate.GateTool("__slate_memo_trace", __slate_memo_trace),
    KaimonGate.GateTool("__slate_memo_snapshot", __slate_memo_snapshot),
        KaimonGate.GateTool("__slate_memo_pin", __slate_memo_pin),
        KaimonGate.GateTool("__slate_blob_of", __slate_blob_of),
        KaimonGate.GateTool("__slate_bind_blob", __slate_bind_blob),
        KaimonGate.GateTool("__slate_client_key", __slate_client_key),
        KaimonGate.GateTool("__slate_server_key", __slate_server_key),
        KaimonGate.GateTool("__slate_ports", __slate_ports),
        KaimonGate.GateTool("__slate_authorize_client", __slate_authorize_client),
        KaimonGate.GateTool("__slate_revoke_client", __slate_revoke_client),
        KaimonGate.GateTool("__slate_pull_blob", __slate_pull_blob),
        KaimonGate.GateTool("__slate_probe_peer", __slate_probe_peer),
        KaimonGate.GateTool("__slate_pull_blob_ssh", __slate_pull_blob_ssh),
        KaimonGate.GateTool("__slate_make_probe_blob", __slate_make_probe_blob),
        KaimonGate.GateTool("__slate_drop_blob", __slate_drop_blob),
        KaimonGate.GateTool("__slate_materialize_datadir", __slate_materialize_datadir),
        KaimonGate.GateTool("__slate_sizeof", __slate_sizeof),
        KaimonGate.GateTool("__slate_portable", __slate_portable),
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
        KaimonGate.GateTool("__slate_extension_manifest", __slate_extension_manifest),
        KaimonGate.GateTool("__slate_pkg", __slate_pkg),
        KaimonGate.GateTool("__slate_pkg_parent", __slate_pkg_parent),
        KaimonGate.GateTool("__slate_revise", __slate_revise),
    ]
end

# ── Blob data channel (the third socket — gate port + 2) ─────────────────────────────────────
# The transport itself (server + direct-pull client + wire protocol) lives in blobchannel.jl,
# unit-tested over loopback. This wrapper injects the CURVE identity + the channel's OWN
# authorization. Serves THIS worker's CAS (`_memo_dir()`); runs for the worker's lifetime.
#
# CURVE-encrypted by default, decoupled from the gate's hub transport (PEER_TUNNEL_PLAN §2). The
# server keypair is the gate's persisted `server.key` (shared with `__slate_server_key`, which the
# hub reads to pin us). `curve=false` runs it PLAINTEXT — the encryption-cost bench toggle
# (PEER_TUNNEL_PLAN §7), decided by the hub (`KAIMONSLATE_BLOB_CURVE`) and baked in at spawn so both
# ends agree; the hub then omits the server key so its client connects plaintext too.
#
# AUTHORIZATION is Slate's, NOT the generic gate's: blob transfer is a Slate concept, and the gate
# is shared by every (non-Slate) REPL session, so the channel runs its OWN ZAP handler on its OWN
# ZMQ context gating a SEPARATE allow-file. Authorising a peer to PULL a blob thus never also grants
# it control-gate access (which sharing the gate's "kaimon" domain would). It enforces the allow-list
# under the SAME condition the gate does (a CURVE allow-list gate, i.e. `:direct`); a `:tunnel`/
# allow_any worker runs CURVE encryption-only, exactly as before. Blob access is the UNION of the
# gate's control clients (the hub — already trusted, so it keeps data access with no second grant)
# and blob-only peers (`_authorized_blob_clients`).

# The blob allow-file is SLATE's (one Z85 client pubkey per line), so it lives under the kaimonslate
# cache base — NOT the gate's shared curve dir. That base honors `KAIMONSLATE_CACHE_HOME` (`cache_root`),
# the SAME per-region knob that isolates the CAS, so co-located regions with distinct cache_roots get
# distinct blob allow-lists and never write the same file — ending the cross-region write race. (The
# gate's shared CURVE identity — server/client keys + the control allow-list — is untouched; blob-only
# peer grants just don't ride on it.) Reads are lock-free (the ZAP handler reads it on EVERY handshake),
# so writes MUST be atomic: `_authorize`/`_revoke` rewrite via tmp+mv (rename is atomic within a dir), so
# a reader always sees a COMPLETE old-or-new file. An in-process lock serializes this worker's own
# concurrent transfers; same-region warm workers still share their region's file, but the atomic writes
# keep that non-corrupting (a lost update is recoverable — a dropped add retries/relays, a dropped revoke
# leaves one extra peer key).
_blob_allow_path() = joinpath(dirname(_memo_dir()), "authorized_blob_clients")
const _BLOB_ALLOW_LOCK = ReentrantLock()

function _authorized_blob_clients()
    f = _blob_allow_path(); s = Set{String}(); isfile(f) || return s
    for line in eachline(f)
        t = strip(line); (isempty(t) || startswith(t, "#")) && continue
        push!(s, String(first(split(t))))
    end
    return s
end

# Atomically replace the allow-file with `keys` (normalized: one sorted Z85 key per line). tmp is
# per-pid so co-located workers' tmp files never collide; the mv is the atomic publish point.
function _write_blob_allow!(keys)
    f = _blob_allow_path(); mkpath(dirname(f))
    tmp = string(f, ".tmp.", getpid())
    open(tmp, "w") do io; for k in sort!(collect(keys)); println(io, k); end; end
    mv(tmp, f; force = true)
    return nothing
end

function _authorize_blob_client!(pubkey::AbstractString)
    lock(_BLOB_ALLOW_LOCK) do
        s = _authorized_blob_clients()
        String(pubkey) in s && return :already
        push!(s, String(pubkey)); _write_blob_allow!(s)
        return :added
    end
end

function _revoke_blob_client!(pubkey::AbstractString)
    lock(_BLOB_ALLOW_LOCK) do
        s = _authorized_blob_clients()
        String(pubkey) in s || return :absent
        delete!(s, String(pubkey)); _write_blob_allow!(s)
        return :removed
    end
end

# Does this worker enforce a blob allow-list? Only a CURVE gate with an allow-list (`:direct`) — the
# same posture under which the gate itself allow-lists, so this matches the pre-split behaviour.
_blob_enforce() = try
    KaimonGate._ZAP_SOCKET[] !== nothing && !KaimonGate._CURVE_ALLOW_ANY[]
catch
    false
end

const _BLOB_ZAP_DOMAIN = "kaimon-blob"
const _BLOB_CTX = Ref{Any}(nothing)   # anchor the blob ZMQ context so GC can't finalize it mid-serve
# The blob data port this worker ACTUALLY bound: the pinned `gate+2` on a `:direct` worker (firewall/peer
# constraint), or a VERIFIED-FREE port on a `:tunnel` worker (never `gate+2`; see `start`). `__slate_ports`
# returns it so the hub reaches the real port. Set from the blob server's `on_ready` (post-bind), so a
# reader never sees an un-bound port. `_STREAM_PORT` mirrors the (hub-assigned) stream port for the same tool.
const _BLOB_DATA_PORT = Ref(0)
const _STREAM_PORT = Ref(0)

# The blob channel's OWN ZAP REP handler (RFC 27), bound on the blob `ctx`. Answers 200/400 per CURVE
# handshake from the UNION of the gate's control clients and the blob-only allow-list, re-read each
# handshake (handshakes are rare) so authorize/revoke apply live without a restart. Must bind BEFORE
# the blob server socket; runs for the gate's lifetime.
function _start_blob_zap!(ctx)
    Z = KaimonGate.ZMQ
    zap = KaimonGate._zmq_socket(ctx, Z.REP)
    Z.bind(zap, KaimonGate._ZAP_ENDPOINT)
    zap.rcvtimeo = 250; zap.linger = 0
    Threads.@spawn :interactive begin
        try
            while KaimonGate._RUNNING[]
                frames = try
                    Z.recv_multipart(zap, Vector{UInt8})
                catch e
                    _is_zmq_timeout(Z, e) && continue   # re-check _RUNNING
                    KaimonGate._RUNNING[] || break
                    continue
                end
                try
                    # ZAP 1.0 CURVE request: [version, request_id, domain, address, identity,
                    # mechanism, credentials(=32 raw client key bytes)].
                    length(frames) >= 7 || continue
                    z85 = try; KaimonGate._z85_encode(frames[7]); catch; ""; end
                    ok = z85 in _authorized_blob_clients() || z85 in KaimonGate._authorized_clients()
                    Z.send_multipart(zap, Any["1.0", frames[2], ok ? "200" : "400",
                                              ok ? "OK" : "denied", "", ""])
                catch e
                    @debug "blob ZAP handler error" exception = e
                end
            end
        finally
            try; close(zap); catch; end
        end
    end
    return nothing
end

function _blob_server!(host::String, port::Int; curve::Bool = true)
    ctx = KaimonGate.ZMQ.Context()          # OWN context → OWN ZAP handler (never the gate's shared one)
    _BLOB_CTX[] = ctx                        # anchor it (see _BLOB_CTX) — a local would risk GC finalization
    enforce = curve && _blob_enforce()
    enforce && _start_blob_zap!(ctx)        # bind the handler BEFORE the server socket
    configure! = curve ? function (sock)
        sec = try; KaimonGate._CURVE_SERVER_SECRET[]; catch; ""; end
        isempty(sec) && ((_, sec) = KaimonGate._load_or_create_server_keypair())
        KaimonGate.make_curve_server!(sock, sec)
        # Set the ZAP domain ONLY when we started a handler — a domain with no handler hangs every
        # handshake. No handler ⇒ CURVE encryption-only (the `:tunnel`/allow_any posture).
        enforce && KaimonGate._setsockopt_str(sock, KaimonGate._ZMQ_ZAP_DOMAIN, _BLOB_ZAP_DOMAIN)
    end : nothing
    blob_server!(KaimonGate.ZMQ, host, port, _memo_dir(); ctx = ctx, configure! = configure!,
                 control_handler = _xfer_control,   # transfer-control plane rides the blob channel (X/S verbs)
                 on_ready = () -> begin             # publish the actually-bound port for `__slate_ports` (post-bind = never a stale/racing value)
                     _BLOB_DATA_PORT[] = port
                     @info "slate worker: blob data channel listening" port = port curve = curve allowlist = enforce
                 end)
    return nothing
end

# Total on-disk bytes under `d` (memo-store sample). Best-effort: a file vanishing mid-walk counts 0.
function _dir_bytes(d::AbstractString)
    n = 0
    isdir(d) || return 0
    for (root, _, files) in walkdir(d)
        for f in files
            n += try; filesize(joinpath(root, f)); catch; 0; end
        end
    end
    return n
end

# ── Telemetry: one sample every 2s — PUBbed on the stream socket (an attached hub sees it live)
# AND stamped into the `.stats` sidecar next to the worker script, atomically (the roster probe
# cats it, so an IDLE pool worker still shows cpu/rss in `list_remote_workers`). Linux /proc for
# cpu%/rss (remote workers are the audience); elsewhere cpu is -1 and rss falls back to maxrss.
# The memo-store walk is the one non-trivial sample, so it refreshes every 15th tick (~30s).
function _telemetry_loop!(stats_path::String)
    isempty(stats_path) || mkpath(dirname(stats_path))   # sidecar is remote-only; the PUB runs for every worker
    pagesz = Sys.islinux() ? Int(ccall(:sysconf, Clong, (Cint,), 30)) : 4096   # _SC_PAGESIZE
    clk    = Sys.islinux() ? Int(ccall(:sysconf, Clong, (Cint,), 2))  : 100   # _SC_CLK_TCK
    # macOS: proc_pid_rusage (libproc, unprivileged — no /proc, no Instruments, no root) gives CURRENT
    # RSS + cumulative user/system CPU ns. Offsets from rusage_info_v0 (see perf_monitor_macos.jl).
    macos_rusage() = try
        buf = Vector{UInt8}(undef, 256)
        ccall(:proc_pid_rusage, Cint, (Cint, Cint, Ptr{UInt8}), Int32(getpid()), Cint(0), buf) == 0 || return nothing
        (user_ns = reinterpret(UInt64, @view buf[17:24])[1],
         sys_ns  = reinterpret(UInt64, @view buf[25:32])[1],
         rss     = reinterpret(UInt64, @view buf[65:72])[1])
    catch; nothing; end
    cputime() = if Sys.islinux()
        try
            s = read("/proc/self/stat", String)
            rest = split(s[findlast(')', s)+2:end])     # stat fields from 3 on (comm may hold spaces)
            (parse(Int, rest[12]) + parse(Int, rest[13])) / clk   # utime + stime (fields 14/15)
        catch; -1.0; end
    elseif Sys.isapple()
        r = macos_rusage(); r === nothing ? -1.0 : (r.user_ns + r.sys_ns) / 1e9
    else
        -1.0                                            # Windows/other: no cheap cpu-time source → cpu% n/a
    end
    rssbytes() = if Sys.islinux()
        try; parse(Int, split(read("/proc/self/statm", String))[2]) * pagesz; catch; Int(Sys.maxrss()); end
    elseif Sys.isapple()
        r = macos_rusage(); r === nothing ? Int(Sys.maxrss()) : Int(r.rss)   # current RSS (not peak)
    else
        Int(Sys.maxrss())                               # Windows/other: peak RSS fallback
    end
    # SYSTEM-WIDE cpu — the whole HOST, not just this worker process — so a remote region shows what the
    # box is doing (a CUDA precompile pegging every core, a neighbour hogging it). Linux /proc/stat's
    # aggregate line → (busy, total) jiffies; the loop deltas them into a %. Non-Linux → n/a (loadavg
    # still rides along cross-platform).
    sysstat() = if Sys.islinux()
        try
            f = split(first(eachline("/proc/stat")))          # "cpu" user nice system idle iowait irq softirq steal …
            v = parse.(Int, f[2:end])
            total = sum(v); idle = v[4] + (length(v) >= 5 ? v[5] : 0)   # idle + iowait
            (total - idle, total)
        catch; (-1, -1); end
    else
        (-1, -1)
    end
    lastc = cputime(); lastw = time(); memo = -1; tick = 0; spin = 0
    lastsb, lastst = sysstat()
    while true
        sleep(2.0)
        tick += 1
        c = cputime(); w = time()
        cpu = (c >= 0 && lastc >= 0 && w > lastw) ? round(100 * (c - lastc) / (w - lastw); digits = 1) : -1.0
        lastc = c; lastw = w
        (memo < 0 || tick % 15 == 0) && (memo = _dir_bytes(joinpath(_memo_dir(), "blobs")))
        # The LIVE running-cell ids — the per-eval heartbeat the hub reconciles against (a cell the hub
        # thinks is running but that's absent here is orphaned). Cheap: just the keys under the lock.
        runids = lock(_CANCEL_LOCK) do; collect(keys(_RUNNING_TASKS)); end
        evals = length(runids)
        # Spin-guard: an orphaned worker (hub restarted / connection died) can wedge a thread at ~one full
        # core forever — a userspace busy-loop that hogs the host while doing nothing useful. Detect the
        # wedge from three independent signals and self-terminate: HOT cpu, an EMPTY run set (no cell is
        # actually computing), and NO hub heartbeat for minutes (an attached kernel is pinged every few
        # seconds via __slate_running; silence ⇒ the hub has forgotten us). Warming/precompiling is exempt,
        # and a healthy idle worker sits near 0% cpu so it never trips. Require a sustained streak on top
        # of the heartbeat gap so a GC burst can't fire it.
        spin = (cpu > 70.0 && evals == 0 && (time() - _LAST_HUB_REQ[]) > 300 &&
                !startswith(_WARM_STATUS[], "warming")) ? spin + 1 : 0
        if spin >= 15                                       # ~30s of hot-idle after ~5min of no hub contact ⇒ wedged orphan
            @error "slate worker: wedged orphan — a core pinned with no running eval and no hub heartbeat for minutes; exiting to free the host" cpu = cpu pid = getpid()
            flush(stdout); flush(stderr); exit(2)
        end
        running = "[" * join(("\"" * replace(String(id), "\\" => "\\\\", "\"" => "\\\"") * "\"" for id in runids), ",") * "]"
        gcms = round(Int, Base.gc_num().total_time / 1e6)
        warm = replace(_WARM_STATUS[], "\\" => "\\\\", "\"" => "\\\"")   # preload/precompile progress
        # System-wide load: host CPU% (delta), 1-min load average, and total/free RAM — the "in addition to
        # process-level" view for a region worker's whole box.
        sb, st = sysstat()
        syscpu = (st > 0 && lastst > 0 && st > lastst) ? round(100 * (sb - lastsb) / (st - lastst); digits = 1) : -1.0
        lastsb, lastst = sb, st
        load1 = try; round(Sys.loadavg()[1]; digits = 2); catch; -1.0; end
        smt = try; Int(Sys.total_memory()); catch; 0; end
        smf = try; Int(Sys.free_memory()); catch; 0; end
        line = "{\"cpu\":$cpu,\"rss\":$(rssbytes()),\"gc_ms\":$gcms,\"evals\":$evals," *
               "\"running\":$running,\"warm\":\"$warm\",\"memo_bytes\":$memo," *
               "\"sys_cpu\":$syscpu,\"load1\":$load1,\"sys_mem_total\":$smt,\"sys_mem_free\":$smf," *
               "\"ts\":$(round(Int, time()))}"
        try; KaimonGate._publish_stream("slate_telemetry", line); catch; end
        isempty(stats_path) || try                          # roster sidecar — remote workers only
            tmp = stats_path * ".tmp"
            write(tmp, line); mv(tmp, stats_path; force = true)
        catch
        end
    end
end

# An IO that mirrors writes to an inner stream (the worker's real stderr / log pipe) AND republishes each
# COMPLETED line over the gate stream as `slate_log`, so the hub can PUSH worker log records to open pages
# live (uniform for local + remote workers) instead of the browser polling the log file. Line-buffered:
# bytes accumulate until '\n', then the line (sans newline) is PUBbed. Thread-safe — many cells can log
# concurrently; the lock keeps one record from interleaving mid-line in the buffer.
mutable struct _LogTee <: IO
    inner::IO
    buf::IOBuffer
    lock::ReentrantLock
end
_LogTee(inner::IO) = _LogTee(inner, IOBuffer(), ReentrantLock())
function Base.unsafe_write(t::_LogTee, p::Ptr{UInt8}, n::UInt)
    lock(t.lock) do
        r = unsafe_write(t.inner, p, n)      # mirror verbatim to the real stream (file logging intact) — inside
        for i in 1:n                         # the lock so concurrent records can't interleave in the file or buffer
            b = unsafe_load(p, i)
            if b == UInt8('\n')
                line = String(take!(t.buf))
                isempty(line) || (try; KaimonGate._publish_stream("slate_log", line); catch; end)
            else
                write(t.buf, b)
            end
        end
        return r
    end
end
Base.flush(t::_LogTee) = flush(t.inner)
Base.isopen(t::_LogTee) = isopen(t.inner)
Base.get(t::_LogTee, k, d) = get(t.inner, k, d)   # IOContext property probing (e.g. :color) delegates through

# A logger wrapper that drops ONE benign message: `Base.Docs`' "Replacing docs for `X`" warning.
# Reactive re-evaluation redefines a cell's documented structs/functions on every run, so Base.Docs
# would warn each time — noise the user can't act on (the docstring is still registered, which is
# exactly what feeds the docs index). Everything else passes through untouched.
struct _DocsQuietLogger{L<:Logging.AbstractLogger} <: Logging.AbstractLogger
    inner::L
end
Logging.min_enabled_level(l::_DocsQuietLogger) = Logging.min_enabled_level(l.inner)
Logging.catch_exceptions(l::_DocsQuietLogger) = Logging.catch_exceptions(l.inner)
Logging.shouldlog(l::_DocsQuietLogger, args...) = Logging.shouldlog(l.inner, args...)
function Logging.handle_message(l::_DocsQuietLogger, level, message, args...; kwargs...)
    (level == Logging.Warn && occursin("Replacing docs for", string(message))) && return nothing
    return Logging.handle_message(l.inner, level, message, args...; kwargs...)
end

"""
    start(; host="127.0.0.1", port, stream_port)

Run the worker gate over TCP, exposing the capture tools. Blocks (this is the
worker process's main loop). `warm_deps=true` (pool workers) background-imports every direct
dep of the active project so package-load time is paid while idle; `stats_path` (remote
workers) turns on the 2s telemetry sampler writing that sidecar + PUBbing `slate_telemetry`.
"""
function start(; host::String = "127.0.0.1", port::Int, stream_port::Int,
               curve::Bool = false, allowed_clients::Vector{String} = String[],
               data_port::Int = 0, warm_deps::Bool = false, stats_path::String = "",
               blob_curve::Bool = true, blob_bind::String = "", blob_free_port::Bool = false)
    _STREAM_PORT[] = stream_port   # publish for `__slate_ports` (hub-assigned today; the hub owns only the gate)
    # Install the task-demux as stdout/stderr + a task-local capture display, so cell evaluators can
    # run CONCURRENTLY in this one process while each captures its own output (see demux.jl, capture.jl
    # DemuxCapture). Non-cell output falls through to the real streams (the worker log). Once installed,
    # all cell capture in this process MUST use DemuxCapture (RedirectCapture's restore can't redirect
    # back to the custom IO).
    try; install_demux!(); pushdisplay(_DemuxDisplay()); catch e; @warn "slate: demux install failed" exception = e; end
    # Timestamp every worker log record (local file + remote tail) so a bring-up / eval is legible after
    # the fact — the default logger emits none. Prepends `HH:MM:SS ` to the metadata prefix.
    try
        # Tee the log stream so every formatted record ALSO PUBs on `slate_log` (→ hub → the worker popup,
        # live) while still writing to the worker-<port>.log file. Mirrors the pipe that `worker_log_tail`
        # reads, so the pushed lines and the polled snapshot are the same text.
        Base.global_logger(_DocsQuietLogger(Logging.ConsoleLogger(_LogTee(stderr), Logging.Info;
            meta_formatter = (lvl, m, g, id, f, l) -> begin
                c, pre, suf = Logging.default_metafmt(lvl, m, g, id, f, l)
                (c, string(Dates.format(Dates.now(), "HH:MM:SS "), pre), suf)
            end)))
    catch e; @warn "slate: timestamp logger install failed" exception = e; end
    # `curve`/`allowed_clients` are set for a REMOTE worker (host="0.0.0.0", :direct transport): the
    # hub pins THIS gate's CURVE server key (fetched over SSH) and the gate allow-lists the hub's client
    # key — proper mutual auth. Local + :ssh_tunnel workers leave them off (loopback / SSH-encrypted).
    _blog("start(): entering KaimonGate.serve")
    KaimonGate.serve(; mode = :tcp, host = host, port = port, stream_port = stream_port,
                     tools = tools(), force = true, allow_mirror = false,
                     allow_restart = false, spawned_by = "slate",
                     curve = curve, allowed_clients = allowed_clients)
    _blog("start(): gate SERVING — port reachable (hub can dial now)")
    # DEFERRED (~5s): Revise/src-watcher setup is heavy compilation; running it now would contend for
    # the codegen lock with the hub's CURVE handshake in the first seconds after the port opens (the
    # handshake path is precompiled but still needs the lock free to run fast). Let the attach win the
    # quiet CPU first, then set up hot-reload.
    Threads.@spawn begin
        sleep(5)
        try; _start_src_watcher(); catch e; @warn "slate worker: src-watcher start failed" exception = e; end
    end
    # The blob data channel (port+2): bulk memo transfer that never queues ahead of cell results.
    # ALWAYS CURVE (decoupled from hub transport): allow-listed on :direct (its OWN Slate-side ZAP
    # handler + allow-file, not the gate's), encryption-only behind SSH on :tunnel. No plaintext blob
    # path on any worker. Needs the memo/CAS layer (MemoStore + codecs) — memo-off means no store to serve.
    data_port > 0 && _MEMO_OK && Threads.@spawn begin
        sleep(5)   # DEFERRED: another CURVE-server setup; keep it out of the hub's handshake window
        # The blob server binds `blob_bind` when given (remote workers → 0.0.0.0 so same-subnet PEERS can
        # reach it for direct pulls) else the gate's `host` (local → loopback). CURVE-protected regardless
        # (a peer must hold the server key to even handshake), so exposing it on a firewalled cloud subnet
        # is safe; peer allow-listing over :tunnel is the follow-on hardening.
        #
        # PORT SELECTION. A `:tunnel` worker's blob channel has no firewall/peer-dial constraint (the hub
        # discovers the port via `__slate_ports` and bridges it over ssh), so it binds a VERIFIED-FREE port
        # up front (`blob_free_port`) rather than the hub-assigned `gate+2` — a co-tenant holding `gate+2` on
        # a shared host then can't stall it (the old bug: same-port retries never cleared sustained
        # contention, so the worker ran blob-LESS for life and every pull FROM it relayed / an ssh-bridge
        # stalled). A `:direct` worker MUST bind the pinned `gate+2` (firewall-opened + dialed directly by
        # peers), so it keeps that port; a warm respawn / reap-replace can briefly RACE the predecessor's
        # not-yet-released socket there, so retry the SAME port a few times, then give up loudly.
        # `_blob_server!` only returns on shutdown, so reaching past it means a clean stop, not a bind failure.
        bind_host = isempty(blob_bind) ? host : blob_bind
        port_try = blob_free_port ? _free_local_port() : data_port
        for attempt in 1:12
            try
                _blob_server!(bind_host, port_try; curve = blob_curve)
                break
            catch e
                if !occursin("Address already in use", sprint(showerror, e))
                    @warn "slate worker: blob channel died" port = port_try exception = e
                    break
                end
                if blob_free_port
                    port_try = _free_local_port()   # a just-probed-free port lost a rare race — pick another
                    @info "slate worker: blob port raced, re-picking a free port" port = port_try attempt = attempt
                    sleep(0.2)
                elseif attempt < 12
                    @info "slate worker: blob port busy (pinned), retrying" port = port_try attempt = attempt
                    sleep(1.5)
                else
                    @warn "slate worker: blob channel gave up — pinned port stayed busy" port = port_try
                end
            end
        end
    end
    # Dedicated transfer executor — pumps queued peer pulls (verb `X`) on a default-pool thread, off the
    # gate loop and off the blob serve loop (TRANSFER_CONTROL_PLAN Mode A). One task = serial per worker.
    data_port > 0 && _MEMO_OK && Threads.@spawn try; _xfer_executor!(); catch e
        @warn "slate worker: transfer executor died" exception = e
    end
    # Reap idle/dead pooled ssh forwards so a peer pair that stops transferring releases its held SSH
    # connection; kill them all on shutdown so exit never orphans the standing ssh children.
    if data_port > 0 && _MEMO_OK
        atexit(_ssh_fwd_killall!)
        Threads.@spawn try
            while true; sleep(30); _ssh_fwd_reap_idle!(); end
        catch e
            @warn "slate worker: ssh-forward reaper died" exception = e
        end
    end
    @info "slate worker: ready" port = port tools = length(tools()) revise = isdefined(Main, :Revise)
    # A memo-off worker used to be SILENT (every store/restore just returned early) — the single
    # hardest-to-spot degradation, since cells still run fine and only recompute. Say it once, loudly.
    _MEMO_OK || @warn "slate worker: durable memo DISABLED — cache tags and restores are no-ops" exception = _MEMO_ERR[]
    # Prewarm the eval path: the FIRST run through `_eval_one`/`run_capture` pays ~4s of JIT
    # (measured — eval/capture/demux/repr machinery all compiling), which otherwise lands under
    # the user's first cell. Compile it NOW, in the background: the port is already serving, so
    # a real eval arriving mid-prewarm just serializes with it harmlessly (same total, never
    # worse) — while an idle-spawned worker (warm pool, detach target) has it fully paid before
    # anyone attaches. "1 + 1" exercises exactly the measured slow path; it writes no globals.
    Threads.@spawn try
        sleep(5)   # DEFERRED: this is the biggest boot compile — let the hub attach on a clear CPU first
        t0 = time()
        # Through the TOOL entry point (not _eval_one) so the wrapper + cancel-registry +
        # kwarg path compile too — the layers a real first request would otherwise JIT.
        __slate_eval("1 + 1"; filename = "cell:__prewarm__")
        @info "slate worker: eval pipeline prewarmed" ms = round(Int, (time() - t0) * 1000)
    catch e
        @warn "slate worker: prewarm failed (harmless — first cell just pays the JIT)" exception = e
    end
    # Pool warmth: pay package-load time NOW, while idle — import every direct dep of the active
    # project (which provisioning populated from the preload env). A failing dep is logged, not
    # fatal: the adopting notebook's own `using` cell will surface the real error with context.
    warm_deps && Threads.@spawn try
        t0 = time(); n = 0
        names = [nm for nm in sort!(collect(keys(Pkg.project().dependencies)))
                 if !(nm in ("KaimonGate", "Revise", "ExpressionExplorer"))]
        total = length(names)
        for name in names
            _WARM_STATUS[] = "warming $(n)/$(total) · $(name)"   # live status → telemetry → the pool UI
            try
                Base.require(Main, Symbol(name)); n += 1          # loads + precompiles if needed
            catch e
                @warn "slate worker: warm-deps import failed" pkg = name exception = e
            end
        end
        _WARM_STATUS[] = "ready · $(n) pkgs · $(round(Int, (time() - t0) * 1000))ms"
        @info "slate worker: warm deps loaded" pkgs = n ms = round(Int, (time() - t0) * 1000)
    catch e
        _WARM_STATUS[] = "warm failed"
        @warn "slate worker: warm-deps pass died" exception = e
    end
    # Cold-env narration (attached workers; pool workers already warm via `warm_deps` above). If this
    # notebook's project isn't precompiled — the classic slow Makie open — precompile it in the background
    # NOW and stream structured progress, so a cold open reads as "Preparing packages · precompiling k/N"
    # instead of a frozen "Running 0/N". Non-blocking; a warm env is a near-instant no-op.
    warm_deps || Threads.@spawn try
        _prepare_env!()
    catch e
        @warn "slate worker: prepare pass died" exception = e
    end
    # Sample every worker — local kernels too. The `.stats` sidecar is still remote-only (empty
    # stats_path skips it), but the `slate_telemetry` PUB now flows from every worker process, so the
    # hub's watchdog can see cpu/rss/gc on a local kernel and not just remote regions.
    Threads.@spawn try
        _telemetry_loop!(stats_path)
    catch e
        @warn "slate worker: telemetry sampler died" exception = e
    end
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
