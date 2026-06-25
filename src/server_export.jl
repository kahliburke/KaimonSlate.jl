# Part of the NotebookServer submodule — included by server.jl (which holds the module
# header: imports/exports, the LiveNotebook struct). Names here resolve in NotebookServer.

# ── Static export (HTML / print-to-PDF) ──────────────────────────────────────
# A self-contained HTML document of the notebook: markdown rendered, code shown,
# outputs embedded (images as base64), client-rendered ECharts frozen to their latest
# snapshot PNG, interactive tables flattened to static HTML. KaTeX from a CDN typesets
# math. No server, no scripts to boot — openable offline and printable to PDF.
const _EXPORT_CSS = """
:root{--bg:#0d1120;--bg2:#141828;--bg3:#1a1e2e;--border:#2a2e40;--text:#d4d8e8;--dim:#6a7090;
  --accent:#569cd6;--green:#56d364;--red:#e57575;--gold:#ffd700;}
*{box-sizing:border-box;} body{background:var(--bg);color:var(--text);margin:0;
  font-family:'Segoe UI',system-ui,sans-serif;line-height:1.6;}
.export{max-width:900px;margin:0 auto;padding:36px 24px 80px;}
.exp-title{color:#fff;font-size:1.9rem;margin:0 0 2px;}
.exp-meta{color:var(--dim);font-size:.78rem;font-family:monospace;margin-bottom:24px;
  border-bottom:1px solid var(--border);padding-bottom:14px;}
.exp-md{margin:14px 0;} .exp-md h1{font-size:1.6rem;border-bottom:1px solid var(--border);padding-bottom:.2em;}
.exp-md table,.exp-table{border-collapse:collapse;margin:8px 0;font-size:.84rem;}
.exp-md td,.exp-md th,.exp-table td,.exp-table th{border:1px solid var(--border);padding:4px 10px;text-align:left;}
.exp-table th{background:var(--bg3);color:var(--dim);} .exp-table td{font-variant-numeric:tabular-nums;}
.exp-md code{background:var(--bg3);padding:1px 5px;border-radius:4px;}
.exp-code{margin:14px 0;border:1px solid var(--border);border-radius:8px;background:var(--bg2);overflow:hidden;}
.exp-src{margin:0;padding:10px 14px;background:var(--bg3);border-bottom:1px solid var(--border);overflow-x:auto;}
.exp-src code{font-family:'Cascadia Code','Fira Code',monospace;font-size:.82rem;color:var(--text);white-space:pre;}
.exp-src .hl-kw{color:#c586c0;} .exp-src .hl-com{color:#6a9955;font-style:italic;}
.exp-src .hl-num{color:#b5cea8;} .exp-src .hl-str{color:#ce9178;}
.exp-src .hl-macro{color:#569cd6;} .exp-src .hl-op{color:#56b6c2;}
.exp-src .hl-fn{color:#dcdcaa;} .exp-src .hl-type{color:#4ec9b0;} .exp-src .hl-sym{color:#d19a66;}
.exp-out{font-size:.86rem;} .exp-out .out,.exp-out .val,.exp-out .err{padding:8px 14px;}
.exp-out .out{color:var(--dim);} .exp-out .val{color:var(--green);} .exp-out .err{color:var(--red);}
.exp-out pre{margin:0;white-space:pre-wrap;} .exp-out .dispwrap,.disp.img{padding:10px 14px;}
.disp.img img{max-width:100%;height:auto;border-radius:4px;display:block;}
.disp.latex{padding:6px 14px;overflow-x:auto;} .katex{font-size:1.1em;}
@media print{ body{-webkit-print-color-adjust:exact;print-color-adjust:exact;} .exp-code{break-inside:avoid;} }
"""

function _export_table_html(spec)
    cols = get(spec, "columns", Any[])
    rows = get(spec, "rows", Any[])
    io = IOBuffer()
    print(io, "<table class=\"exp-table\"><thead><tr>")
    for c in cols
        nm = c isa AbstractDict ? get(c, "name", "") : c
        print(io, "<th>", _esc(string(nm)), "</th>")
    end
    print(io, "</tr></thead><tbody>")
    for r in rows
        print(io, "<tr>")
        for v in r
            print(io, "<td>", v === nothing ? "" : _esc(string(v)), "</td>")
        end
        print(io, "</tr>")
    end
    print(io, "</tbody></table>")
    return String(take!(io))
end

# Server-side Julia syntax highlighting for the SELF-CONTAINED export: tokenize with the
# `JuliaSyntax` bundled in Base (no dependency, no JS, works offline) and wrap each interesting
# token in a `<span class="hl-…">`; whitespace/punctuation pass through as escaped text. A macro
# call (`@name`) colours both the `@` and the following name. Any tokenizer hiccup falls back to
# plain escaped source, so a syntactically-incomplete cell still exports.
function _highlight_julia(code::AbstractString)
    isempty(code) && return ""
    try
        JS = Base.JuliaSyntax
        cu = codeunits(code)                 # token ranges are BYTE ranges (char-aligned), so slice
        toks = collect(JS.tokenize(code))    # bytes — `code[range]` throws when a token follows a
        kinds = [string(JS.kind(t)) for t in toks]   # multibyte char like λ/π/θ (mid-char index).
        n = length(toks)
        io = IOBuffer()
        prev_at = false                       # last token was `@` → this one is the macro name
        prev_sym = false                      # last token was a quote-colon → this one completes `:name`
        for i in 1:n
            t = toks[i]; txt = String(cu[t.range]); k = JS.kind(t); ks = kinds[i]
            nextk = i < n ? kinds[i+1] : ""   # IMMEDIATE next (no skip) — call/symbol have no space
            # `*` `^` `'` `/` `<` … tokenize as identifiers, not operator kinds — catch them too.
            is_op_id = ks == "Identifier" && Base.isoperator(Symbol(txt))
            cls = JS.is_keyword(k) ? "kw" :
                  ks == "Comment" ? "com" :
                  (prev_at || ks == "@") ? "macro" :
                  prev_sym ? "sym" :
                  (ks == ":" && nextk == "Identifier") ? "sym" :        # :gray  :cyan  :dash
                  JS.is_number(k) ? "num" :
                  (occursin("String", ks) || occursin("Char", ks) || ks in ("\"", "`")) ? "str" :
                  (ks == "Identifier" && !is_op_id && nextk == "(") ? "fn" :   # f(…)  lines!(…)
                  (is_op_id || JS.is_operator(k)) ? "op" :
                  (ks == "Identifier" && !isempty(txt) && isuppercase(first(txt))) ? "type" : ""
            prev_at = (ks == "@")
            prev_sym = (cls == "sym" && ks == ":")
            isempty(cls) ? print(io, _esc(txt)) :
                print(io, "<span class=\"hl-", cls, "\">", _esc(txt), "</span>")
        end
        return String(take!(io))
    catch
        return _esc(code)
    end
end

function export_html(nb::LiveNotebook; include_source::Bool = true)
    lock(nb.lock) do
        title = _esc(nb.report.title)
        io = IOBuffer()
        print(io, "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"/>",
              "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\"/><title>", title, "</title>",
              "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css\"/>",
              "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js\"></script>",
              "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js\"></script>",
              "<style>", _EXPORT_CSS, "</style></head><body><article class=\"export\">")
        print(io, "<h1 class=\"exp-title\">", title, "</h1>")
        print(io, "<div class=\"exp-meta\">Exported from Kaimon Slate · ", _esc(abspath(nb.path)), "</div>")
        for c in nb.report.cells
            if c.kind == MARKDOWN
                print(io, "<section class=\"exp-md\">", markdown_html(c.source, c.interp), "</section>")
            else
                print(io, "<section class=\"exp-code\">")
                # Honour BOTH the global `?source=0` toggle AND the per-cell `hidecode` flag (the
                # 🙈 toggle) — a cell whose code is hidden in the notebook exports output-only.
                (include_source && !(:hidecode in c.flags) && !isempty(strip(c.source))) &&
                    print(io, "<pre class=\"exp-src\"><code>", _highlight_julia(c.source), "</code></pre>")
                print(io, "<div class=\"exp-out\">", output_html(c), "</div>")
                if !isempty(_echarts_specs(c))            # client-rendered chart → freeze to snapshot
                    png = _snapshot(nb.id, c.id)
                    png === nothing || print(io, "<div class=\"disp img\"><img alt=\"chart\" src=\"data:image/png;base64,",
                                                  Base64.base64encode(png), "\"/></div>")
                end
                for spec in _table_specs(c)
                    print(io, _export_table_html(spec))
                end
                print(io, "</section>")
            end
        end
        print(io, "</article><script>window.addEventListener('load',function(){",
              "if(window.renderMathInElement)renderMathInElement(document.body,{delimiters:[",
              "{left:'\$\$',right:'\$\$',display:true},{left:'\\\\[',right:'\\\\]',display:true},",
              "{left:'\$',right:'\$',display:false},{left:'\\\\(',right:'\\\\)',display:false}],throwOnError:false});});",
              "</script></body></html>")
        return String(take!(io))
    end
end

# The notebook-priming system prompt, set once at `agent_open` (the `system_prompt`
# arg → `claude --append-system-prompt`). It makes the agent a *live notebook
# operator* — driving the reactive notebook one cell at a time through the `slate.*`
# tools and reading each result — instead of a blind file-author that composes
# everything in its head and dumps one big Edit.
# DAG-scoped context for a per-cell ✨ turn: the target cell + its upstream dependency
# cone (what it reads, transitively, with sources) + downstream impact. Lets the agent
# work focused — edit this cell, branch upstream only when the cause is a precursor — and
# it knows WHERE the precursors are instead of grepping.
# Inline-reference expansion: a user can mention a cell by `@id` in chat (the UI offers
# autocomplete on `@`). For each @token that resolves to a real cell id, append that cell's
# source + current result, so the agent has the referenced cells in hand without surveying
# the whole notebook. Returns "" when nothing resolves.
function _mention_context(nb::LiveNotebook, text::AbstractString)
    byid = Dict(c.id => c for c in nb.report.cells)
    refs = String[]
    for m in eachmatch(r"@([A-Za-z0-9_]+)", String(text))
        id = String(m.captures[1])
        (haskey(byid, id) && !(id in refs)) && push!(refs, id)
    end
    isempty(refs) && return ""
    io = IOBuffer()
    print(io, "══ REFERENCED CELLS — the user mentioned these by @id; here is each one's source and current result. ══")
    for id in refs
        c = byid[id]
        kind = c.kind == MARKDOWN ? "md" : "code"
        print(io, "\n\n--- @", id, " [", kind, "] ---\n", rstrip(c.source))
        c.kind == CODE && print(io, "\n→ ", replace(_cell_result_text(c), "\n" => "\n  "))
    end
    return String(take!(io))
end

function _cell_context(nb::LiveNotebook, id::AbstractString)
    cells = nb.report.cells
    i = findfirst(c -> c.id == id, cells)
    i === nothing && return ""
    byid = Dict(c.id => c for c in cells)
    up = Set{String}(); frontier = String[id]
    while !isempty(frontier)
        c = get(byid, pop!(frontier), nothing); c === nothing && continue
        for d in c.deps
            (d == id || d in up) && continue
            push!(up, d); push!(frontier, d)
        end
    end
    down = setdiff(dependents_of(nb.report, Set([id])), Set([id]))
    io = IOBuffer()
    println(io, "══ SCOPED TURN — the user clicked ✨ on cell `", id, "`. This cell is your ENTIRE focus. ══")
    println(io, "- Answer about / modify ONLY cell `", id, "` (and, if a fix truly requires it, the upstream",
            " cells listed below that it reads from).")
    println(io, "- Do NOT review, critique, or touch any OTHER cell. Do NOT call `slate_read` to survey the",
            " whole notebook — this cell's source, output, its upstream dependency cone, and its downstream",
            " impact are ALL given below. Only read another cell if you genuinely need one not shown here.")
    println(io, "- If the request can't be satisfied within this cell + its precursors, say so briefly instead",
            " of widening scope. `slate_view(\"", id, "\")` shows this cell's figure if it has one.")
    tc = cells[i]
    println(io, "\n--- cell `", id, "` source ---\n", tc.source)
    o = tc.output
    if o !== nothing
        o.exception !== nothing ? println(io, "→ ERROR: ", first(split(o.exception, "\n"))) :
            (isempty(o.value_repr) || println(io, "→ ", o.value_repr))
    end
    upcells = [c for c in cells if c.id in up]
    if !isempty(upcells)
        println(io, "\n--- upstream cells it depends on (define what it reads) ---")
        for c in upcells
            println(io, "[`", c.id, "`] ", replace(strip(first(split(c.source, "\n"))), r"\s+" => " "))
        end
    end
    isempty(down) || println(io, "\n--- changing it re-runs downstream: ", join(sort(collect(down)), ", "))
    return String(take!(io))
end

# ── Canonical Slate notebook-API reference (SINGLE SOURCE OF TRUTH) ───────────
# The one place documenting the helpers injected into every cell (echart, @bind, reactive,
# slate_table) — fed to BOTH the agent system prompt below AND the `slate.api` tool, so the two
# can never drift (that drift is exactly what left an agent using the old echart API). Update the
# notebook API? Update HERE. Reached from the parent module as `NotebookServer.slate_api_reference()`.
const _SLATE_API = """
# Kaimon Slate notebook API

Cells run in a REACTIVE notebook: a cell that READS a variable re-runs automatically when that
variable changes. The LAST expression of a cell is DISPLAYED. Beyond standard Julia and your
`using`'d packages, these helpers are injected into every cell — they are Slate-specific, so look
HERE (not `slate.search_docs`, which only indexes packages and will mislead you toward Makie).

## Display
Return the value to show — a number / String / DataFrame, a CairoMakie figure, an `echart(…)`, or
`slate_table(df)`. Use `println` for stdout.

## Charts — `echart` (Slate's ECharts DSL; NOT Makie's `series`)
    echart(:line, x, y; title="…", smooth=true)          # Express: ONE series. kinds: line bar
                                                          #   scatter area pie heatmap candlestick
                                                          #   radar boxplot gauge funnel … (+ any raw type)
    echart(series(:line, x, a; name="a"),                 # Composable: MANY series
           series(:bar,  x, b; name="b"); legend=true, title="Mix")
    echart(; xAxis=(type=:category, data=x),              # Raw: the full ECharts option surface
            series=[(type=:bar, data=b)], dataZoom=[(type=:slider,)])
Renders live, animating in place on updates. Ergonomic kinds infer data shape + components
(`:heatmap` matrix→axes+visualMap, `:radar` indicators, `:boxplot` raw samples). `?echart` `?series`.

## Widgets — `@bind name Widget(…)`  (declare in a cell; `name` holds the live value)
    @bind n     Slider(1:100; label="n")
    @bind on    Toggle(true; on="A", off="B")
    @bind which Radio(["sin"=>"sine", "cos"=>"cosine"])     # value => label pairs (which == "sin")
    @bind sel   Select(opts) / MultiSelect(opts) / MultiCheckBox(opts) / Checkbox(true)
    @bind s     NumberField(0) / TextField("hi") / TextArea("…") / ColorPicker("#56d364")
    @bind dt    DateField(…) / TimeField(…)
    @bind go    Button("Run")                               # value = click count (Int, 0,1,2,…)
Any cell that READS a bound var recomputes when its control changes. `which.label` = the label.

## Live / async — stream updates into a value over time
    level = reactive(:level, 0)        # live value: `level[]` reads, `level[] = v` pushes to readers
    @onclick go begin                  # runs on click; a NEW click cancels the still-running prior run
        for v in 0:2:100; level[] = v; pause(0.1) end       # pause = CANCELLABLE sleep
    end
    @onchange n  (level[] = n)         # runs on each change; `n` is the new value; cell does NOT recompute
    cancel(:level)                     # cooperatively stop a running @onclick handler (at its next pause)
A chart/cell that reads `level[]` re-renders live as values are pushed — no manual refresh.

## Tables — `slate_table(df; …)`  → an interactive sortable / filterable / paged table

Worked examples: `examples/echarts_dsl.jl` (all chart forms + a live gauge) and
`examples/binds_demo.jl` (every widget).
"""
slate_api_reference() = _SLATE_API

function _agent_system_prompt(nb::LiveNotebook)
    return """
    You are pair-building a LIVE reactive Julia notebook with the user, in real time.
    Your notebook id is "$(nb.id)" (file: $(abspath(nb.path))). Pass that id as the
    `notebook` argument to every slate tool.

    OPERATE THE NOTEBOOK THROUGH THESE TOOLS — do NOT edit the .jl file directly:
      mcp__kaimon__slate_read(notebook)                          — all cells + their outputs/errors
      mcp__kaimon__slate_add_cell(notebook, source, after, kind) — append a cell, RUN it, return its result
      mcp__kaimon__slate_edit_cell(notebook, cell, source)       — revise a cell, run it, return its result
      mcp__kaimon__slate_run(notebook, cell)                     — run a cell ("" = all stale)
      mcp__kaimon__slate_delete_cell(notebook, cell)             — remove a cell
      mcp__kaimon__slate_view(notebook, cell)                    — SEE a cell's rendered
        figure (returns the image) — inspect a CairoMakie plot you made and fix it
    (`after`="" appends at the end; `kind` is "code" or "md".)

    LEARN THE API — you have NO file access, so do NOT grep/read source.
      mcp__kaimon__slate_api()                          — the SLATE notebook helper cheatsheet:
        echart (charts), @bind widgets, reactive/@onclick (live updates), slate_table. READ THIS
        before plotting or adding interactivity — these helpers are NOT in any package's docs.
      mcp__kaimon__slate_search_docs(notebook, query)   — fuzzy semantic search of the notebook's
        PACKAGE docs (Statistics, DataFrames, CairoMakie, …). NOTE: a search for "chart"/"series"
        returns CairoMakie's `series` — that is NOT the Slate `echart` API; use slate_api for that.
      mcp__kaimon__slate_index_docs(notebook, modules)  — force-index more packages if a search is empty

    WORK INCREMENTALLY — this is the entire point of the project:
    - Call slate_read FIRST to see the current state.
    - Add ONE cell at a time with slate_add_cell, then LOOK at the result it returns.
    - If a cell errors, fix it with slate_edit_cell before moving on.
    - Choose the next cell from what you just saw. Do NOT compose the whole notebook
      in your head and write it all at once — small, visible steps the user can watch.
    - Cells are REACTIVE: a cell re-runs when an upstream variable it reads changes.

    $(_SLATE_API)

    For STATIC/scientific figures use **CairoMakie** (dark: `using CairoMakie;
    set_theme!(theme_dark())`; return the figure). NEVER GLMakie/WGLMakie (no GPU window), and do
    NOT use Makie `SliderGrid`/`@lift`/`Observable` — use the @bind reactivity above instead (Makie
    interactivity renders dead/static under CairoMakie).

    SCOPED TURNS: if a turn begins with a "SCOPED TURN — the user clicked ✨ on cell `…`"
    block, that cell is your whole focus for the turn. Stay on it (and only the upstream cells
    that block lists); do NOT survey or comment on the rest of the notebook, and do NOT
    slate_read the whole thing — the relevant context is already in the block.

    Be concise in chat. You are a focused notebook assistant — ignore any global or
    project onboarding (Kaimon usage quizzes, "take the quiz", Revise/Infiltrator
    workflows); never run a quiz or setup step.
    """
end

# Ensure an agent is bound to this notebook, spawning one (keyed `slate-<id>`,
# cwd = the notebook's directory) on first use and registering its event route.
# The agent inherits the host's MCP config (Kaimon included), so it can also call
# `slate.*`/`ex` — no explicit `mcp_config` needed (passing one with --strict would
# instead cut it off from the live Kaimon). Cell editing goes through the file.
# Ensure a crew member's agent is bound to this notebook, spawning one on first use.
# `crew` is a crew label ("" = the default/solo agent — id stays `slate-<id>` for
# back-compat so a re-adopted agent matches across an extension restart). Multiple
# crew agents share one notebook; `_AGENT_ROUTES` already maps each id → this nb.
# `model` ("" = service default = sonnet) binds at spawn only — an already-running
# crew agent keeps its model until reaped (the UI kills it on a model-setting change).
function _ensure_agent!(nb::LiveNotebook; crew::AbstractString = "", model::AbstractString = "",
                        permission::AbstractString = "")
    label = String(crew)
    existing = get(nb.agents, label, "")
    isempty(existing) || return existing
    aid = isempty(label) ? "slate-$(nb.id)" : "slate-$(nb.id)-$(label)"
    open_args = Dict{String,Any}(
            "cwd" => dirname(abspath(nb.path)),
            "id"  => aid,
            # Kaimon M4 permission preset. "lab" (the default) allows the agent the Kaimon
            # MCP tools (slate.*/ex/qdrant) + file edits — enough to drive + introspect the
            # notebook, without arbitrary shell/web. Runs unattended (no prompt to stall a
            # headless agent); the agent_* recursion guard is always applied. The user can
            # pick another preset in Settings ("auto"/"default"/"bypass"); it binds at spawn,
            # so a change reaps the agent (chat-kill) and the next turn respawns on it.
            "permission" => (isempty(permission) ? "lab" : String(permission)),
            "system_prompt" => _agent_system_prompt(nb))
    isempty(model) || (open_args["model"] = model)   # omit → Kaimon's default (sonnet)
    res = try
        _agent_call(:agent_open, open_args)
    catch e
        # Agent already running (e.g. it outlived an extension restart — agents are
        # Kaimon-owned) → re-adopt it rather than failing the chat.
        occursin("in use", lowercase(sprint(showerror, e))) || rethrow()
        Dict("agent_id" => aid)
    end
    aid = String(get(res, "agent_id", aid))
    isempty(aid) && error("agent_open returned no id")
    lock(_AGENT_LOCK) do
        _AGENT_ROUTES[aid] = nb
        _AGENT_CREW[aid] = label
        nb.agents[label] = aid
    end
    isempty(label) && (nb.agent_id = aid)   # keep the back-compat alias in sync
    return aid
end

# Close + deregister a notebook's crew agents (best effort). `keep_log=true` preserves
# the replay transcript (hard-kill: agents gone, but the conversation stays visible and
# a fresh agent continues it); `false` wipes it (notebook close — nothing left to show).
function _reap_agents!(nb::LiveNotebook; keep_log::Bool = false)
    aids = lock(_AGENT_LOCK) do
        ids = collect(values(nb.agents))
        for aid in ids
            delete!(_AGENT_ROUTES, aid); delete!(_AGENT_CREW, aid)
        end
        empty!(nb.agents)
        keep_log || delete!(_AGENT_LOG, nb.id)
        ids
    end
    nb.agent_id = ""
    if _agent_available()
        for aid in aids
            try; _agent_call(:agent_close, Dict{String,Any}("agent_id" => aid)); catch; end
        end
    end
    return nothing
end
_close_agent!(nb::LiveNotebook) = _reap_agents!(nb; keep_log = false)   # on notebook close

"""
    relay_agent_event(channel, data)

Gate-bus callback for an `agent:<id>` event: forward the raw `{kind,turn,data}`
JSON onto the bound notebook's SSE, prefixed `agent:` so the SPA's live-event
handler routes it to the chat pane. `data` already rides the bus as a JSON string.
"""
function relay_agent_event(channel::AbstractString, data)
    startswith(channel, "agent:") || return
    aid = String(channel)[length("agent:")+1:end]
    nb, crew = lock(_AGENT_LOCK) do
        get(_AGENT_ROUTES, aid, nothing), get(_AGENT_CREW, aid, "")
    end
    nb === nothing && return
    s = data isa AbstractString ? String(data) : String(JSON.json(data))
    env = try; JSON.parse(s); catch; nothing; end
    kind = env === nothing ? "" : get(env, "kind", "")
    # Tag the envelope with the speaking crew member so the SPA can lane multiple
    # agents (and replay stays attributed). Re-serialize only when we parsed cleanly.
    if env !== nothing
        env["crew"] = crew
        s = JSON.json(env)
    end
    # Mark the agent busy across a turn so the file-watcher attributes the edits it
    # makes to "agent" (not "external"). Clear shortly AFTER the turn ends, so the
    # watcher tick that picks up the agent's final save is still inside the window.
    if kind == "turn_started"
        nb.agent_busy = true
    elseif kind == "result"
        # Keep attributing edits to the agent for a bit after the turn ends — the
        # final file-write often syncs a couple seconds late (watcher latency), and
        # would otherwise be mislabeled "external".
        @async (sleep(8.0); nb.agent_busy = false)
    end
    # Always push live (token + tool-input deltas stream to the pane). Buffer for
    # reload-replay, but SKIP the liveness chunks (`data.delta == true` and
    # `tool_input_delta`) — the authoritative copies (the `delta:false` block, the
    # `tool_result`) are buffered, so replay stays clean and the cap isn't burned.
    _broadcast(nb, "agent:" * s)
    is_delta = kind == "tool_input_delta" ||
        (env !== nothing && (d = get(env, "data", nothing); d isa AbstractDict && get(d, "delta", false) === true))
    if !is_delta
        compact = false; bufcopy = String[]
        lock(_AGENT_LOCK) do
            buf = get!(_AGENT_LOG, nb.id, String[])
            push!(buf, s)
            length(buf) > _AGENT_LOG_CAP && (popfirst!(buf); compact = true; bufcopy = copy(buf))
        end
        # Mirror to disk (outside the lock): append the new line, or compact the file to
        # the capped buffer once we start dropping the oldest (bounds the file to the cap).
        compact ? _rewrite_chat_log(nb, bufcopy) : _append_chat_log(nb, s)
    end
    return nothing
end

