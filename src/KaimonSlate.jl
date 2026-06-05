"""
    KaimonSlate

A warm-session, **reactive** Julia notebook served as a live browser UI — packaged
as a Kaimon extension.

Cells evaluate in isolated modules; edits and `@bind` widgets drive *pruned*
reactive recompute; Makie/MIME figures and interactive ECharts render inline; the
source round-trips to a plain `.jl` file so the agent and the browser share one
source of truth.

It runs **out-of-process on HTTP 2.0**, independent of Kaimon core's HTTP version —
the two talk over the Gate (ZMQ), never a shared HTTP stack.

Standalone use:

```julia
using KaimonSlate
serve_notebook("notebook.jl"; port = 8765)   # blocks
```

As a Kaimon extension, `create_tools` exposes `slate.open` / `slate.list` /
`slate.close` to the agent, and Kaimon manages the subprocess lifecycle.
"""
module KaimonSlate

include("engine.jl")    # module ReportEngine (+ eval / deps / bind / echarts)
include("render.jl")    # module ReportRender
include("server.jl")    # module NotebookServer (uses ..ReportEngine, ..ReportRender)

using .ReportEngine
using .ReportRender
using .NotebookServer: serve_notebook, start_server, LiveNotebook,
                      Hub, start_hub, open_notebook!, close_notebook!, stop_hub

export serve_notebook, LiveNotebook

# ── Single-server hub ─────────────────────────────────────────────────────────
# The extension serves *all* notebooks from one HTTP 2.0 server on one port,
# routing per-notebook by id (`/n/<id>`, `/api/<id>/…`); `/` is a switcher index.
# The hub runs in the extension subprocess alongside the Gate loop.

# Port is configurable via the KAIMONSLATE_PORT env var (default 8765) so a
# config UI / launcher can pin it; the hub auto-starts at extension init.
const _PORT = something(tryparse(Int, get(ENV, "KAIMONSLATE_PORT", "8765")), 8765)
const _HUB = Ref{Union{Hub,Nothing}}(nothing)
const _LOCK = ReentrantLock()

_base() = "http://127.0.0.1:$_PORT"

# The running hub (started lazily on first open).
function _hub()
    lock(_LOCK) do
        _HUB[] === nothing && (_HUB[] = start_hub(; port = _PORT))
        return _HUB[]::Hub
    end
end

# Restart-reaping backstop: kill leftover worker subprocesses from a previous
# extension instance that exited non-gracefully (crash / hard kill), since that
# path skips `on_shutdown`. Each worker's boot script carries the `SlateWorker.start`
# marker in its argv, so `pgrep -f` finds exactly ours. Called once at init, BEFORE
# this instance spawns any worker, so it never targets our own children.
function _reap_orphan_workers!()
    try
        for line in split(readchomp(`pgrep -f SlateWorker.start`))
            pid = tryparse(Int, strip(line))
            pid === nothing && continue
            try; run(`kill -9 $pid`); catch; end
        end
    catch  # pgrep absent / no matches — nothing to reap
    end
    return nothing
end

# ── Extension entrypoints ─────────────────────────────────────────────────────

"""
    create_tools(GateTool) -> Vector{GateTool}

Tools exposed to the agent under the `slate.*` namespace. `GateTool` is passed in
so the extension needs no Kaimon dependency — handlers are plain typed functions,
reflected into MCP JSON Schema by Kaimon.
"""
function create_tools(GateTool::Type)

    """
        open(path::String) -> String

    Open a reactive notebook for the `.jl` file at `path` and start its live
    browser server (creating the file if it does not exist). Returns the URL.
    Opening the same file again returns the existing server.
    """
    function nb_open(path::String)::String
        path = expanduser(path)
        isfile(path) || write(path, "#%% md id=intro\n# New Notebook\n")
        h = _hub()
        id = open_notebook!(h, path)
        return "Serving $(abspath(path)) at $(_base())/n/$id"
    end

    """
        list() -> String

    List the notebooks currently being served and their URLs (index: the base URL).
    """
    function nb_list()::String
        h = _HUB[]
        (h === nothing || isempty(h.notebooks)) && return "No notebooks open."
        lines = lock(h.lock) do
            ["$(_base())/n/$(nb.id)  ←  $(abspath(nb.path))" for nb in values(h.notebooks)]
        end
        return join(["Index: $(_base())"; lines], "\n")
    end

    """
        close(path::String) -> String

    Stop serving the notebook at `path` (the hub stays up for the others).
    """
    function nb_close(path::String)::String
        h = _HUB[]
        h === nothing && return "Not open: $(abspath(path))"
        file = abspath(expanduser(path))
        id = lock(h.lock) do
            for nb in values(h.notebooks)
                abspath(nb.path) == file && return nb.id
            end
            return nothing
        end
        id === nothing && return "Not open: $file"
        close_notebook!(h, id)
        return "Closed $file"
    end

    # Auto-start the hub at extension init so the server is always up on its port
    # (browse the index, open notebooks over HTTP) — no longer gated on the first
    # `slate.open` MCP call. Reap any orphaned workers from a prior crashed instance
    # first, and register an atexit backstop so a normal process exit also reaps.
    # Guarded: a failure here must not break tool registration.
    try
        _reap_orphan_workers!()
        atexit(on_shutdown)
        _hub()
        @info "KaimonSlate hub auto-started" url = _base()
    catch e
        @warn "KaimonSlate hub auto-start failed" exception = (e, catch_backtrace())
    end

    return [
        GateTool("open", nb_open),
        GateTool("list", nb_list),
        GateTool("close", nb_close),
    ]
end

"""
    on_event(channel, data, session_name)

Gate event-bus callback (the extension manifest subscribes to the `agent:` topic
prefix). Kaimon's agent service publishes each agent session's `{kind,turn,data}`
events on `agent:<id>`; we relay them onto the bound notebook's SSE so the chat
pane updates live. Other channels are ignored.
"""
function on_event(channel, data, session_name)
    try
        startswith(String(channel), "agent:") &&
            NotebookServer.relay_agent_event(String(channel), data)
    catch e
        @warn "KaimonSlate on_event failed" channel exception = (e, catch_backtrace())
    end
    return nothing
end

"""
    on_shutdown()

Stop every running notebook server before the extension subprocess exits.
"""
function on_shutdown()
    lock(_LOCK) do
        _HUB[] === nothing || (try; stop_hub(_HUB[]); catch; end; _HUB[] = nothing)
    end
    @info "KaimonSlate shut down"
end

end # module
