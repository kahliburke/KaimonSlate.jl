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
function restart_kernel!(nb::LiveNotebook)
    lock(nb.lock) do
        try; ReportEngine.shutdown!(nb.kernel); catch; end
        ReportEngine.reset!(nb.kernel, nb.report)
        build_dependencies!(nb.report)
        eval_stale!(nb.report, nb.kernel)
    end
    _broadcast(nb, "restart")
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
    HTTP.register!(router, "POST", "/api/{id}/cell/{cid}", req -> _withnb(h, req, nb -> begin
        edit_cell!(nb, HTTP.getparam(req, "cid"), get(_body(req), "source", "")); _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/complete", req -> _withnb(h, req, nb -> begin
        body = _body(req)
        code = String(get(body, "code", ""))
        pos = clamp(Int(get(body, "pos", ncodeunits(code))), 0, ncodeunits(code))
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
        _json(Dict("completions" => [Dict("text" => t, "kind" => k) for (t, k) in items],
                   "from" => from, "to" => to))
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
    HTTP.register!(router, "POST", "/api/{id}/cell-move/{cid}", req -> _withnb(h, req, nb -> begin
        b = _body(req); cid = HTTP.getparam(req, "cid")
        haskey(b, "target") ? move_cell_rel!(nb, cid, b["target"], get(b, "before", true) === true) :
                              move_cell!(nb, cid, get(b, "dir", "up"))
        _json(state_json(nb))
    end))
    HTTP.register!(router, "POST", "/api/{id}/cell-type/{cid}", req -> _withnb(h, req, nb -> begin
        set_kind!(nb, HTTP.getparam(req, "cid"), get(_body(req), "kind", "code")); _json(state_json(nb))
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
    # Publication-quality PDF via Typst (server-side). `?source=0` hides code listings.
    HTTP.register!(router, "GET", "/api/{id}/export.pdf", req -> _withnb(h, req, nb -> begin
        qp = HTTP.queryparams(HTTP.URI(req.target))
        pdf = try
            export_pdf(nb; include_source = get(qp, "source", "1") != "0",
                       style = get(qp, "style", "article"),
                       columns = something(tryparse(Int, get(qp, "columns", "1")), 1),
                       theme = get(qp, "theme", "light"),
                       code = get(qp, "code", "normal"),
                       body = get(qp, "body", ""))
        catch e
            return HTTP.Response(500, "PDF export failed: " * sprint(showerror, e))
        end
        fn = replace(splitext(basename(nb.path))[1], r"[^A-Za-z0-9_.-]" => "_") * ".pdf"
        HTTP.Response(200, ["Content-Type" => "application/pdf",
                            "Content-Disposition" => "attachment; filename=\"$fn\""], pdf)
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
                eval_stale!(nb.report, nb.kernel)
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
    HTTP.register!(router, "POST", "/api/{id}/undo", req -> _withnb(h, req, nb -> (undo!(nb); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/redo", req -> _withnb(h, req, nb -> (redo!(nb); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/run", req -> _withnb(h, req, nb -> (eval_stale!(nb.report, nb.kernel); _json(state_json(nb)))))
    HTTP.register!(router, "POST", "/api/{id}/restart", req -> _withnb(h, req, nb -> (restart_kernel!(nb); _json(state_json(nb)))))
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
        results = isempty(q) ? Dict{String,Any}[] : search_docs(String(q))
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
    # Browser diagnostics push (console errors / failed requests / unhandled rejections) →
    # read back by the slate.diag MCP tool. See assets/js/diag.js.
    HTTP.register!(router, "POST", "/api/{id}/diag", req -> _withnb(h, req, nb -> begin
        set_diag!(nb.id, _body(req)); _json(Dict("ok" => true))
    end))
    # Per-notebook toggle for parent /src hot-reload (Revise). Stored in report meta.
    HTTP.register!(router, "POST", "/api/{id}/hotreload", req -> _withnb(h, req, nb -> begin
        nb.report.meta["hotreload"] = get(_body(req), "enabled", true) === true
        _json(Dict("ok" => true, "hotreload" => nb.report.meta["hotreload"]))
    end))
    HTTP.register!(router, "POST", "/api/{id}/reset", req -> _withnb(h, req, nb -> begin
        ReportEngine.reset!(nb.kernel, nb.report); build_dependencies!(nb.report); eval_stale!(nb.report, nb.kernel); _json(state_json(nb))
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
            nb === nothing ? (HTTP.setstatus(stream, 404); HTTP.startwrite(stream)) : _sse(stream, nb)
        elseif startswith(target, "/api/import-standalone")   # long-lived SSE; raw Stream, not router
            _sse_import(stream, h)
        else
            handle(stream)
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
function open_notebook!(h::Hub, path::AbstractString)
    file = abspath(path)
    lock(h.lock) do
        for nb in values(h.notebooks)
            abspath(nb.path) == file && return nb.id
        end
        id = _unique_id(h, file)
        nb = load_notebook(file; id = id)
        h.notebooks[id] = nb
        _start_watcher!(nb)
        return id
    end
end

"Remove a notebook from the hub: drain its SSE connections and drop it."
function close_notebook!(h::Hub, id::AbstractString)
    lock(h.lock) do
        nb = get(h.notebooks, id, nothing)
        nb === nothing && return false
        _close_listeners(nb)
        _close_agent!(nb)
        unregister_refresh!(nb.report.id); unregister_srcchange!(nb.report.id)
        try; shutdown!(nb.kernel); catch; end
        delete!(h.notebooks, id)
        return true
    end
end

"Stop the hub: drain every notebook's SSE connections, then close the server."
function stop_hub(h::Hub)
    lock(h.lock) do
        for nb in values(h.notebooks)
            _close_listeners(nb); unregister_refresh!(nb.report.id); unregister_srcchange!(nb.report.id)
            try; shutdown!(nb.kernel); catch; end
        end
        empty!(h.notebooks)
    end
    h.server === nothing || close(h.server)
    return nothing
end

