# ── SlateDiag — instrumentation you can leave in, and switch on when you need it ──────────────────
#
# Written after an afternoon of hand-rolled probes answered a "why is the hub busy?" question badly:
# each guess needed its own throwaway route, three of them were wrong, and the one measurement that
# settled it (allocations attributed to source lines) took four attempts to aim correctly. The point
# of this module is that the next such question is answered by turning something on.
#
# OFF by default. Disabled, every hook here is a single `Ref` read and a branch, so it can sit on the
# request path permanently. Enable at boot with `KAIMONSLATE_DIAG=1`, or at runtime through
# `/api/_diag/on` — a hub that has already gone strange does not have to be restarted to be measured,
# which matters because restarting is what destroys the state you were trying to look at.
#
# Three things it records, because they answer different questions:
#   per-request timing   — which route is slow, and how slow at worst rather than on average
#   registry gauges      — what the hub keeps between requests, and whether any of it only grows
#   allocation sites     — where the garbage comes from when nothing is supposed to be happening
module SlateDiag

import Profile

export diag_enabled, diag_enable!, diag_record!, diag_gauge!, diag_snapshot, diag_log_line

const _ON = Ref(false)
const _LOCK = ReentrantLock()

diag_enabled() = _ON[]
function diag_enable!(on::Bool = true)
    _ON[] = on
    on || reset!()          # leaving stale numbers behind invites reading them as current
    return on
end
__init__() = (_ON[] = get(ENV, "KAIMONSLATE_DIAG", "") in ("1", "true", "on"); nothing)

# ── per-request ───────────────────────────────────────────────────────────────────────────────────
# One entry per route KEY, not per request: a hub serves thousands of requests and the useful shape
# is the aggregate plus the worst case. `max_ns` is kept because a route that is usually fast and
# occasionally terrible averages to "fine", and it is the occasional that people notice.
mutable struct RouteStat
    calls::Int
    errors::Int
    total_ns::Int
    max_ns::Int
    bytes::Int
    last_ns::Int
end
RouteStat() = RouteStat(0, 0, 0, 0, 0, 0)

const _ROUTES = Dict{String,RouteStat}()

"""
    diag_record!(key, ns, bytes, ok)

Record one served request. Cheap and lock-guarded; callers should check `diag_enabled()` first so a
disabled hub does not even build the key.

`bytes` is APPROXIMATE under concurrency: it comes from a process-wide allocation counter, so a
request measured while other tasks run is charged for their allocation too. Good enough to find a
route that allocates a thousand times more than its neighbours, useless as an exact figure.
"""
function diag_record!(key::AbstractString, ns::Integer, bytes::Integer, ok::Bool)
    lock(_LOCK) do
        st = get!(RouteStat, _ROUTES, String(key))
        st.calls += 1
        ok || (st.errors += 1)
        st.total_ns += Int(ns)
        st.last_ns = Int(ns)
        Int(ns) > st.max_ns && (st.max_ns = Int(ns))
        st.bytes += Int(bytes)
    end
    return nothing
end

# The route KEY, not the raw target: `/api/<uuid>/cell/<id>` is one route with two variables, and
# keeping them apart would give a million buckets of one call each.
function diag_key(method::AbstractString, target::AbstractString)
    t = first(split(String(target), '?'))
    t = replace(t, r"/n/[^/]+" => "/n/{id}")
    t = replace(t, r"/api/[0-9a-zA-Z_.-]{8,}/" => "/api/{id}/")
    t = replace(t, r"/(blob|output|asset)/[^/]+" => s"/\1/{name}")
    return string(method, " ", t)
end

# ── gauges ────────────────────────────────────────────────────────────────────────────────────────
# Registered by whoever owns the state, so this module needs no knowledge of the hub's internals and
# nothing has to be kept in sync when a registry is added or renamed.
const _GAUGES = Dict{String,Any}()

diag_gauge!(name::AbstractString, f) = (lock(_LOCK) do; _GAUGES[String(name)] = f; end; nothing)

function gauges()
    d = Dict{String,Int}()
    for (k, f) in (lock(_LOCK) do; collect(_GAUGES); end)
        d[k] = try; Int(f()); catch; -1; end
    end
    return d
end

# ── snapshots ─────────────────────────────────────────────────────────────────────────────────────
function runtime_stats()
    g = Base.gc_num()
    return Dict{String,Any}(
        "threads" => Threads.nthreads(),
        "interactive" => (try; Threads.nthreads(:interactive); catch; -1; end),
        "gcthreads" => (try; Threads.ngcthreads(); catch; -1; end),
        "gc_pause" => g.pause, "gc_full_sweep" => g.full_sweep,
        "gc_total_time_ns" => g.total_time, "gc_poolalloc" => g.poolalloc,
        "gc_bigalloc" => g.bigalloc,
        "live_bytes" => (try; Base.gc_live_bytes(); catch; -1; end))
end

function diag_snapshot()
    routes = lock(_LOCK) do
        [Dict{String,Any}("route" => k, "calls" => v.calls, "errors" => v.errors,
                          "mean_ms" => v.calls == 0 ? 0.0 : round(v.total_ns / v.calls / 1e6; digits = 3),
                          "max_ms" => round(v.max_ns / 1e6; digits = 3),
                          "last_ms" => round(v.last_ns / 1e6; digits = 3),
                          "mb" => round(v.bytes / 2^20; digits = 2))
         for (k, v) in _ROUTES]
    end
    sort!(routes; by = r -> -r["calls"])
    return Dict{String,Any}("enabled" => _ON[], "routes" => routes,
                            "runtime" => runtime_stats(), "gauges" => gauges())
end

reset!() = (lock(_LOCK) do; empty!(_ROUTES); end; nothing)

# ── the periodic line ─────────────────────────────────────────────────────────────────────────────
# On demand is no use for something that builds up over hours: nobody polls a hub all afternoon, and
# a leak is only visible as a series. Deltas since the previous line, so the shape is readable
# without diffing by eye; zero-valued gauges are omitted so a quiet hub logs a short line.
const _LAST = Dict{String,Int}()
const _LAST_AT = Ref(0.0)

"""
    diag_log_line(; every = 300.0) -> Union{String,Nothing}

The next periodic summary, or `nothing` when it is not due yet. Returned rather than logged so the
caller owns the logging (and its rate limiting) — this module has no opinion about where output goes.

Runs even when disabled: gauges are cheap, and a leak that only appears in production is exactly the
one nobody thought to switch instrumentation on for.
"""
function diag_log_line(; every::Real = 300.0)
    time() - _LAST_AT[] < every && return nothing
    first_run = _LAST_AT[] == 0.0
    _LAST_AT[] = time()
    g = gauges()
    parts = String[]
    for k in sort!(collect(keys(g)))
        v = g[k]
        # Baseline EVERY gauge, including the zeroes. Skipping the record along with the printing
        # leaves a stale baseline behind, so a registry that empties and refills reports the delta
        # against whatever it held before it emptied.
        prev = get(_LAST, k, -1); _LAST[k] = v
        v > 0 || continue                       # printed only when there is something to say
        d = (first_run || prev < 0) ? 0 : v - prev
        push!(parts, d == 0 ? "$k=$v" : string(k, "=", v, "(", d > 0 ? "+" : "", d, ")"))
    end
    mb = try; round(Int, Base.gc_live_bytes() / 2^20); catch; -1; end
    return "diag: live=$(mb)MB " * join(parts, " ")
end

# ── allocation attribution ────────────────────────────────────────────────────────────────────────
"""
    alloc_sites(; seconds = 5.0, rate = 0.0005, limit = 25)

Where allocations come from, by source line. The only way to find a hot idle loop: a process doing
nothing should not allocate, and when it does the cost shows up on the GC threads rather than
anywhere that looks busy.

`rate` is a sampling FRACTION — keep it small on a hot process. Each sample is attributed to the
innermost frame outside Julia's own trees: the useful answer is which of OUR loops runs hot, and
stopping at the innermost frame overall answers every such question with `readline`.
"""
function alloc_sites(; seconds::Real = 5.0, rate::Real = 0.0005, limit::Integer = 25)
    secs = clamp(Float64(seconds), 0.5, 60.0)
    r = clamp(Float64(rate), 1e-6, 1.0)
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate = r sleep(secs)
    res = Profile.Allocs.fetch()
    tally = Dict{String,Tuple{Int,Int}}()
    for a in res.allocs
        site = _first_own_frame(a.stacktrace)
        n, b = get(tally, site, (0, 0))
        tally[site] = (n + 1, b + a.size)
    end
    top = sort!(collect(tally); by = kv -> -kv[2][1])
    return Dict{String,Any}(
        "seconds" => secs, "rate" => r, "sampled" => length(res.allocs),
        "per_second" => round(Int, length(res.allocs) / r / secs),
        "top" => [Dict("site" => k, "count" => v[1], "bytes" => v[2])
                  for (k, v) in top[1:min(end, Int(limit))]])
end

# Julia's own trees, so a frame from them can be skipped past. Resolved once and kept.
const _JL_ROOTS = String[]
function _jl_roots()
    isempty(_JL_ROOTS) || return _JL_ROOTS
    for p in (Sys.STDLIB, abspath(Sys.BINDIR, "..", "share", "julia"))
        try; push!(_JL_ROOTS, abspath(String(p))); catch; end
    end
    return _JL_ROOTS
end

# Base reports its frames by BARE RELATIVE filename (`io.jl`, `iostream.jl`), never as a path
# containing `Base`, so a substring test on the path silently matches nothing and every stack stops
# on its innermost Base frame. `isabspath` is what actually separates them; stdlib is absolute, and
# is excluded by root instead.
_is_own_file(f::AbstractString) =
    endswith(f, ".jl") && isabspath(f) && !any(r -> startswith(f, r), _jl_roots())

# The innermost frame belonging to code we ship or depend on. `readline` allocating says nothing;
# the loop calling it in a cycle is the answer.
function _first_own_frame(st)
    for fr in st
        _is_own_file(String(fr.file)) && return string(basename(String(fr.file)), ":", fr.line, " ", fr.func)
    end
    # All Julia's own: report the innermost frame rather than dropping the sample, marked so it is
    # not mistaken for one of ours.
    i = findfirst(fr -> endswith(String(fr.file), ".jl"), st)
    return i === nothing ? "(no julia frames)" :
           string("[julia] ", basename(String(st[i].file)), ":", st[i].line, " ", st[i].func)
end

end # module SlateDiag
