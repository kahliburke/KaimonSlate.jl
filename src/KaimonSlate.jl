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

import JSON

include("engine.jl")    # module ReportEngine (+ eval / deps / bind / echarts)
include("render.jl")    # module ReportRender
include("server.jl")    # module NotebookServer (uses ..ReportEngine, ..ReportRender)

using .ReportEngine
using .ReportRender
using .NotebookServer: serve_notebook, start_server, LiveNotebook,
                      Hub, start_hub, open_notebook!, close_notebook!, stop_hub,
                      find_live, notebook_digest,
                      agent_add_cell!, agent_edit_cell!, agent_run!, agent_delete_cell!, agent_rename_cell!,
                      acquire_floor!, release_floor!, floor_status,
                      index_docs!, search_docs, cell_image, cell_image_fresh, cell_inspect, diag_report,
                      request_live_eval, export_standalone, export_pdf, expand

export serve_notebook, LiveNotebook, expand, register_extension

# ── Auto-registration as a Kaimon extension ───────────────────────────────────
# The intended path is zero-setup: install KaimonSlate, and if Kaimon is present on
# this machine it registers itself in Kaimon's extension list — then the user just
# launches Kaimon and opens the browser. No hand-editing of config, no manual
# `serve_notebook`. Detection is simply "Kaimon's config dir exists".

const _KAIMON_DIR = joinpath(homedir(), ".config", "kaimon")

"""
    register_extension(; auto_start=true, enabled=true, project_path=pkgdir(KaimonSlate)) -> Bool

Add this package to Kaimon's extension registry (`~/.config/kaimon/extensions.json`) so Kaimon
loads the `slate.*` tools automatically — no hand-wiring. **Idempotent**: returns `false`
(nothing written) if Kaimon isn't installed here or the entry already exists, and `true` when an
entry is added. Runs automatically on load (see `__init__`); call it explicitly to (re)register a
specific `project_path` or to flip `auto_start`.
"""
function register_extension(; auto_start::Bool = true, enabled::Bool = true,
                            project_path = pkgdir(@__MODULE__))
    isdir(_KAIMON_DIR) || return false                       # Kaimon not installed on this machine
    project_path === nothing && return false                 # can't locate ourselves (unusual)
    path = abspath(String(project_path))
    file = joinpath(_KAIMON_DIR, "extensions.json")
    data = isfile(file) ? (try; JSON.parsefile(file); catch; Dict{String,Any}(); end) : Dict{String,Any}()
    exts = get(data, "extensions", nothing)
    exts isa AbstractVector || (exts = Any[])
    any(e -> e isa AbstractDict && get(e, "project_path", nothing) == path, exts) && return false  # already there
    push!(exts, Dict("project_path" => path, "enabled" => enabled, "auto_start" => auto_start))
    data["extensions"] = exts
    write(file, JSON.json(data, 2))
    @info "Registered KaimonSlate as a Kaimon extension — launch Kaimon and open the browser." file
    return true
end

# Auto-register on first load when Kaimon is present, so installing + loading the package once is
# all it takes. Best-effort and idempotent — never breaks loading; opt out with
# `ENV["KAIMONSLATE_NO_AUTOREGISTER"] = "1"`.
function __init__()
    get(ENV, "KAIMONSLATE_NO_AUTOREGISTER", "0") in ("1", "true") && return nothing
    try
        register_extension()
    catch e
        @debug "KaimonSlate auto-registration skipped" exception = (e, catch_backtrace())
    end
    return nothing
end

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
    # The invoking agent's identity (its MCP session id), or "" for a sessionless/self call.
    # Keys the build-floor implicitly, so the model never threads a token (and can't self-lock).
    _caller() = (c = parentmodule(GateTool).current_caller(); c === nothing ? "" : String(c))

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
        read(notebook::String; delta_since="") -> String

    Read the notebook's cells and their current outputs/errors — your view of the live state.
    `notebook` is its id or .jl path. Each read ends with a STATE TOKEN ("state=…"); pass it back as
    `delta_since` on a later read to get only the cells added/edited/removed since (instead of the
    whole notebook). An unknown/expired token falls back to a full read.
    """
    function read_cells(notebook::String; delta_since::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        return notebook_digest(nb; delta_since = delta_since)
    end

    """
        api() -> String

    The Kaimon Slate notebook API cheatsheet: the Slate-specific helpers injected into every
    cell — `echart` (custom ECharts DSL), `@bind` widgets, `reactive`/`@onclick`/`@onchange`
    for live updates, `slate_table`. READ THIS before writing cells that plot or add
    interactivity — these names are NOT in package docs, and a `search_docs` for "chart" or
    "series" returns CairoMakie, which will lead you astray.
    """
    api()::String = NotebookServer.slate_api_reference()   # single source of truth (also feeds the agent prompt)

    """
        add_cell(notebook, source, after, kind) -> String

    Append a cell containing `source`, RUN it, and return its result (value/output,
    or the error to fix). `after` = the id to insert after ("" = end of notebook).
    `kind` = "code" or "md". `id` = an optional explicit cell id (a meaningful label like
    "ground_state"); must be UNIQUE — errors if already in use — and is folded to header-safe
    characters (letters/digits/underscore). Omit it to auto-generate. Add ONE cell at a time and
    read its result before the next — do not compose the whole notebook up front.

    Cells run in a REACTIVE notebook with Slate helpers injected (charts via `echart`, widgets
    via `@bind`, live updates via `reactive`/`@onclick`, tables via `slate_table`) — call
    `slate.api` for the reference before plotting or adding interactivity; their names are not in
    package docs.
    """
    function add_cell(notebook::String, source::String; after::String = "", kind::String = "code", id::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        return agent_add_cell!(nb, source; after = after, kind = kind, id = id, caller = _caller())
    end

    """
        rename_cell(notebook, cell, newid) -> String

    Rename cell `cell`'s id (its label) to `newid`. Ids must be UNIQUE (errors if `newid` is
    already in use) and are folded to header-safe characters (letters/digits/underscore).
    Dependencies are preserved. Use to give cells meaningful ids (e.g. "ground_state", "viz_conv").
    """
    function rename_cell(notebook::String, cell::String, newid::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return agent_rename_cell!(nb, cell, newid; caller = _caller())
    end

    """
        edit_cell(notebook, cell, source, token, expected_version) -> String

    Replace cell `cell`'s source, run it, and return its result. Use to fix a cell
    that errored, or to revise one in place.
    """
    function edit_cell(notebook::String, cell::String, source::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return agent_edit_cell!(nb, cell, source; caller = _caller())
    end

    """
        run(notebook, cell, token, expected_version) -> String

    Run cell `cell` and return its result; `cell` = "" recomputes all stale cells.
    """
    function run_cell(notebook::String, cell::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return agent_run!(nb, cell; caller = _caller())
    end

    """
        delete_cell(notebook, cell, token, expected_version) -> String

    Delete cell `cell` from the notebook.
    """
    function delete_cell(notebook::String, cell::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return agent_delete_cell!(nb, cell; caller = _caller())
    end

    # ── Multi-agent write safety (MULTIAGENT.md §3) ───────────────────────────
    # Only needed when SEVERAL agents drive one notebook. A solo agent ignores all of
    # this — your edits already carry your session id implicitly, so they just work.

    """
        acquire_floor(notebook) -> String

    Claim the notebook's BUILD-FLOOR before a run of edits, so no other agent can
    commit underneath you ("one voice at a time"). No token to manage — every edit you
    make is recognized as yours automatically; just `release_floor` when done. The lease
    auto-expires after a few minutes idle. If another agent holds it, you get told who.
    """
    function acquire_floor(notebook::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        ok, why = acquire_floor!(nb, _caller())
        ok || return "⛔ build-floor $why. Try again shortly, or coordinate via the team."
        return "🔓 build-floor acquired — you hold it; other agents are locked out until slate.release_floor (auto-expires after $(Int(NotebookServer.FLOOR_TTL))s idle). Your edits carry your session automatically."
    end

    """
        release_floor(notebook) -> String

    Release the build-floor you hold so other agents can commit.
    """
    function release_floor(notebook::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return release_floor!(nb, _caller()) ? "✅ build-floor released." : "(you don't hold the build-floor — nothing to release)"
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
        n == 0 || NotebookServer.ensure_docs_fts!()   # light up lexical search + module filters for these
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
        nb, _ = _nb(notebook)   # scope to this notebook's packages when resolvable; unfiltered otherwise
        mods = nb === nothing ? String[] : NotebookServer._inscope_modules(nb)
        res = search_docs(query; modules = mods)
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
        png = cell_image_fresh(nb, cell)   # CairoMakie/ECharts raster, or a fresh on-demand capture (md/table/value)
        png === nothing && return "Cell '$cell' has no figure to view yet — run a plotting cell (CairoMakie or an ECharts chart); text/data → use slate.read."
        isdefined(Main, :Kaimon) || return "Image view needs the Kaimon host (unavailable in standalone mode)."
        return getfield(Main, :Kaimon).KaimonGate.image_result(png; text = "Cell '$cell' — rendered figure")
    end

    """
        inspect(notebook, cell) -> String

    Everything about one cell, for inspecting while you build: its state (kind/state/deps/
    reads/writes/duration/flags), source, the canonical result, and its edit history. Use it
    after add_cell/edit_cell/run to decide the next step. (Rendered figure → slate.view;
    whole notebook → slate.read.)
    """
    function inspect_cell(notebook::String, cell::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return cell_inspect(nb, cell)
    end

    """
        diag(notebook) -> String

    Browser diagnostics for an OPEN notebook tab: console errors, failed resource loads
    (e.g. 404s), and unhandled promise rejections captured by the live page. Push-based —
    reflects the most recent tab session, so open the notebook in a browser and reload to
    refresh. Use after a front-end change to verify the console is clean (no headless browser
    needed). Reports "✓ clean" when nothing was captured.
    """
    function notebook_diag(notebook::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        return diag_report(nb)
    end

    """
        eval_js(notebook, code) -> String

    Run `code` as JavaScript IN THE OPEN BROWSER TAB and return its result — the general way to
    drive or inspect the live notebook UI without a headless browser. Runs in the page's global
    scope, so page globals are reachable: invoke actions (`renderCharts(c)`, open a dialog, click a
    handler), read live state (`nbState`, a chart's resolved option `charts[id][0].getOption()`,
    DOM/computed styles), or trigger a reactive flow. The last expression is the return value; a
    returned Promise is awaited (so `await`-style snippets work). The value comes back JSON-encoded
    (functions / DOM nodes / cycles are collapsed, size-capped). Needs an OPEN tab — returns a notice
    if none answers in time. NOTE: this CANNOT capture a browser download (e.g. the PDF blob from
    `exportPdf()`); to inspect generated artifacts use the server-side tool (`slate.export_pdf`).
    """
    function eval_js(notebook::String, code::String)::String
        nb, err = _nb(notebook); nb === nothing && return err
        res = request_live_eval(nb, code)
        res === nothing && return "No open browser tab answered. Open/reload the notebook in a browser, then retry — eval_js runs in the live page."
        res isa AbstractDict || return string(res)
        get(res, "ok", false) === true && return String(get(res, "result", "null"))
        return "JS error: " * String(get(res, "error", "(unknown)"))
    end

    """
        export_pdf(notebook; theme="light", params="0", source="1", style="article",
                   columns="1", code="normal", body="", path="") -> String

    Render the notebook to a publication-quality PDF (the same server-side Typst pipeline as
    the browser's "Export PDF") and WRITE it to a file, so you can open that file with `Read`
    to verify the result — layout, figures, math, and whether interactive chrome or `@bind`
    parameter strips leaked in. This is how you check the PDF without a browser. Options mirror
    the export dialog: `theme ∈ ("light","dark")`; `params="1"` shows the frozen `@bind`
    parameter strip (hidden by default); `source="0"` drops code listings; `style ∈
    ("article","report")`; `columns ∈ ("1","2")`; `code ∈ ("normal","small","smaller","tiny",
    "hidden")`; `body ∈ ("","large","normal","compact","small")`. `path` overrides the output
    file (default: a temp path). Returns the written path — pass it to `Read` to see the pages.
    """
    function export_pdf_tool(notebook::String; theme::String = "light", params::String = "0",
                             source::String = "1", style::String = "article", columns::String = "1",
                             code::String = "normal", body::String = "", path::String = "")::String
        nb, err = _nb(notebook); nb === nothing && return err
        pdf = try
            export_pdf(nb; include_source = source != "0", style = style,
                       columns = something(tryparse(Int, columns), 1), theme = theme,
                       code = code, body = body, include_params = params == "1")
        catch e
            return "PDF export failed: " * sprint(showerror, e)
        end
        out = isempty(path) ? joinpath(tempdir(), "slate-export",
                  replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".pdf") : String(path)
        try
            mkpath(dirname(out)); write(out, pdf)
        catch e
            return "PDF rendered ($(length(pdf)) bytes) but writing to $out failed: " * sprint(showerror, e)
        end
        return "Wrote $(length(pdf)) bytes → $out\n(open it with Read to view the pages)"
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
        GateTool("api", api),
        GateTool("open", nb_open),
        GateTool("list", nb_list),
        GateTool("close", nb_close),
        GateTool("read", read_cells),
        GateTool("add_cell", add_cell),
        GateTool("edit_cell", edit_cell),
        GateTool("rename_cell", rename_cell),
        GateTool("run", run_cell),
        GateTool("delete_cell", delete_cell),
        GateTool("acquire_floor", acquire_floor),
        GateTool("release_floor", release_floor),
        GateTool("view", view_cell),
        GateTool("inspect", inspect_cell),
        GateTool("diag", notebook_diag),
        GateTool("eval_js", eval_js),
        GateTool("export_pdf", export_pdf_tool),
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
