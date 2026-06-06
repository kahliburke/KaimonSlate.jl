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
                      Hub, start_hub, open_notebook!, close_notebook!, stop_hub,
                      find_live, notebook_digest,
                      agent_add_cell!, agent_edit_cell!, agent_run!, agent_delete_cell!,
                      acquire_floor!, release_floor!, floor_status,
                      index_docs!, search_docs, cell_image

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

    # ── Cell-level operations (the incremental-build loop) ────────────────────
    # These let the agent operate the LIVE notebook one cell at a time — add a
    # cell, run it, read the result, decide the next — instead of composing the
    # whole thing blind and dumping one big file Edit. `notebook` is the id (e.g.
    # "para") or the .jl path. All args are flat scalars (gate-reflection friendly).
    function _nb(notebook::String)
        h = _HUB[]
        h === nothing && return (nothing, "No notebooks are open.")
        nb = find_live(h, notebook)
        nb === nothing && return (nothing, "No open notebook '$notebook' (use slate.list).")
        return (nb, "")
    end

    """
        read(notebook::String) -> String

    Read the notebook's cells and their current outputs/errors — your view of the
    live state. `notebook` is its id or .jl path. Call this first, and after changes.
    """
    function read_cells(notebook::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return notebook_digest(nb)
    end

    """
        add_cell(notebook, source, after, kind) -> String

    Append a cell containing `source`, RUN it, and return its result (value/output,
    or the error to fix). `after` = the id to insert after ("" = end of notebook).
    `kind` = "code" or "md". Add ONE cell at a time and read its result before the
    next — do not compose the whole notebook up front.
    """
    function add_cell(notebook::String, source::String; after::String = "", kind::String = "code",
                      token::String = "", expected_version::Int = -1)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return agent_add_cell!(nb, source; after = after, kind = kind,
                               token = token, expected_version = expected_version)
    end

    """
        edit_cell(notebook, cell, source, token, expected_version) -> String

    Replace cell `cell`'s source, run it, and return its result. Use to fix a cell
    that errored, or to revise one in place. `token`/`expected_version` are for
    multi-agent safety — see `add_cell` (omit when you're the only agent).
    """
    function edit_cell(notebook::String, cell::String, source::String;
                       token::String = "", expected_version::Int = -1)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return agent_edit_cell!(nb, cell, source; token = token, expected_version = expected_version)
    end

    """
        run(notebook, cell, token, expected_version) -> String

    Run cell `cell` and return its result; `cell` = "" recomputes all stale cells.
    """
    function run_cell(notebook::String, cell::String;
                      token::String = "", expected_version::Int = -1)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return agent_run!(nb, cell; token = token, expected_version = expected_version)
    end

    """
        delete_cell(notebook, cell, token, expected_version) -> String

    Delete cell `cell` from the notebook.
    """
    function delete_cell(notebook::String, cell::String;
                         token::String = "", expected_version::Int = -1)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return agent_delete_cell!(nb, cell; token = token, expected_version = expected_version)
    end

    # ── Multi-agent write safety (MULTIAGENT.md §3) ───────────────────────────
    # Only needed when SEVERAL agents drive one notebook. A solo agent ignores all of
    # this (omit `token`/`expected_version` and the ops behave exactly as before).

    """
        acquire_floor(notebook, holder) -> String

    Claim the notebook's BUILD-FLOOR before a run of edits, so no other agent can
    commit underneath you ("one voice at a time"). Returns a `token` — pass it to
    `add_cell`/`edit_cell`/`run`/`delete_cell` while you work, then `release_floor`.
    The lease auto-expires after a few minutes idle. If another agent holds it, you
    get told who — coordinate or retry.
    """
    function acquire_floor(notebook::String; holder::String = "agent")::String
        nb, err = _nb(notebook); nb === nothing && return err
        tok, why = acquire_floor!(nb, holder)
        tok === nothing && return "⛔ build-floor $why. Try again shortly, or coordinate via the team."
        return "🔓 build-floor acquired by '$holder' — token=$tok. Pass it as `token` to every edit, then slate.release_floor. Auto-expires after $(Int(NotebookServer.FLOOR_TTL))s idle."
    end

    """
        release_floor(notebook, token) -> String

    Release the build-floor you hold (by its `token`) so other agents can commit.
    """
    function release_floor(notebook::String, token::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return release_floor!(nb, token) ? "✅ build-floor released." : "(you don't hold the build-floor — nothing to release)"
    end

    """
        index_docs(notebook, modules) -> String

    Index the documentation of `using`'d packages/modules (comma- or space-separated
    names) into semantic search so `search_docs` can find them. The modules must be
    loaded in the notebook first (a cell with `using Foo`).
    """
    function index_docs(notebook::String, modules::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        mods = String[strip(m) for m in split(modules, r"[,\s]+") if !isempty(strip(m))]
        isempty(mods) && return "Name the packages/modules to index (comma-separated); they must be `using`'d in the notebook."
        recs = ReportEngine.harvest_docs(nb.kernel, nb.report, mods)
        n = index_docs!(recs)
        return n == 0 ?
            "Indexed nothing — are the modules loaded (run `using …`) and the docs service (Ollama/Qdrant) up?" :
            "Indexed $n documented symbols from $(join(mods, ", ")). Search them with slate.search_docs."
    end

    """
        search_docs(notebook, query) -> String

    Fuzzy SEMANTIC search of indexed docs ("a function that sorts in place") — discover
    Julia/package API by meaning instead of reading source (you have no file access).
    Build the index first with `index_docs`.
    """
    function search_docs_tool(notebook::String, query::String)::String
        res = search_docs(query)
        isempty(res) && return "No matches — build the index first with slate.index_docs, or rephrase."
        io = IOBuffer()
        for r in res
            println(io, "● $(r["module"]).$(r["name"])  (", round(Float64(get(r, "score", 0.0)); digits = 3), ")")
            snip = join(first(split(rstrip(string(r["doc"])), "\n"), 4), "\n")
            isempty(strip(snip)) || println(io, snip)
            println(io)
        end
        return String(take!(io))
    end

    """
        view(notebook, cell) -> image

    SEE a cell's rendered figure — returns the cell's PNG as an image you can look at
    (e.g. a CairoMakie plot), so you can inspect/verify/fix a visualization. Use this
    after running a plotting cell. ECharts/tables are interactive (not raster) — read
    those with `read`; text output also comes back via `read`.
    """
    function view_cell(notebook::String, cell::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        findfirst(c -> c.id == cell, nb.report.cells) === nothing &&
            return "No cell '$cell' in '$notebook' (use slate.read to list cells)."
        png = cell_image(nb, cell)   # CairoMakie raster OR client-captured ECharts snapshot
        png === nothing && return "Cell '$cell' has no figure to view yet — run a plotting cell (CairoMakie or an ECharts chart); text/data → use slate.read."
        isdefined(Main, :Kaimon) || return "Image view needs the Kaimon host (unavailable in standalone mode)."
        return getfield(Main, :Kaimon).KaimonGate.image_result(png; text = "Cell '$cell' — rendered figure")
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
        GateTool("read", read_cells),
        GateTool("add_cell", add_cell),
        GateTool("edit_cell", edit_cell),
        GateTool("run", run_cell),
        GateTool("delete_cell", delete_cell),
        GateTool("acquire_floor", acquire_floor),
        GateTool("release_floor", release_floor),
        GateTool("view", view_cell),
        GateTool("index_docs", index_docs),
        GateTool("search_docs", search_docs_tool),
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
