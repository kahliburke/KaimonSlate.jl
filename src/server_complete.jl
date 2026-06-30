# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Cell-local completion ─────────────────────────────────────────────────────
# `REPLCompletions` only sees the live module, so identifiers a cell BINDS before
# it has run (assignments, `for`/`let`/`function`/generator vars, params) don't
# complete. We parse the cell's complete leading statements and union their bound
# names in — an over-approximation (ignores nested-scope visibility), which is fine
# for completion. Only for bare identifiers; field access (after `.`) is left to
# REPLCompletions.
_isidcu(b::UInt8) = (UInt8('a') <= b <= UInt8('z')) || (UInt8('A') <= b <= UInt8('Z')) ||
                    (UInt8('0') <= b <= UInt8('9')) || b == UInt8('_') || b == UInt8('!')

# (token-start-0based, typed-prefix, is-field-access) for the identifier at `pos`.
function _id_prefix(code::String, pos::Int)
    cu = codeunits(code)
    i = pos
    while i > 0 && _isidcu(cu[i]); i -= 1; end
    dotted = i >= 1 && cu[i] == UInt8('.')
    return (i, String(cu[(i + 1):pos]), dotted)
end

# Stable re-rank for the popup: cell-local bindings float to the top and keywords sink,
# while names of the same kind keep REPLCompletions' (alphabetical) order. `prefix` is the
# typed token — an exact match (you've already typed the whole name) drops to the bottom.
const _KIND_RANK = Dict("local" => 0, "field" => 1, "kwarg" => 1, "var" => 2, "function" => 2,
                        "type" => 2, "const" => 2, "module" => 2, "method" => 2, "key" => 2,
                        "path" => 2, "text" => 3, "latex" => 3, "keyword" => 4)
function _rank_completions(items::Vector{Tuple{String,String}}, prefix::AbstractString)
    length(items) <= 1 && return items
    order = collect(enumerate(items))
    sort!(order; by = p -> (p[2][1] == prefix ? 1 : 0, get(_KIND_RANK, p[2][2], 3), p[1]))
    return [it for (_, it) in order]
end

# Names introduced at a binding site (LHS of `=`, params, `f(a,b)` def, `x::T`, …).
function _bind_names!(out::Set{Symbol}, x)
    if x isa Symbol
        x === :_ || push!(out, x)
    elseif x isa Expr
        h = x.head
        if h === :(::) || h === :(<:) || h === :kw || h === :(=) || h === :(...) || h === :curly
            isempty(x.args) || _bind_names!(out, x.args[1])
        elseif h === :tuple || h === :parameters || h === :call   # destructuring / def LHS+params
            for a in x.args
                _bind_names!(out, a)
            end
        end
    end
end

function _collect_binds!(out::Set{Symbol}, ex)
    ex isa Expr || return
    h = ex.head
    if h === :(=)
        _bind_names!(out, ex.args[1]); _collect_binds!(out, ex.args[2])
    elseif h === :function || h === :(->)
        _bind_names!(out, ex.args[1])
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :for
        spec = ex.args[1]
        for b in (spec isa Expr && spec.head === :block ? spec.args : (spec,))
            b isa Expr && b.head === :(=) && _bind_names!(out, b.args[1])
        end
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :generator || h === :comprehension || h === :flatten
        for a in ex.args
            (a isa Expr && a.head === :(=)) ? _bind_names!(out, a.args[1]) : _collect_binds!(out, a)
        end
    elseif h === :let
        binds = ex.args[1]
        for b in (binds isa Expr && binds.head === :block ? binds.args : (binds,))
            b isa Symbol ? push!(out, b) : (b isa Expr && b.head === :(=) && _bind_names!(out, b.args[1]))
        end
        for i in 2:length(ex.args); _collect_binds!(out, ex.args[i]); end
    elseif h === :local || h === :global
        for a in ex.args; _bind_names!(out, a); end
    else
        for a in ex.args; _collect_binds!(out, a); end
    end
end

# All names bound by the cell's complete leading statements (stops at the first
# incomplete/erroring statement — typically the line being typed).
function _cell_locals(code::AbstractString)
    out = Set{Symbol}()
    s = String(code); n = ncodeunits(s); idx = 1
    while idx <= n
        ex, nxt = try
            Meta.parse(s, idx; raise = false)
        catch
            break
        end
        ex === nothing && break
        (ex isa Expr && (ex.head === :incomplete || ex.head === :error)) && break
        _collect_binds!(out, ex)
        nxt <= idx && break
        idx = nxt
    end
    return out
end

# Restart a notebook's kernel: kill its worker (a gate worker is a real subprocess;
# no-op in-process), then re-evaluate from a fresh namespace. The gate kernel
# respawns a worker on the next `prepare!`.
# Graceful stop: interrupt the worker's running cells WITHOUT killing the namespace. Only meaningful
# for a gate worker with cells in flight; the interrupted cells stream back as errors (via celldone)
# and the namespace + every already-finished result survives. Falls back to a full worker restart when
# there's nothing to gracefully interrupt (in-process kernel, no live worker, or no running cells) —
# matching the old stop-button behaviour. Returns the notebook.
function cancel_run!(nb::LiveNotebook)
    k = nb.kernel
    _PARALLEL_CANCEL[nb.id] = true            # stop the parallel scheduler from starting not-yet-run cells
    hasrunning = lock(nb.lock) do; any(c -> c.state == RUNNING, nb.report.cells); end
    if k isa ReportEngine.GateKernel && hasrunning
        n = ReportEngine.cancel_eval(k)
        if n >= 0
            @info "slate: run cancelled (namespace preserved)" notebook = nb.id interrupted = n
            try; _broadcast(nb, "cancelled:$n"); catch; end
            return nb
        end
    end
    return restart_kernel!(nb)
end

function restart_kernel!(nb::LiveNotebook)
    # Tear down + reset synchronously (fast), mark a background re-run underway, and RETURN — the
    # full re-eval (which respawns the worker on prepare! and streams cells back) runs async, so the
    # user gets control back immediately instead of blocking until everything re-renders. Same
    # "open instantly" pattern as load_notebook.
    lock(nb.lock) do
        try; ReportEngine.shutdown!(nb.kernel); catch; end
        ReportEngine.reset!(nb.kernel, nb.report)
        build_dependencies!(nb.report)
        nb.report.meta["hydrating"] = true
        nb.version += 1
    end
    _broadcast(nb, "restart")
    @async begin
        try
            lock(nb.lock) do
                _eval!(nb)         # respawns the worker, streams cellrun/celldone
                delete!(nb.report.meta, "hydrating")
                nb.version += 1
            end
        catch e
            lock(nb.lock) do
                nb.report.meta["hydrate_error"] = sprint(showerror, e)
                delete!(nb.report.meta, "hydrating")
                nb.version += 1
            end
            @warn "KaimonSlate: worker-restart re-run failed" exception = (e, catch_backtrace())
        end
        try; _broadcast(nb, string(nb.version)); catch; end   # nudge the browser to pull the now-live cells
    end
    return nb
end

# The gate worker's stdout/stderr log (eval output, prints, errors, package loads)
# — the debugging surface for "what is the worker doing". In-process kernels have
# no separate log (cells eval in the extension process).
function worker_log(nb::LiveNotebook; maxbytes::Int = 100_000)
    if nb.kernel isa GateKernel                          # real subprocess → tail its raw log
        path = nb.kernel.logpath
        (isempty(path) || !isfile(path)) && return "(worker not started yet)"
        s = read(path, String)
        return ncodeunits(s) > maxbytes ? "…(truncated; last $(maxbytes ÷ 1000)KB)…\n" * String(last(s, maxbytes)) : s
    end
    # In-process kernel: no separate log file, so synthesize an eval console from the
    # cells' captured output (state · duration · stdout · error).
    io = IOBuffer()
    println(io, "# in-process kernel — this notebook isn't in a Julia project, so cells eval in")
    println(io, "# the extension. Open it inside a project dir for a separate gate worker + raw log.\n")
    ran = false
    for c in nb.report.cells
        c.kind == CODE || continue
        o = c.output; o === nothing && continue
        ran = true
        println(io, "[$(c.id)]  $(lowercase(string(c.state)))  ·  $(round(o.duration_ms; digits = 1))ms")
        st = rstrip(o.stdout)
        isempty(st) || println(io, "  " * replace(st, "\n" => "\n  "))
        o.exception === nothing || println(io, "  ERROR: " * replace(o.exception, "\n" => "\n  "))
        println(io)
    end
    ran || println(io, "(no code cells have run yet)")
    return String(take!(io))
end

# Locally-served models for the Settings dropdown, via an Ollama-compatible `/api/tags`.
# Both Ollama and vmlx (the MLX inference server for Apple Silicon) speak this protocol —
# Kaimon's OllamaBackend drives either, routed by an `ollama:` / `vmlx:` model prefix.
# Proxied through the server so the browser dodges cross-origin issues; best-effort —
# returns [] if that server isn't running.
function _tags_models(host::AbstractString)
    startswith(host, "http") || (host = "http://" * host)
    try
        r = HTTP.get(rstrip(host, '/') * "/api/tags"; connect_timeout = 2, request_timeout = 4, retry = false)
        d = JSON.parse(String(r.body))
        names = String[String(get(m, "name", "")) for m in get(d, "models", Any[])]
        # Drop embedding-only models — they can't run /api/chat, so they're useless as agents.
        return filter(n -> !isempty(n) && !occursin(r"embed"i, n), names)
    catch
        return String[]
    end
end
_ollama_models() = _tags_models(get(ENV, "OLLAMA_HOST", "http://127.0.0.1:11434"))
_vmlx_models()   = _tags_models(get(ENV, "VMLX_HOST", "http://127.0.0.1:8000"))

include("export_typst.jl")   # export_pdf(nb) — publication-quality PDF via Typst (uses types defined above)
include("export_bundle.jl")  # export_standalone(nb) / expand(jl) — self-contained single-source .jl

function _make_router(h::Hub)
    router = HTTP.Router()
    HTTP.register!(router, "GET", "/", _ -> _html(read(_INDEX_ASSET, String)))   # static asset; sessions render client-side from /api/notebooks
    HTTP.register!(router, "GET", "/assets/notebook.css", _ -> _asset(read(_CSS_ASSET, String), "text/css; charset=utf-8"))
    # Vendored third-party assets (offline cache, pinned in vendor.json). Greedy `**` so
    # nested paths work (CodeMirror modes/addons, KaTeX fonts). First hit fetches+caches.
    HTTP.register!(router, "GET", "/assets/vendor/**", req -> begin
        rel = replace(HTTP.URI(req.target).path, r"^/assets/vendor/" => "")
        parts = split(rel, '/'; limit = 2)
        (length(parts) == 2 && !isempty(parts[2])) || return HTTP.Response(404)
        f = _vendor_file(String(parts[1]), String(parts[2]))
        f === nothing && return HTTP.Response(404, "vendor asset unavailable (offline & uncached?)")
        HTTP.Response(200, ["Content-Type" => _vendor_ctype(parts[2]),
                            "Cache-Control" => "public, max-age=31536000, immutable"], read(f))
    end)
    HTTP.register!(router, "GET", "/assets/js/{file}", req -> begin
        f = HTTP.getparam(req, "file")
        # path-safety: a bare `name.js` only — no separators, no traversal.
        (occursin('/', f) || occursin('\\', f) || occursin("..", f) || !endswith(f, ".js")) && return HTTP.Response(404)
        p = joinpath(_JS_DIR, f)
        isfile(p) ? _asset(read(p, String), "application/javascript; charset=utf-8") : HTTP.Response(404)
    end)
    HTTP.register!(router, "GET", "/api/notebooks", _ -> _json(_notebooks_json(h)))
    # Open/close a notebook by path over HTTP — lets the index page (and any
    # caller) bring up a notebook without the `slate.*` MCP tools. Mirrors
    # `KaimonSlate.create_tools`'s open: creates the file if it doesn't exist.
    HTTP.register!(router, "POST", "/api/open", req -> begin
        path = expanduser(strip(String(get(_body(req), "path", ""))))   # resolve ~ (tab-complete emits ~ paths)
        isempty(path) && return HTTP.Response(400, "missing path")
        isfile(path) || write(path, "#%% md id=intro\n# New Notebook\n")
        id = open_notebook!(h, path)
        _json(Dict("id" => id, "url" => "/n/$id", "path" => abspath(path)))
    end)
    HTTP.register!(router, "POST", "/api/close", req -> begin
        file = abspath(expanduser(strip(String(get(_body(req), "path", "")))))
        id = lock(h.lock) do
            for nb in values(h.notebooks)
                abspath(nb.path) == file && return nb.id
            end
            return nothing
        end
        id === nothing ? HTTP.Response(404, "not open") : (close_notebook!(h, id); _json(Dict("closed" => file)))
    end)
    HTTP.register!(router, "GET", "/api/path-complete", req -> begin
        q = get(HTTP.queryparams(HTTP.URI(req.target)), "q", "")
        r = _path_completions(q)
        _json(Dict("completions" => r.items, "truncated" => r.truncated))
    end)
    # Stat a path (with ~ expansion) so the open box can decide: open file / show
    # subpaths for a directory / confirm-create for a new path.
    HTTP.register!(router, "GET", "/api/path-info", req -> begin
        p = expanduser(strip(String(get(HTTP.queryparams(HTTP.URI(req.target)), "q", ""))))
        # `standalone`: a self-contained `.jl` (Slate.bundle footer) → the open box offers the
        # import-into-a-project helper instead of opening it bare.
        _json(Dict("path" => p, "exists" => ispath(p), "isdir" => isdir(p), "isfile" => isfile(p),
                   "standalone" => isfile(p) && _has_bundle_footer(p)))
    end)
    # Close a notebook by id (the index's per-session shutdown button).
    HTTP.register!(router, "POST", "/api/{id}/shutdown", req -> begin
        id = HTTP.getparam(req, "id")
        close_notebook!(h, id) ? _json(Dict("closed" => id)) : HTTP.Response(404, "no such notebook")
    end)
    HTTP.register!(router, "GET", "/n/{id}", req -> begin
        id = HTTP.getparam(req, "id")
        present = lock(h.lock) do; haskey(h.notebooks, id); end
        present ? _html(read(_ASSET, String)) : HTTP.Response(302, ["Location" => "/"])   # not open → home
    end)
    HTTP.register!(router, "GET", "/api/{id}/state", req -> _withnb(h, req, nb -> (sync_from_file!(nb); _json(state_json(nb)))))
    # Content-addressed output image (see server_history.jl `_externalize_blobs`): immutable, so the
    # browser caches it forever — a reload re-uses the cached image instead of re-downloading it.
    HTTP.register!(router, "GET", "/api/{id}/blob/{hash}", req -> begin
        # memory tier (plot rasters) → durable disk tier (animation stacks); the latter may be gzip'd.
        b = blob_lookup(string(HTTP.getparam(req, "id"), "/", HTTP.getparam(req, "hash")))
        b === nothing && return HTTP.Response(404, "no such blob")
        hdrs = ["Content-Type" => b[1], "Cache-Control" => "public, max-age=31536000, immutable"]
        isempty(b[3]) || push!(hdrs, "Content-Encoding" => b[3])
        HTTP.Response(200, hdrs, b[2])
    end)
    # Full result for a truncated output — only serves temp files WE registered (no path traversal).
    HTTP.register!(router, "GET", "/api/{id}/output/{name}", req -> begin
        path = outfile_get(string(HTTP.getparam(req, "id"), "/", HTTP.getparam(req, "name")))
        (path === nothing || !isfile(path)) && return HTTP.Response(404, "no such output")
        mime = endswith(path, ".html") ? "text/html; charset=utf-8" : "text/plain; charset=utf-8"
        HTTP.Response(200, ["Content-Type" => mime, "Cache-Control" => "public, max-age=31536000, immutable"], read(path))
    end)
    HTTP.register!(router, "POST", "/api/{id}/cell/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        edit_cell!(nb, HTTP.getparam(req, "cid"), get(b, "source", ""); force = get(b, "force", false) === true)
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/complete", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        code = String(get(body, "code", ""))
        # `Int(...)` throws InexactError on a JSON float (`pos: 3.5`); round + tryparse defensively.
        n = ncodeunits(code)
        pos = clamp(round(Int, something(tryparse(Float64, string(get(body, "pos", n))), Float64(n))), 0, n)
        pstart, prefix, dotted = _id_prefix(code, pos)
        # Completion resolves WHERE the cells eval (the worker, for a gate kernel), so
        # `using`'d packages and evaluated bindings complete — not just server-side globals.
        items, from, to = (Tuple{String,String}[], pstart, pos)
        try
            r = ReportEngine.complete(nb.kernel, nb.report, code, pos)
            items = Tuple{String,String}[(String(t), String(k)) for (t, k) in r.items]
            from = Int(r.from); to = Int(r.to)
        catch
        end
        if !dotted                          # union in cell-local bindings (skip field access)
            have = Set(first.(items))
            locals = try; _cell_locals(code); catch; Set{Symbol}(); end
            extra = sort!(String[n for n in (String(s) for s in locals) if startswith(n, prefix) && !(n in have)])
            isempty(extra) || (items = vcat(Tuple{String,String}[(n, "local") for n in extra], items))
        end
        items = _rank_completions(items, prefix)
        # `@bind` vars expand to consts, so the completer tags them "const" — relabel them "bind"
        # for a clearer icon (a control, not a constant).
        bindnames = Set(String(b.name) for c in nb.report.cells for b in c.binds)
        isempty(bindnames) || (items = Tuple{String,String}[(t, t in bindnames ? "bind" : k) for (t, k) in items])
        # latex/emoji: a partial query returns the NAME (`\alpha`); attach the resolved symbol as
        # `apply` so the UI shows the name (filterable) but inserts the character in one step.
        comps = map(items) do (t, k)
            d = Dict{String,Any}("text" => t, "kind" => k)
            if k == "latex" && startswith(t, "\\")
                sym = ReportEngine.latex_symbol(t)
                isempty(sym) || (d["apply"] = sym)
            end
            d
        end
        _json(Dict("completions" => comps, "from" => from, "to" => to))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-add", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        add_cell!(nb, get(b, "after", ""), get(b, "kind", "code"); before = get(b, "before", false) === true)
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-rename/{cid}", req -> _withnb(h, req, nb -> begin
        ok, msg = rename_cell!(nb, HTTP.getparam(req, "cid"), get(_body(req), "newid", ""))
        ok ? _json(state_json(nb)) : HTTP.Response(400, msg)
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-split/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req); split_cell!(nb, HTTP.getparam(req, "cid"), get(b, "before", ""), get(b, "after", "")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-merge/{cid}", req -> _withnb(h, req, nb -> begin
        merge_cell!(nb, HTTP.getparam(req, "cid"), get(_body(req), "source", "")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-delete/{cid}", req -> _withnb(h, req, nb ->
        (delete_cell!(nb, HTTP.getparam(req, "cid")); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/cells-delete", req -> _withnb(h, req, nb -> begin
        b = _body(req); delete_cells!(nb, get(b, "ids", String[]); verb = get(b, "verb", "delete")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cells-paste", req -> _withnb(h, req, nb -> begin
        b = _body(req); paste_cells!(nb, get(b, "after", ""), get(b, "cells", Any[])); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-move/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req); cid = HTTP.getparam(req, "cid")
        haskey(b, "target") ? move_cell_rel!(nb, cid, b["target"], get(b, "before", true) === true) :
                              move_cell!(nb, cid, get(b, "dir", "up"))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-type/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        set_kind!(nb, HTTP.getparam(req, "cid"), get(b, "kind", "code"); source = get(b, "source", nothing)); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/controls", req -> _withnb(h, req, nb -> begin
        set_controls_map!(nb, get(_body(req), "map", Dict{String,Any}())); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/collapse/{cid}", req -> _withnb(h, req, nb -> begin
        set_collapsed!(nb, HTTP.getparam(req, "cid"), get(_body(req), "collapsed", true) === true); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/hidecode/{cid}", req -> _withnb(h, req, nb -> begin
        set_code_hidden!(nb, HTTP.getparam(req, "cid"), get(_body(req), "hidden", true) === true); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/trace/{cid}", req -> _withnb(h, req, nb -> begin
        # Toggle the flag (marks the cell STALE) then re-run stale cells, so the trace table
        # appears / disappears in one round-trip — no client-side source resend.
        set_trace!(nb, HTTP.getparam(req, "cid"), get(_body(req), "trace", true) === true)
        _eval!(nb)
        _json(state_json(nb))
    end))
    # Set a cell's full tag set from the tag editor (known behaviour tags + free-form). Re-runs stale
    # cells so a `trace` toggle takes effect in one round-trip.
    HTTP.register!(router, "POST", "/api/{id}/tags/{cid}", req -> _withnb(h, req, nb -> begin
        tags = get(_body(req), "tags", String[])
        set_cell_tags!(nb, HTTP.getparam(req, "cid"), tags isa AbstractVector ? tags : String[])
        _eval!(nb)
        _json(state_json(nb))
    end))
    # Static export: a self-contained HTML document of the notebook (also the print →
    # PDF path — the browser's print dialog saves it as PDF). `?dl=1` downloads; `?source=0`
    # hides code. No scripts/server needed; KaTeX (CDN) typesets math, figures are embedded.
    HTTP.register!(router, "GET", "/api/{id}/export.html", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        html = export_html(nb; include_source = get(qp, "source", "1") != "0")
        headers = Pair{String,String}["Content-Type" => "text/html; charset=utf-8"]
        if get(qp, "dl", "0") == "1"
            fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".html"
            push!(headers, "Content-Disposition" => "attachment; filename=\"$fn\"")
        end
        HTTP.Response(200, headers, html)
    end))
    # Publication-quality PDF via Typst (server-side). `?source=0` hides code listings;
    # `?params=1` shows the @bind parameter strip (hidden by default — a PDF is a snapshot).
    HTTP.register!(router, "GET", "/api/{id}/export.pdf", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        pdf = try
            export_pdf(nb; include_source = get(qp, "source", "1") != "0",
                       style = get(qp, "style", "article"),
                       columns = something(tryparse(Int, get(qp, "columns", "1")), 1),
                       theme = get(qp, "theme", "light"),
                       code = get(qp, "code", "normal"),
                       body = get(qp, "body", ""),
                       include_params = get(qp, "params", "0") == "1")
        catch e
            return HTTP.Response(500, "PDF export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".pdf"
        HTTP.Response(200, ["Content-Type" => "application/pdf",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], pdf)
    end))
    # The editable Typst PROJECT (doc.typ + assets) as a .tar.gz, so the layout can be tweaked and
    # recompiled (`typst compile doc.typ`). Same options as export.pdf.
    HTTP.register!(router, "GET", "/api/{id}/export.typ", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        data = try
            export_typst_bundle(nb; include_source = get(qp, "source", "1") != "0",
                       style = get(qp, "style", "article"),
                       columns = something(tryparse(Int, get(qp, "columns", "1")), 1),
                       theme = get(qp, "theme", "light"),
                       code = get(qp, "code", "normal"),
                       body = get(qp, "body", ""),
                       include_params = get(qp, "params", "0") == "1")
        catch e
            return HTTP.Response(500, "Typst export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".typ.tar.gz"
        HTTP.Response(200, ["Content-Type" => "application/gzip",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], data)
    end))
    # Self-contained single-source .jl: cells + full Project/Manifest + local source (+ a
    # shallow git bundle when the project is a repo). Reinflate with `KaimonSlate.expand`.
    HTTP.register!(router, "GET", "/api/{id}/export.standalone.jl", req -> _withnb(h, req, nb -> begin
        jl = try
            export_standalone(nb)
        catch e
            return HTTP.Response(500, "Standalone export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".standalone.jl"
        HTTP.Response(200, ["Content-Type" => "text/x-julia; charset=utf-8",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], jl)
    end))
    # ── Notebook packages ─────────────────────────────────────────────────────
    # Show the environment with provenance: `notebook` deps (the notebook's own forked env,
    # where adds land — removable) and `parent` deps (inherited from the enclosing project,
    # which the forked env extends — read-only). `detached` is true when there's no parent
    # (the notebook env IS everything). `manageable` is false for an in-process kernel.
    # Package-name completion for the Add box (matches reachable registries).
    HTTP.register!(router, "GET", "/api/{id}/pkg-complete", req -> _withnb(h, req, _ -> begin
        q = get(HTTP.queryparams(HTTP.URI(req.target)), "q", "")
        _json(Dict("names" => _pkg_complete(String(q))))
    end))
    HTTP.register!(router, "GET", "/api/{id}/packages", req -> _withnb(h, req, nb -> begin
        e = _notebook_adds(nb)
        _json(Dict("notebook" => e.adds,
                   "parent" => e.parent,
                   "parentPath" => e.parentpath,
                   "detached" => e.detached,
                   "manageable" => !(nb.kernel isa InProcessKernel)))
    end))
    HTTP.register!(router, "POST", "/api/{id}/package", req -> _withnb(h, req, nb -> begin
        b = _body(req); op = String(get(b, "op", "")); name = String(get(b, "name", ""))
        (op in ("add", "rm")) || return _json(Dict("ok" => false, "message" => "bad op '$op'"))
        res = lock(nb.lock) do
            r = ReportEngine.pkg_op(nb.kernel, nb.report, op, name)
            if get(r, "ok", false) === true              # env changed → re-run so `using` cells pick it up
                for c in nb.report.cells; c.kind == CODE && (c.state = STALE); end
                _eval!(nb)
                _refresh_env_meta!(nb)                   # update the .jl reproducibility footer
            end
            r
        end
        get(res, "ok", false) === true && (_autoindex!(nb); _agent_push!(nb))
        _json(res)
    end))
    # The worker's stdout/stderr log — what the kernel is doing when evaluating cells.
    HTTP.register!(router, "GET", "/api/{id}/worker-log", req -> _withnb(h, req, nb ->
        _json(Dict("log" => worker_log(nb), "worker" => _kernel_status(nb.kernel)))))
    HTTP.register!(router, "POST", "/api/{id}/bind/{cid}", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        set_bind!(nb, HTTP.getparam(req, "cid"), get(body, "name", ""), get(body, "value", nothing))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/table-page", req -> _withnb(h, req, nb -> begin
        b = _body(req)
        res = lock(nb.lock) do                       # serialize vs eval (shared gate connection)
            ReportEngine.table_page(nb.kernel, nb.report, String(get(b, "table_id", "")), b)
        end
        _json(Dict("rows" => res.rows, "total" => res.total))
    end))
    HTTP.register!(router, "POST", "/api/{id}/undo", req -> _withnb(h, req, nb -> begin
        lbl = undo!(nb); j = state_json(nb); j["undid"] = lbl; _json(j)
    end))
    HTTP.register!(router, "POST", "/api/{id}/redo", req -> _withnb(h, req, nb -> begin
        lbl = redo!(nb); j = state_json(nb); j["redid"] = lbl; _json(j)
    end))
    HTTP.register!(router, "POST", "/api/{id}/run", req -> _withnb(h, req, nb -> (_eval!(nb); _json(state_json(nb)))))
    # Re-run the WHOLE notebook (every cell in order, keeping the namespace) — the "safe"
    # option after a /src hot-reload when our guess at affected cells may be incomplete.
    HTTP.register!(router, "POST", "/api/{id}/rerun-all", req -> _withnb(h, req, nb -> begin
        lock(nb.lock) do
            for c in nb.report.cells; c.state = STALE; end
            _eval!(nb)
        end
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/restart", req -> _withnb(h, req, nb -> (restart_kernel!(nb); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/cancel", req -> _withnb(h, req, nb -> (cancel_run!(nb); _json(state_json(nb)))))
    # Agent chat: forward the turn to Kaimon's agent service (spawning a session
    # bound to this notebook on first use); the agent's `{kind,turn,data}` events
    # arrive async on the gate bus and are relayed to this notebook's SSE by
    # `relay_agent_event` (wired via KaimonSlate.on_event). See AGENT_SESSION_*.md.
    HTTP.register!(router, "POST", "/api/{id}/chat", req -> _withnb(h, req, nb -> begin
        text = String(get(_body(req), "text", ""))
        isempty(strip(text)) && return _json(Dict("ok" => false, "error" => "empty message"))
        _agent_available() ||
            return _json(Dict("ok" => false, "error" => "agent service unavailable (run inside Kaimon, with a logged-in `claude` CLI)"))
        tgt = String(get(_body(req), "target", ""))   # per-cell ✨: scope the turn to a cell + its dep cone
        crew = String(get(_body(req), "crew", ""))     # crew label → route to that crew member's agent ("" = solo)
        model = String(get(_body(req), "model", ""))   # agent model ("" = service default = sonnet); binds at spawn
        perm = String(get(_body(req), "permission", "")) # permission preset (lab/auto/default/bypass); binds at spawn
        ment = _mention_context(nb, text)              # @id cell references → inline those cells' context
        isempty(ment) || (text = ment * "\n\n" * text)
        isempty(tgt) || (text = _cell_context(nb, tgt) * "\n\nUSER REQUEST:\n" * text)
        let d = get(_body(req), "dark", nothing)       # browser's UI theme → plot-theme hint in the system prompt
            d === nothing || (nb.report.meta["ui_dark"] = d === true)
        end
        try
            aid = _ensure_agent!(nb; crew = crew, model = model, permission = perm)
            res = _agent_call(:agent_send, Dict{String,Any}("agent_id" => aid, "text" => text))
            _json(Dict("ok" => true, "agent_id" => aid, "crew" => crew, "turn" => get(res, "turn", nothing)))
        catch e
            _json(Dict("ok" => false, "error" => sprint(showerror, e)))
        end
    end))
    # Replay the conversation after a page reload (buffered as relayed, crew-tagged,
    # in arrival order across ALL crew agents on this notebook).
    HTTP.register!(router, "GET", "/api/{id}/agent-log", req -> _withnb(h, req, nb -> begin
        log = lock(_AGENT_LOCK) do; copy(get(_AGENT_LOG, nb.id, String[])); end
        _json(Dict("events" => log, "agents" => copy(nb.agents)))
    end))
    # Interrupt EVERY crew agent's in-flight turn (best effort, graceful).
    HTTP.register!(router, "POST", "/api/{id}/chat-interrupt", req -> _withnb(h, req, nb -> begin
        (_agent_available() && !isempty(nb.agents)) || return _json(Dict("ok" => false))
        any_int = false
        for aid in collect(values(nb.agents))
            r = try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => aid)); catch; Dict("interrupted" => false); end
            get(r, "interrupted", false) === true && (any_int = true)
        end
        _json(Dict("ok" => true, "interrupted" => any_int))
    end))
    # Hard stop: interrupt AND close (terminate) every crew agent — for a wedged agent
    # that `agent_interrupt` alone can't stop (it only cancels an in-flight LLM turn).
    # Reaps the whole crew so the next chat message spawns fresh.
    HTTP.register!(router, "POST", "/api/{id}/chat-kill", req -> _withnb(h, req, nb -> begin
        (_agent_available() && !isempty(nb.agents)) || return _json(Dict("ok" => false))
        for aid in collect(values(nb.agents))
            try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => aid)); catch; end
        end
        _reap_agents!(nb; keep_log = true)   # agents gone, transcript stays visible
        _json(Dict("ok" => true, "killed" => true))
    end))
    # Clear the conversation entirely: interrupt + reap every agent, then wipe the
    # transcript from memory AND disk. The next message starts a clean chat.
    HTTP.register!(router, "POST", "/api/{id}/chat-clear", req -> _withnb(h, req, nb -> begin
        if _agent_available() && !isempty(nb.agents)
            for aid in collect(values(nb.agents))
                try; _agent_call(:agent_interrupt, Dict{String,Any}("agent_id" => aid)); catch; end
            end
        end
        _reap_agents!(nb; keep_log = false)   # agents gone + in-memory log dropped
        _clear_chat_log!(nb)                  # and the on-disk transcript
        _json(Dict("ok" => true, "cleared" => true))
    end))
    # Locally-served models → the Settings model dropdown (ollama:<name> / vmlx:<name>).
    HTTP.register!(router, "GET", "/api/{id}/ollama-models", req -> _withnb(h, req, _ ->
        _json(Dict("models" => _ollama_models()))))
    HTTP.register!(router, "GET", "/api/{id}/vmlx-models", req -> _withnb(h, req, _ ->
        _json(Dict("models" => _vmlx_models()))))
    # Semantic docs search (docs v2) — for the UI palette; the agent uses slate.search_docs.
    HTTP.register!(router, "GET", "/api/{id}/docsearch", req -> _withnb(h, req, nb -> begin
        q = strip(get(HTTP.queryparams(HTTP.URI(req.target)), "q", ""))
        results = isempty(q) ? Dict{String,Any}[] : search_docs(String(q); modules = _inscope_modules(nb))
        for r in results; r["docHtml"] = _doc_html(get(r, "doc", "")); end   # rendered markdown for the detail pane
        _json(Dict("results" => results))
    end))
    # Live help lookup (?Module / cross-reference link) — doc + (for a module) its exports.
    HTTP.register!(router, "GET", "/api/{id}/help", req -> _withnb(h, req, nb -> begin
        name = strip(get(HTTP.queryparams(HTTP.URI(req.target)), "name", ""))
        _json(isempty(name) ? Dict{String,Any}() : help_lookup(nb, String(name)))
    end))
    # Client-rendered figure snapshot (ECharts canvas → PNG) — feeds slate_view + PDF.
    HTTP.register!(router, "POST", "/api/{id}/snapshot", req -> _withnb(h, req, nb -> begin
        b = _body(req); cell = String(get(b, "cell", "")); img = String(get(b, "image", ""))
        getstr(k) = (v = get(b, k, nothing); (v isa AbstractString && !isempty(v)) ? String(v) : nothing)
        svg = getstr("svg"); svg_dark = getstr("svgDark")
        (isempty(cell) || isempty(img)) && return _json(Dict("ok" => false))
        try; set_snapshot!(nb.id, cell, Vector{UInt8}(Base64.base64decode(img)); svg = svg, svg_dark = svg_dark); catch; return _json(Dict("ok" => false)); end
        _json(Dict("ok" => true))
    end))
    # Live cell inspect: the open tab POSTs a cell's captured DOM + console + raster in answer to an
    # `inspect:` SSE request (assets/js/inspect.js), routed back to the waiting slate.inspect call.
    HTTP.register!(router, "POST", "/api/{id}/inspect-result", req -> _withnb(h, req, nb -> begin
        b = _body(req); reqid = String(get(b, "reqid", ""))
        isempty(reqid) && return _json(Dict("ok" => false))
        cell = String(get(b, "cell", "")); png = String(get(b, "png", ""))   # raster → snapshot store (slate.view)
        (isempty(cell) || isempty(png)) || (try; set_snapshot!(nb.id, cell, Vector{UInt8}(Base64.base64decode(png))); catch; end)
        _json(Dict("ok" => deliver_live!(reqid, b)))
    end))
    # slate.eval_js: the open tab POSTs the result of running agent-supplied JS (assets/js/inspect.js
    # `_slateEvalJs`), in answer to a `js:` SSE request, routed back to the waiting eval call.
    HTTP.register!(router, "POST", "/api/{id}/eval-result", req -> _withnb(h, req, nb -> begin
        b = _body(req); reqid = String(get(b, "reqid", ""))
        isempty(reqid) && return _json(Dict("ok" => false))
        _json(Dict("ok" => deliver_live!(reqid, b)))
    end))
    # Browser diagnostics push (console errors / failed requests / unhandled rejections) →
    # read back by the slate.diag MCP tool. See assets/js/diag.js.
    HTTP.register!(router, "POST", "/api/{id}/diag", req -> _withnb(h, req, nb -> begin
        set_diag!(nb.id, _body(req)); _json(Dict("ok" => true))
    end))
    # Per-notebook toggle for parent /src hot-reload (Revise). Stored in report meta.
    HTTP.register!(router, "POST", "/api/{id}/hotreload", req -> _withnb(h, req, nb -> begin
        nb.report.meta["hotreload"] = get(_body(req), "enabled", true) === true
        _persist!(nb)                                    # write the Slate.config footer so it sticks
        _json(Dict("ok" => true, "hotreload" => nb.report.meta["hotreload"]))
    end))
    # Per-notebook toggle for parallel (inter-cell) execution. Stored in report meta; the runner reads
    # it each iteration, so it takes effect on the next run with no worker restart.
    HTTP.register!(router, "POST", "/api/{id}/parallel", req -> _withnb(h, req, nb -> begin
        nb.report.meta["parallel"] = get(_body(req), "enabled", false) === true
        _persist!(nb)                                    # write the Slate.config footer so it sticks
        _json(Dict("ok" => true, "parallel" => nb.report.meta["parallel"]))
    end))
    # Per-notebook worker-thread override. "" clears it (back to the global). Applies by respawning this
    # notebook's worker — so changing it kills + restarts the process (lose the warm namespace), unlike
    # the parallel toggle. Stored in meta so it survives reloads; the .jl footer carries it across restarts.
    HTTP.register!(router, "POST", "/api/{id}/threads", req -> _withnb(h, req, nb -> begin
        spec = strip(String(get(_body(req), "threads", "")))
        if isempty(spec)
            delete!(nb.report.meta, "threads")
        else
            nb.report.meta["threads"] = spec
        end
        nb.kernel isa ReportEngine.GateKernel && (nb.kernel.threads = spec)   # update the live kernel's override
        _persist!(nb)                                                          # write the Slate.config footer
        restart_kernel!(nb)                                                    # respawn the worker with it
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/reset", req -> _withnb(h, req, nb -> begin
        ReportEngine.reset!(nb.kernel, nb.report); build_dependencies!(nb.report); _eval!(nb); _json(state_json(nb))
    end))
    # ── Time machine: durable edit history ───────────────────────────────────
    # List checkpoints (newest data is appended last); `current` marks the live state.
    HTTP.register!(router, "GET", "/api/{id}/history", req -> _withnb(h, req, nb ->
        _json(Dict("entries" => SlateHistory.entries(nb.path),
                   "current" => SlateHistory.latest_hash(nb.path)))))
    # Full serialized source of one recorded state (for preview / diff / replay).
    HTTP.register!(router, "GET", "/api/{id}/history/{hash}", req -> _withnb(h, req, nb -> begin
        hash = HTTP.getparam(req, "hash")
        src = SlateHistory.content(nb.path, hash)
        src === nothing ? HTTP.Response(404, "no such snapshot") :
            _json(Dict("hash" => hash, "source" => src))
    end))
    # Restore a recorded state (non-destructive: recorded as a new checkpoint).
    HTTP.register!(router, "POST", "/api/{id}/history/restore", req -> _withnb(h, req, nb -> begin
        hash = String(get(_body(req), "hash", ""))
        restore_history!(nb, hash) ? _json(state_json(nb)) : HTTP.Response(404, "no such snapshot")
    end))
    return router
end

const _EVENTS_RE = r"^/api/([^/]+)/events$"

"""
    start_hub(; host="127.0.0.1", port=8765) -> Hub

Start the single notebook server with an empty registry. Add notebooks with
[`open_notebook!`](@ref). Non-blocking.
"""
function start_hub(; host = "127.0.0.1", port = 8765)
    h = Hub(Dict{String,LiveNotebook}(), nothing, host, port, ReentrantLock())
    handle = HTTP.streamhandler(_make_router(h))
    server = HTTP.listen!(host, port) do stream::HTTP.Stream
        target = stream.message.target
        m = match(_EVENTS_RE, target)
        if m !== nothing
            nb = lock(h.lock) do; get(h.notebooks, m.captures[1], nothing); end
            nb === nothing && (nb = _reopen_persisted!(h, m.captures[1]))   # re-register after a restart
            nb === nothing ? (HTTP.setstatus(stream, 404); HTTP.startwrite(stream)) : _sse(stream, nb)
        elseif startswith(target, "/api/import-standalone")   # long-lived SSE; raw Stream, not router
            _sse_import(stream, h)
        else
            t0 = time()
            handle(stream)
            dt = time() - t0      # includes the body WRITE — surfaces slow transfers, not just slow compute
            dt > 1.0 && @warn "Kaimon Slate: slow request" target round_ms = round(Int, dt * 1000)
        end
    end
    h.server = server
    @info "Kaimon Slate hub" url = _hub_url(h)
    return h
end

"""
    open_notebook!(hub, path) -> id

Load the notebook at `path` into the hub (reusing the existing entry if already
open) and start its file watcher. Returns the hub id (its `/n/<id>` route).
"""
function open_notebook!(h::Hub, path::AbstractString; threads::AbstractString = "")
    file = abspath(path)
    id = lock(h.lock) do
        for nb in values(h.notebooks)
            abspath(nb.path) == file && return nb.id
        end
        id = _unique_id(h, file)
        nb = load_notebook(file; id = id, threads = threads)
        h.notebooks[id] = nb
        _start_watcher!(nb)
        return id
    end
    _persist_registry!(h)        # remember id→path so a restart can lazily re-open it
    return id
end

"Remove a notebook from the hub: drain its SSE connections and drop it."
function close_notebook!(h::Hub, id::AbstractString)
    removed = lock(h.lock) do
        nb = get(h.notebooks, id, nothing)
        nb === nothing && return false
        _close_listeners(nb)
        _close_agent!(nb)
        unregister_refresh!(nb.report.id); unregister_srcchange!(nb.report.id); unregister_progress!(nb.report.id); unregister_runbatch!(nb.report.id); unregister_userprog!(nb.report.id); unregister_celldone!(nb.report.id)
        try; shutdown!(nb.kernel); catch; end
        delete!(h.notebooks, id)
        return true
    end
    removed && _persist_registry!(h)        # forget an explicitly-closed nb so a restart won't re-open it
    return removed
end

"Stop the hub: drain every notebook's SSE connections, then close the server."
function stop_hub(h::Hub)
    lock(h.lock) do
        for nb in values(h.notebooks)
            _close_listeners(nb); unregister_refresh!(nb.report.id); unregister_srcchange!(nb.report.id); unregister_progress!(nb.report.id); unregister_runbatch!(nb.report.id); unregister_userprog!(nb.report.id); unregister_celldone!(nb.report.id)
            try; shutdown!(nb.kernel); catch; end
        end
        empty!(h.notebooks)
    end
    h.server === nothing || close(h.server)
    return nothing
end

