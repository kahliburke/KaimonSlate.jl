# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Client-rendered image snapshots ───────────────────────────────────────────
# Client-side visuals (ECharts) only render in the browser, so the SPA captures their
# PNG from the canvas and posts it here, keyed by (notebook, cell). That gives a
# UNIFORM image interface: `cell_image` returns a PNG whether the figure was produced
# server-side (CairoMakie's `image/png`) or client-side (ECharts) — one approach for
# the agent (`slate_view`) today, and the source of figure bytes for PDF export later.
# Browser diagnostics: the open tab pushes its captured console errors / failed requests /
# unhandled rejections here (on load + debounced on each new entry; see assets/js/diag.js), so
# `slate.diag` can report the console state without a headless browser. One payload per tab.
const _DIAG = Dict{String,Any}()                               # nbid → last pushed payload
const _DIAG_LOCK = ReentrantLock()
set_diag!(nbid, payload) = lock(_DIAG_LOCK) do; _DIAG[String(nbid)] = payload; end
get_diag(nbid) = lock(_DIAG_LOCK) do; get(_DIAG, String(nbid), nothing); end

# Human-readable diagnostics for the `slate.diag` MCP tool.
function diag_report(nb::LiveNotebook)
    d = get_diag(nb.id)
    d === nothing && return "No browser has reported diagnostics for '$(nb.id)' yet. Open the " *
        "notebook in a browser (it pushes on load) and retry."
    entries = get(d, "entries", Any[])
    io = IOBuffer()
    url = string(get(d, "url", "")); ts = string(get(d, "ts", ""))
    println(io, "Browser diagnostics for '", nb.id, "'", isempty(url) ? "" : "  ($url)")
    println(io, "session ", get(d, "session", "?"), isempty(ts) ? "" : "  @ $ts")
    if isempty(entries)
        println(io, "\n✓ clean — no console errors, failed requests, or unhandled rejections.")
    else
        println(io, "\n", length(entries), " entr", length(entries) == 1 ? "y" : "ies", ":")
        for e in entries
            println(io, "  [", get(e, "kind", "?"), "] ", get(e, "text", ""))
        end
    end
    return String(take!(io))
end

# Package-name completion for the Add box — all names across the reachable registries (General
# + any others), cached after the first scan (the set is static for the process lifetime).
const _PKG_NAMES = Ref{Vector{String}}()
function _pkg_names()
    isassigned(_PKG_NAMES) && return _PKG_NAMES[]
    names = String[]
    try
        for reg in Pkg.Registry.reachable_registries(), (_, e) in reg.pkgs
            push!(names, e.name)
        end
    catch
    end
    try   # stdlibs (LinearAlgebra, Statistics, …) aren't in the registries but are addable
        for d in readdir(Sys.STDLIB)
            isdir(joinpath(Sys.STDLIB, d)) && push!(names, d)
        end
    catch
    end
    _PKG_NAMES[] = sort!(unique!(names))
end
# Rank: exact match first, then prefix matches, then substring; case-insensitive; capped.
function _pkg_complete(q::AbstractString, limit::Int = 50)
    q = lowercase(strip(q)); isempty(q) && return String[]
    names = _pkg_names()
    exact = filter(n -> lowercase(n) == q, names)
    pre = filter(n -> lowercase(n) != q && startswith(lowercase(n), q), names)
    sub = filter(n -> !startswith(lowercase(n), q) && occursin(q, lowercase(n)), names)
    first(vcat(exact, pre, sub), limit)
end

const _SNAPSHOTS = Dict{String,Dict{String,Vector{UInt8}}}()   # nbid → cellid → latest PNG
const _SNAP_SVG = Dict{String,Dict{String,String}}()           # nbid → cellid → latest light-theme SVG (vector)
const _SNAP_SVG_DARK = Dict{String,Dict{String,String}}()      # nbid → cellid → latest dark-theme SVG (vector)
const _SNAP_LOCK = ReentrantLock()
function set_snapshot!(nbid::AbstractString, cell::AbstractString, png::Vector{UInt8};
                       svg::Union{AbstractString,Nothing} = nothing,
                       svg_dark::Union{AbstractString,Nothing} = nothing)
    lock(_SNAP_LOCK) do
        get!(_SNAPSHOTS, String(nbid), Dict{String,Vector{UInt8}}())[String(cell)] = png
        svg === nothing || (get!(_SNAP_SVG, String(nbid), Dict{String,String}())[String(cell)] = String(svg))
        svg_dark === nothing || (get!(_SNAP_SVG_DARK, String(nbid), Dict{String,String}())[String(cell)] = String(svg_dark))
    end
    return nothing
end
_snapshot(nbid, cell) = lock(_SNAP_LOCK) do
    get(get(_SNAPSHOTS, String(nbid), Dict{String,Vector{UInt8}}()), String(cell), nothing)
end
# Vector (SVG) snapshot of a client-rendered chart for PDF export — crisp at any scale.
# `dark` picks the dark-theme rendering (for a dark-mode PDF). `nothing` if absent.
_snapshot_svg(nbid, cell; dark::Bool = false) = lock(_SNAP_LOCK) do
    store = dark ? _SNAP_SVG_DARK : _SNAP_SVG
    get(get(store, String(nbid), Dict{String,String}()), String(cell), nothing)
end

"""
    cell_image(nb, cell) -> Vector{UInt8} | nothing

A PNG of the cell's rendered figure, regardless of where it was drawn: the server-side
raster (CairoMakie `image/png`) if present, else the latest client-captured snapshot
(ECharts). `nothing` if the cell has no viewable figure.
"""
function cell_image(nb::LiveNotebook, cell::AbstractString)
    i = findfirst(c -> c.id == cell, nb.report.cells)
    i === nothing && return nothing
    o = nb.report.cells[i].output
    if o !== nothing
        for ch in o.display
            ch.mime == "image/png" && return copy(ch.data)
        end
    end
    return _snapshot(nb.id, cell)
end

# ── Live cell inspect — round-trip capture from the open browser ──────────────
# `slate.inspect` asks the open tab to capture a cell's rendered DOM + console + a raster, so an
# agent can SEE what actually rendered (not just the canonical result). We push an `inspect:<json>`
# SSE event carrying a reqid, then block on a per-reqid channel until the browser POSTs
# /api/<id>/inspect-result (assets/js/inspect.js) or a short timeout elapses. No open tab → return
# `nothing` (text-only inspect, exactly the pre-phase-2 behaviour — never hangs).
const _INSPECT_PENDING = Dict{String,Channel{Any}}()
const _INSPECT_LOCK = ReentrantLock()
const _INSPECT_SEQ = Threads.Atomic{Int}(0)
_inspect_reqid() = string(Threads.atomic_add!(_INSPECT_SEQ, 1); base = 16)

# The POST handler hands the browser's capture to the waiting request. Returns whether a waiter existed.
function deliver_inspect!(reqid::AbstractString, payload)
    ch = lock(_INSPECT_LOCK) do; get(_INSPECT_PENDING, String(reqid), nothing); end
    ch === nothing && return false
    try; put!(ch, payload); catch; end
    return true
end

# Ask the open browser to capture cell `cellid`. Returns the capture payload (a Dict) or `nothing`
# (no live tab, or the browser didn't answer within `timeout`). Always deregisters the request.
# NOTE: call this OUTSIDE `nb.lock` — it blocks up to `timeout` and must not stall other notebook ops.
function request_live_inspect(nb::LiveNotebook, cellid::AbstractString; timeout::Real = 4.0)
    any_listener = lock(nb.llock) do; !isempty(nb.listeners); end
    any_listener || return nothing
    reqid = _inspect_reqid()
    ch = Channel{Any}(1)
    lock(_INSPECT_LOCK) do; _INSPECT_PENDING[reqid] = ch; end
    timer = Timer(_ -> (isopen(ch) && close(ch)), timeout)   # wakes the take! when the browser is silent
    try
        _broadcast(nb, "inspect:" * JSON.json(Dict("reqid" => reqid, "cell" => String(cellid))))
        return take!(ch)                 # the browser capture; throws once the timer closes the channel
    catch
        return nothing                   # timeout (channel closed) or any error → text-only inspect
    finally
        close(timer)
        lock(_INSPECT_LOCK) do; delete!(_INSPECT_PENDING, reqid); end
        isopen(ch) && close(ch)
    end
end

# Render a browser capture into the inspect text: cleaned DOM + this tab's console entries. The
# raster (if any) is routed to the snapshot store by the POST handler, so it shows via `slate.view`.
function _format_live_capture(cap)
    cap isa AbstractDict || return ""
    io = IOBuffer()
    html = strip(string(get(cap, "html", "")))
    isempty(html) || (println(io, "\n--- live DOM (rendered in the open browser) ---"); println(io, html))
    cons = get(cap, "console", nothing)
    if cons isa AbstractVector && !isempty(cons)
        println(io, "\n--- console (this tab) ---")
        for e in cons
            e isa AbstractDict ? println(io, "  [", get(e, "kind", "?"), "] ", get(e, "text", "")) :
                                 println(io, "  ", e)
        end
    end
    return String(take!(io))
end

