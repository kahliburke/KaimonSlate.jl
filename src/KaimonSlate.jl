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
using .NotebookServer: serve_notebook, start_server, LiveNotebook

export serve_notebook, LiveNotebook

# ── Notebook server registry ──────────────────────────────────────────────────
# The extension manages several notebooks at once — one live server per file,
# each on its own port (answering "can it load more than one file?"). Servers run
# in the extension subprocess alongside the Gate loop.

const _BASE_PORT = 8765
const _SERVERS = Dict{String,@NamedTuple{server::Any, port::Int}}()
const _LOCK = ReentrantLock()

_url(port::Int) = "http://127.0.0.1:$port"

# Start (or return the existing) live server for `path`, returning its URL.
function _ensure_server(path::AbstractString)
    file = abspath(path)
    lock(_LOCK) do
        haskey(_SERVERS, file) && return _url(_SERVERS[file].port)
        # First free port at/above _BASE_PORT not already taken by us.
        taken = Set(s.port for s in values(_SERVERS))
        port = _BASE_PORT
        while port in taken
            port += 1
        end
        server = start_server(file; port = port)
        _SERVERS[file] = (server = server, port = port)
        return _url(port)
    end
end

function _stop_server(path::AbstractString)
    file = abspath(path)
    lock(_LOCK) do
        haskey(_SERVERS, file) || return false
        try
            close(_SERVERS[file].server)
        catch
        end
        delete!(_SERVERS, file)
        return true
    end
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
        isfile(path) || write(path, "#%% md id=intro\n# New Notebook\n")
        url = _ensure_server(path)
        return "Serving $(abspath(path)) at $url"
    end

    """
        list() -> String

    List the notebooks currently being served and their URLs.
    """
    function nb_list()::String
        lock(_LOCK) do
            isempty(_SERVERS) && return "No notebooks open."
            return join(("$(_url(s.port))  ←  $file" for (file, s) in _SERVERS), "\n")
        end
    end

    """
        close(path::String) -> String

    Stop the live server for the notebook at `path`.
    """
    function nb_close(path::String)::String
        return _stop_server(path) ? "Closed $(abspath(path))" : "Not open: $(abspath(path))"
    end

    return [
        GateTool("open", nb_open),
        GateTool("list", nb_list),
        GateTool("close", nb_close),
    ]
end

"""
    on_shutdown()

Stop every running notebook server before the extension subprocess exits.
"""
function on_shutdown()
    lock(_LOCK) do
        for (_, s) in _SERVERS
            try
                close(s.server)
            catch
            end
        end
        empty!(_SERVERS)
    end
    @info "KaimonSlate shut down"
end

end # module
