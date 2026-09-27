# ── Rendering doc bundles for a docs build ────────────────────────────────────────────────────────
# A docs build needs each notebook run the way the author runs it: in its own worker, with memo,
# `@replay` sweeps and themed figures. That is what a hub with a Kaimon gate does, so the renderer is a
# client of one — the hub the author already has running, or, on a machine with none (CI), an isolated
# embedded Kaimon host started for the render (`slate --ai`'s host, see embedded_kaimon.jl). The
# in-process kernel remains available for a quick render with none of that.

"""
    render_doc_bundle(notebook, dir; backend = :auto, light = "daylight", dark = "midnight",
                      timeout = 3600) -> Dict

Run `notebook` and write its doc bundle to `dir` (see `export_doc_bundle`), returning the manifest.

`backend`:
- `:hub` — through the Slate hub already answering on this machine's hub port.
- `:embedded` — start an isolated Kaimon host for the render, and stop it afterwards. The first
  start on a machine installs and precompiles Kaimon, which takes minutes.
- `:inprocess` — in this process, with no worker: no `@replay` sweeps, so controls export frozen.
- `:auto` (default) — the hub already on this machine if there is one (waiting for it if Kaimon is
  still bringing its Slate extension up), else `:embedded`.

`timeout` bounds each notebook's run, in seconds.
"""
render_doc_bundle(notebook::AbstractString, dir::AbstractString; kw...) =
    only(render_doc_bundles([notebook => dir]; kw...))

"""
    render_doc_bundles(jobs; kw...) -> Vector{Dict}

[`render_doc_bundle`](@ref) for several `notebook => dir` pairs, sharing one host.
"""
function render_doc_bundles(jobs; backend::Symbol = :auto, light::AbstractString = "daylight",
                            dark::AbstractString = "midnight", timeout::Real = 3600,
                            host_timeout::Real = 1800)
    jobs = [abspath(String(n)) => abspath(String(d)) for (n, d) in jobs]
    backend in (:auto, :hub, :embedded, :inprocess) ||
        throw(ArgumentError("backend must be :auto, :hub, :embedded or :inprocess"))
    if backend === :inprocess
        return [NotebookServer.render_doc_bundle_inprocess(n, d; light, dark, timeout) for (n, d) in jobs]
    end
    if backend === :auto
        # A Kaimon already hosting Slate is the host to use, even while its hub is still starting.
        backend = (_hub_running() || _kaimon_slate_extension_running()) ? :hub : :embedded
    end
    started = false
    if backend === :hub
        _await_hub(host_timeout)
    else
        _start_render_host!(host_timeout)
        started = true
    end
    try
        return [_render_via_hub(n, d; light, dark, timeout) for (n, d) in jobs]
    finally
        started && stop_embedded_kaimon!()
    end
end

# A Kaimon that spawned a Slate extension reaps any other process claiming that extension namespace
# as an orphan, and keeps the extension's environment under a path keyed by namespace alone. An
# embedded host started beside a running Kaimon would therefore take that Kaimon's hub down, so it is
# refused; the running hub is the one to render through.
_kaimon_slate_extension_running() = !isempty(_pids_matching("namespace=\"slate\""))

# Any Kaimon-hosted Slate, including a checkout registered under its own namespace (`slatedoc`, …):
# something that will answer on a hub port once it has loaded.
_kaimon_slate_family_running() = !isempty(_pids_matching("namespace=\"slate"))

function _await_hub(host_timeout::Real)
    _hub_running() && return nothing
    _kaimon_slate_family_running() ||
        error("render_doc_bundle: no Slate hub is answering at $(_base())")
    @info "render_doc_bundle: waiting for the Kaimon-hosted Slate hub at $(_base())"
    t0 = time()
    while !_hub_running()
        time() - t0 > host_timeout &&
            error("render_doc_bundle: Kaimon's Slate extension is running but no hub answered at " *
                  "$(_base()) within $(host_timeout)s. Is KAIMONSLATE_PORT the port it serves on?")
        sleep(1)
    end
    return nothing
end

function _start_render_host!(host_timeout::Real)
    _hub_running() && error("render_doc_bundle: a hub is already answering at $(_base()); " *
                            "render through it with `backend = :hub`")
    _kaimon_slate_extension_running() &&
        error("render_doc_bundle: a Kaimon-hosted Slate extension is running on this machine, and a " *
              "second host would displace it. Start its hub (or render with `backend = :hub`).")
    port = _free_mcp_port()
    @info "render_doc_bundle: starting an embedded Kaimon host" mcp_port = port hub = _base()
    start_embedded_kaimon!(port; online = line -> @debug(line))
    t0 = time()
    while !_hub_running()
        p = _EMBEDDED[]
        if p === nothing || !process_running(p)
            log = joinpath(_embedded_root(), "kaimon.log")
            error("render_doc_bundle: the embedded Kaimon host exited before its hub came up.\n" *
                  _log_tail(log, 20) * "\nFull log: $log")
        end
        if time() - t0 > host_timeout
            stop_embedded_kaimon!()
            error("render_doc_bundle: the embedded host's hub did not answer within $(host_timeout)s")
        end
        sleep(1)
    end
    @info "render_doc_bundle: hub is up" seconds = round(time() - t0; digits = 1)
    return nothing
end

function _free_mcp_port()
    for p in 2828:2900
        ReportEngine._port_free(p) && return p
    end
    error("render_doc_bundle: no free port in 2828–2900 for the embedded Kaimon host")
end

_hub_json(r) = JSON.parse(String(r.body))
_hub_get(path) = _hub_json(HTTP.get(_base() * path; retry = false, request_timeout = 60))
_hub_post(path, body; timeout = 60) =
    _hub_json(HTTP.post(_base() * path, ["Content-Type" => "application/json"], JSON.json(body);
                        retry = false, request_timeout = timeout))

# Open `path` in the hub, wait for its run to settle, write the bundle, and close it again — unless it
# was already open (the author has it in a tab), in which case it is left exactly as it was.
function _render_via_hub(path::AbstractString, dir::AbstractString; light, dark, timeout)
    wasopen = any(n -> n isa AbstractDict && get(n, "path", "") == path, _hub_get("/api/notebooks"))
    id = String(_hub_post("/api/open", Dict("path" => path))["id"])
    try
        t0 = time()
        quiet = 0
        while quiet < 2                      # two settled polls in a row: a run can hand over between cells
            st = _hub_get("/api/$id/state")
            err = get(st, "hydrateError", nothing)
            err === nothing || error("render_doc_bundle: $(basename(path)) failed to start: $err")
            busy = get(st, "hydrating", false) === true ||
                   any(c -> c isa AbstractDict && get(c, "state", "") == "running", get(st, "cells", Any[]))
            quiet = busy ? 0 : quiet + 1
            time() - t0 > timeout && error("render_doc_bundle: $(basename(path)) did not finish within $(timeout)s")
            sleep(0.5)
        end
        man = try
            _hub_post("/api/$id/docbundle", Dict("dir" => dir, "light" => light, "dark" => dark);
                      timeout = timeout)
        catch e
            (e isa HTTP.StatusError && e.status == 404) || rethrow()
            error("render_doc_bundle: the hub at $(_base()) runs a KaimonSlate without doc bundle " *
                  "support; update the KaimonSlate that Kaimon loads, then restart its extension")
        end
        errs = get(get(man, "rendered", Dict()), "errors", Any[])
        isempty(errs) || @warn "render_doc_bundle: cells raised errors; their error output is in the bundle" notebook = basename(path) cells = errs
        @info "render_doc_bundle: wrote $(basename(dir))" notebook = basename(path) cells = length(get(man, "cells", Any[]))
        return man
    finally
        wasopen || try; _hub_post("/api/close", Dict("path" => path)); catch; end
    end
end
