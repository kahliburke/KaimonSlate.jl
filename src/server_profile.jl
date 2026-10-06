# ── Cell profiler: the hub's side ──────────────────────────────────────────────────────────────
#
# The sampling and the tree are built where the cell runs (profile.jl, `ReportEngine.profile_*`):
# this file resolves that kernel, turns a Run into an ordinary forced run of the cell with a profile
# armed for it, and pushes what comes back to every open page. A region cell is profiled on its node
# by the same calls, since a region kernel is a GateKernel like any other.
#
# Everything here is asynchronous and pushed (`profile:` on the page socket): compiling a cell's
# packages for a prepare, or running a long cell, takes as long as it takes, and the dock follows
# the pushes rather than a request held open.

const _PROF_LAST = Dict{Tuple{String,String},Dict{String,Any}}()   # (nb, cell) → last pushed result
const _PROF_HUB_LOCK = ReentrantLock()

_broadcast_profile(nb::LiveNotebook, payload::Dict{String,Any}) =
    (try; _broadcast(nb, "profile:" * JSON.json(_json_finite(payload))); catch; end; nothing)

function _profile_cell(nb::LiveNotebook, cid::AbstractString)
    i = findfirst(c -> c.id == cid, nb.report.cells)
    i === nothing && return nothing
    c = nb.report.cells[i]
    return c.kind == CODE ? c : nothing
end

# The cell's kernel, or why there is none to profile on. A region with no worker is not started
# here: the dock says so, and the worker panel's Start or a run of the cell brings one up.
function _profile_kernel(nb::LiveNotebook, side::AbstractString)
    return try
        (lock(_eval_mutex(nb)) do; _side_kernel!(nb, side); end, "")
    catch e
        e isa RegionWaiting ? (nothing, "the $(side) region has no worker yet: start it from its worker panel, or run the cell") :
                              (nothing, first(sprint(showerror, e), 300))
    end
end

function _profile_fail(nb::LiveNotebook, cid::AbstractString, side::AbstractString, why::AbstractString)
    _broadcast_profile(nb, Dict{String,Any}("kind" => "error", "cell" => String(cid), "side" => String(side),
                                            "error" => String(why)))
    return Dict{String,Any}("ok" => false, "error" => String(why))
end

"""
    prepare_profile!(nb, cid) -> Dict

Compile cell `cid`'s code where it runs, without running it, in the background. The page hears
`preparing`, then `prepared` with what was compiled.
"""
function prepare_profile!(nb::LiveNotebook, cid::AbstractString)
    cell = _profile_cell(nb, cid)
    cell === nothing && return Dict{String,Any}("ok" => false, "error" => "no code cell '$cid'")
    _, side = _region_route(nb, cell)
    src = cell.source; reads = String[String(r) for r in cell.reads]
    _broadcast_profile(nb, Dict{String,Any}("kind" => "preparing", "cell" => String(cid), "side" => side))
    Threads.@spawn try
        k, why = _profile_kernel(nb, side)
        k === nothing && return _profile_fail(nb, cid, side, why)
        r = lock(_eval_mutex(nb)) do
            ReportEngine.profile_prepare!(k, nb.report; cell = String(cid), source = src, reads = reads)
        end
        _broadcast_profile(nb, merge(Dict{String,Any}(r), Dict{String,Any}("kind" => "prepared", "side" => side)))
    catch e
        _profile_fail(nb, cid, side, first(sprint(showerror, e), 300))
    end
    return Dict{String,Any}("ok" => true)
end

"""
    run_profile!(nb, cid; mode) -> Dict

Profile cell `cid`: arm a profile for it on its kernel, run it as its ▶ would (so its output,
bindings and memo entry are the run's), and push the profile when the run is over.
"""
function run_profile!(nb::LiveNotebook, cid::AbstractString; mode::AbstractString = "cpu")
    cell = _profile_cell(nb, cid)
    cell === nothing && return Dict{String,Any}("ok" => false, "error" => "no code cell '$cid'")
    _, side = _region_route(nb, cell)
    _broadcast_profile(nb, Dict{String,Any}("kind" => "running", "cell" => String(cid), "side" => side,
                                            "mode" => String(mode)))
    Threads.@spawn try
        k, why = _profile_kernel(nb, side)
        k === nothing && return _profile_fail(nb, cid, side, why)
        lock(_eval_mutex(nb)) do
            ReportEngine.profile_arm!(k, nb.report; cell = String(cid), mode = String(mode))
        end
        t0 = time()
        lock(nb.lock) do; _force_cell!(nb, cid); end
        _eval!(nb; wait_for = cid)
        r = lock(_eval_mutex(nb)) do
            ReportEngine.profile_result(k, nb.report; cell = String(cid))
        end
        if r === nothing || Float64(get(r, "at", 0.0)) < t0
            try; lock(_eval_mutex(nb)) do; ReportEngine.profile_disarm!(k, nb.report; cell = String(cid)); end; catch; end
            c = _profile_cell(nb, cid)
            state = c === nothing ? "" : (c.state == BLOCKED ? " (it is waiting: $(c.blocked))" : "")
            return _profile_fail(nb, cid, side, "the cell did not run$state")
        end
        payload = Dict{String,Any}("kind" => "result", "cell" => String(cid), "side" => side,
                                   "source" => _profile_cell(nb, cid).source, "profile" => r)
        lock(_PROF_HUB_LOCK) do; _PROF_LAST[(nb.id, String(cid))] = payload; end
        _broadcast_profile(nb, payload)
    catch e
        _profile_fail(nb, cid, side, first(sprint(showerror, e), 300))
    end
    return Dict{String,Any}("ok" => true)
end

"The last profile pushed for `cid`, for a dock opened after it was taken."
last_profile(nb::LiveNotebook, cid::AbstractString) =
    lock(_PROF_HUB_LOCK) do; get(_PROF_LAST, (nb.id, String(cid)), nothing); end

"""
    profile_source(nb, cid, file) -> Dict

The text of `file` for the profile's code pane. A cell's file (`cell:<id>`) is the notebook's own
text, which no kernel has; anything else is read on the machine the cell ran on.
"""
function profile_source(nb::LiveNotebook, cid::AbstractString, file::AbstractString)
    f = String(file)
    if startswith(f, "cell:")
        c = _profile_cell(nb, f[6:end])
        c === nothing && return Dict{String,Any}("file" => f, "text" => "", "error" => "no such cell")
        return Dict{String,Any}("file" => f, "path" => f, "text" => c.source, "error" => nothing)
    end
    cell = _profile_cell(nb, cid)
    cell === nothing && return Dict{String,Any}("file" => f, "text" => "", "error" => "no code cell '$cid'")
    _, side = _region_route(nb, cell)
    k, why = _profile_kernel(nb, side)
    k === nothing && return Dict{String,Any}("file" => f, "text" => "", "error" => why)
    return try
        Dict{String,Any}(lock(_eval_mutex(nb)) do; ReportEngine.profile_source(k, nb.report; file = f); end)
    catch e
        Dict{String,Any}("file" => f, "text" => "", "error" => first(sprint(showerror, e), 300))
    end
end

function _register_profile_routes!(router, h::Hub)
    HTTP.register!(router, "POST", "/api/{id}/profile/prepare", req -> _withnb(h, req, nb ->
        _json(prepare_profile!(nb, String(get(_body(req), "cell", ""))))))
    HTTP.register!(router, "POST", "/api/{id}/profile/run", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        _json(run_profile!(nb, String(get(b, "cell", "")); mode = String(get(b, "mode", "cpu"))))
    end))
    HTTP.register!(router, "GET", "/api/{id}/profile/last", req -> _withnb(h, req, nb -> begin
        q = HTTP.queryparams(HTTP.URI(req.target))
        p = last_profile(nb, String(get(q, "cell", "")))
        _json(_json_finite(p === nothing ? Dict{String,Any}("kind" => "none") : p))
    end))
    HTTP.register!(router, "GET", "/api/{id}/profile/source", req -> _withnb(h, req, nb -> begin
        q = HTTP.queryparams(HTTP.URI(req.target))
        _json(profile_source(nb, String(get(q, "cell", "")), String(get(q, "file", ""))))
    end))
end
