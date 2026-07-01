# Part of NotebookServer — the SINGLE SOURCE OF TRUTH for Slate's notebook API (the helpers injected
# into every cell: echart, @bind + widgets, animate, reactive/@onclick, slate_table, slate_progress,
# cell tags …). These are NOT in package docstrings, so they're documented HERE and fed to three
# consumers, all from this one registry:
#   • the `slate.api` tool — `slate_api_reference()` renders the full reference, `("name")` drills in;
#   • semantic search — `slate_api_records()` is indexed into `slate_docs` (module "Slate"), so
#     `slate.search_docs("@bind")` finds these helpers alongside package docs;
#   • the agent system prompt — a CONCISE cheatsheet (`_SLATE_CHEATSHEET`) is inlined every turn.
# Add or change a helper? Edit the entry here and all three stay in sync.

"One documented Slate helper: `name`, its `category`, a `signature` line, and markdown `doc`."
struct SlateApiEntry
    name::String
    category::String
    signature::String
    doc::String          # markdown: a sentence or two + at least one example
end

const SLATE_API = SlateApiEntry[
    # ── Display ──────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("display", "Display", "<last expression of a cell>",
        """The cell's LAST expression is shown. Return a number / String / DataFrame, a CairoMakie
        figure, an `echart(…)`, a `slate_table(df)`, or an `animate(…)`. `println` writes stdout. A
        trailing `;` makes the cell quiet (no value shown). Cells are REACTIVE: a cell that READS a
        variable re-runs when that variable changes."""),

    # ── Charts ───────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("echart", "Charts", "echart(kind, x, y; title, smooth, yAxis=(type=:log,), …) | echart(series...; …) | echart(; xAxis=…, series=…)",
        """Slate's ECharts chart DSL (NOT Makie's `series`). Returns an `EChart`; RETURN it from a cell
        to render a live, interactive chart (zoom/pan/hover) that animates IN PLACE on reactive updates.
        Everything is thin sugar over the raw ECharts option dict, so the ENTIRE ECharts surface stays
        reachable — nothing is gated.

        THREE FORMS
        ```julia
        echart(:line, x, y; title="…", smooth=true)                      # Express — one series, axes inferred
        echart(series(:line, x, a; name="a"), series(:bar, x, b; name="b"); legend=true)   # Composable — many
        echart(; xAxis=(type=:category, data=x), series=[(type=:bar, data=b)], dataZoom=[(type=:slider,)])  # Raw
        ```

        KINDS + data shapes (Express positional args = `series` positional args)
        - `:line` / `:bar` `(x, y)` — string x ⇒ category axis, numeric x ⇒ value axis
        - `:area` `(x, y)` — line with a filled `areaStyle`
        - `:scatter` `(x, y)`   ·   `:pie` `(labels, values)`
        - `:heatmap` `(z::Matrix)` or `(xlabels, ylabels, z)` — adds category axes + a `visualMap`
        - `:candlestick` `(dates, ohlc)` where `ohlc[i] = [open, close, low, high]`
        - `:radar` `(indicators, values)` — `indicators = ["Sales"=>6500, …]`; values a vector, or
          `["Allocated"=>[…], "Actual"=>[…]]` for several rings
        - `:boxplot` `(categories, data)` — each `data[i]` is `[min,Q1,med,Q3,max]` OR raw samples (auto 5-number)
        - any other ECharts type via `series(:kind; data=…, …)` — gauge, funnel, sankey, graph, tree, …

        AXES & COMPONENTS — top-level, work in EVERY form (Express too). These kwargs go on the OPTION,
        not the series: `xAxis yAxis grid dataZoom visualMap toolbox polar angleAxis radiusAxis radar geo
        dataset calendar timeline singleAxis parallel parallelAxis graphic axisPointer`.
        ```julia
        echart(:line, x, y; yAxis=(type=:log,))                          # LOG axis (log-scaled Y)
        echart(:bar,  x, y; grid=(left=70, right=20, containLabel=true))  # roomier plot area
        echart(:line, x, y; dataZoom=[(type=:slider,)])                  # zoom/pan slider
        echart(:scatter, x, y; visualMap=(min=0, max=1, dimension=1, calculable=true))
        # Dual Y axes: give an array of axes + point a series at the 2nd:
        echart(series(:line, x, a; name="L"), series(:line, x, b; name="R", yAxisIndex=1);
               yAxis=[(name="L",), (name="R", type=:log)])
        ```

        SERIES STYLING — any OTHER kwarg (Express or `series`) is spliced into the series verbatim:
        `smooth stack symbolSize step lineStyle itemStyle areaStyle label markLine markPoint markArea …`
        ```julia
        echart(:bar,  x, a; stack="total")                               # stacked bars
        echart(:line, x, y; markLine=(data=[(type=:average,)],), symbolSize=6)
        ```

        DEFAULTS: dark theme + transparent bg (`theme=false` to opt out); `tooltip=true`; a `legend`
        appears when ≥2 series are named (`legend=<spec>` to place it, `legend=false` to drop it);
        `title="…"`. Reactive charts re-`setOption` (~300 ms transition; `animation=false` to snap).
        Worked examples: `examples/echarts_dsl.jl`. See also `series`."""),
    SlateApiEntry("series", "Charts", "series(kind, x, y; name, smooth, stack, symbolSize, …) -> EChartSeries",
        """One series for the composable `echart(series(…), series(…); …)` form — combine different
        kinds/axes in one chart. Same positional data shapes as `echart`'s Express kinds (`:line`/`:bar`/
        `:area` `(x,y)`, `:scatter` `(x,y)`, `:pie` `(labels,vals)`, `:heatmap` `(z)`/`(xs,ys,z)`,
        `:candlestick` `(dates,ohlc)`, `:radar` `(inds,vals)`, `:boxplot` `(cats,data)`; any other kind
        via `series(:kind; data=…)`). `name=` labels it for the legend; every extra kwarg (`smooth`,
        `stack`, `symbolSize`, `yAxisIndex`, `markLine`, `lineStyle`, …) splices into the series option.
        ```julia
        echart(series(:bar, x, a; name="obs", stack="t"),
               series(:line, x, b; name="fit", smooth=true, yAxisIndex=1); legend=true,
               yAxis=[(name="obs",), (name="fit", type=:log)])
        ```"""),

    # ── Animation ────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("animate", "Animation", "animate(frames; kind=:heatmap, fps=30, colormap=:auto, clim=:global, transform, dither, x, y, title, loop, autoplay) -> Animation",
        """Precompute a stack of 2-D fields (a `Vector` of matrices) ONCE, then play it back entirely
        in the browser on a WebGL canvas — nothing touches Julia during playback, so a slow simulation
        still plays at 60 fps. `clim`: `:global` (comparable frames) | `:symmetric` (signed fields →
        diverging map; skips `transform`) | `:perframe` | `(lo,hi)`. `colormap`: a name (`:viridis`,
        `:magma`, …) or a `cgrad(:magma)` from your own Makie env. Pair with `playhead` to react to the
        current frame.
        ```julia
        frames = [density(t) for t in times]          # heavy compute, once (cache it)
        animate(frames; clim=:symmetric, x=r, y=r, title="ψ(t)", autoplay=true)
        ```"""),

    # ── Widgets (@bind) ────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("@bind", "Widgets", "@bind name Widget(…)",
        """Declare a reactive input control: `name` holds the live value, and any cell that READS
        `name` recomputes when the control changes. Widgets: Slider, NumberField, Checkbox, Toggle,
        TextField, TextArea, Select, Radio, MultiSelect, MultiCheckBox, ColorPicker, DateField,
        TimeField, Button, playhead. `@bind n Slider(1:100; label=\"n\")`."""),
    SlateApiEntry("Slider", "Widgets", "Slider(range; default, label) | Slider(lo, hi, default; step, label)",
        """A range slider. `@bind n Slider(1:100; label=\"n\")` or `@bind x Slider(0.0, 1.0, 0.5; step=0.01)`."""),
    SlateApiEntry("NumberField", "Widgets", "NumberField(default=0; min, max, label)",
        """A numeric input box. `@bind k NumberField(10; min=0, max=100)`."""),
    SlateApiEntry("Checkbox", "Widgets", "Checkbox(default=false; label)",
        """A boolean checkbox. `@bind on Checkbox(true)`."""),
    SlateApiEntry("Toggle", "Widgets", "Toggle(default=false; label, on, off)",
        """A boolean toggle with optional on/off labels. `@bind live Toggle(true; on=\"Live\", off=\"Paused\")`."""),
    SlateApiEntry("TextField", "Widgets", "TextField(default=\"\"; label)",
        """A single-line text input. `@bind name TextField(\"hi\")`."""),
    SlateApiEntry("TextArea", "Widgets", "TextArea(default=\"\"; rows=3, label)",
        """A multi-line text input. `@bind note TextArea(\"\"; rows=5)`."""),
    SlateApiEntry("Select", "Widgets", "Select(options, default; label)",
        """A dropdown. Options are bare values or `value => label` pairs (the bound var takes `value`;
        `.label` reaches the label). `@bind f Select([\"sin\"=>\"sine\", \"cos\"=>\"cosine\"])`."""),
    SlateApiEntry("Radio", "Widgets", "Radio(options, default; label)",
        """A radio group (rich/`\$math\$` labels rendered). `@bind which Radio([1=>\"one\", 2=>\"two\"])`."""),
    SlateApiEntry("MultiSelect", "Widgets", "MultiSelect(options, default=[]; label)",
        """A multi-select listbox; the bound value is a Vector. `@bind picks MultiSelect(cols)`."""),
    SlateApiEntry("MultiCheckBox", "Widgets", "MultiCheckBox(options, default=[]; label)",
        """A checkbox list (small discrete sets); value is a Vector. `@bind picks MultiCheckBox([:a,:b,:c])`."""),
    SlateApiEntry("ColorPicker", "Widgets", "ColorPicker(default=\"#3aa0ff\"; label)",
        """A color picker; value is a hex String. `@bind c ColorPicker(\"#56d364\")`."""),
    SlateApiEntry("DateField", "Widgets", "DateField(default; label)", """A date input. `@bind d DateField(\"2026-01-01\")`."""),
    SlateApiEntry("TimeField", "Widgets", "TimeField(default; label)", """A time input. `@bind t TimeField(\"09:00\")`."""),
    SlateApiEntry("Button", "Widgets", "Button(label=\"Click\")",
        """An action button; value is the click count (Int, 0,1,2,…). Drive an action with `@onclick`.
        `@bind go Button(\"Run\")`."""),
    SlateApiEntry("playhead", "Widgets", "playhead(anim; label) -> driven control",
        """A DRIVEN control: an animation player pushes its current 1-based frame index here (no input
        of its own). `@bind t playhead(anim)` lets another cell react to playback —
        `frames[t]` / `\"t=\$t\"`. Playback never waits on Julia; updates are throttled."""),

    # ── Live / reactive ────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("reactive", "Live", "reactive(:name, init) -> live value",
        """A live value you push to over time: `level = reactive(:level, 0)`; `level[]` reads,
        `level[] = v` pushes to every cell that reads it (re-renders live, no manual refresh)."""),
    SlateApiEntry("@onclick", "Live", "@onclick button begin … end",
        """Run a body when a Button is clicked (a NEW click cancels the still-running prior run). The
        cell does NOT recompute — the handler fires directly.
        ```julia
        @onclick go for v in 0:2:100; level[] = v; pause(0.1) end
        ```"""),
    SlateApiEntry("@onchange", "Live", "@onchange control (body)",
        """Run a body on each change of a control; the new value is bound and the cell does NOT
        recompute. `@onchange n (level[] = n)`."""),
    SlateApiEntry("pause", "Live", "pause(seconds)",
        """A CANCELLABLE sleep for use inside `@onclick`/`@onchange` bodies — a new click or `cancel`
        stops the run at its next `pause`. `pause(0.1)`."""),
    SlateApiEntry("cancel", "Live", "cancel(:name)",
        """Cooperatively stop a running `@onclick` handler (it stops at its next `pause`). `cancel(:level)`."""),

    # ── Tables ─────────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("slate_table", "Tables", "slate_table(df; …) -> interactive table",
        """Render a DataFrame / table as an interactive sortable, filterable, paged table (server-paged
        for big data). Just return it from a cell. `slate_table(df)`."""),
    SlateApiEntry("slate_query", "Tables", "slate_query(…) -> paged provider",
        """A server-paged table provider for large/lazy data — only the visible page crosses the wire."""),

    # ── Progress ───────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("slate_progress", "Progress", "slate_progress(frac; msg=\"\", id=\"\", done=false)",
        """Report progress (0..1) from a running cell — drives the cell's progress bar + the floating
        run chip. `@progress`/`@withprogress` loops also drive it automatically.
        `for i in 1:n; slate_progress(i/n; msg=\"step \$i\"); end`."""),

    # ── Cell tags (header) ─────────────────────────────────────────────────────────────────────────
    SlateApiEntry("cell tags", "Cell tags", "#%% code id=… <tag> …    (or the 🏷 tag editor)",
        """Per-cell tags travel in the `#%%` header (set them with the 🏷 button in the cell header, or
        an explicit header token). Behaviour tags: `collapsed` (fold the cell), `hidecode` (hide the
        editor, show output), `trace` (wrap in @trace — inspect every value), `nocache` (opt OUT of
        durable memoization — for impure / side-effecting cells). Presentation tags: `slide` (force a
        new slide), `notes` (speaker notes, presenter-only). Document-metadata ROLE tags: `title`,
        `abstract`, `bibliography` (see "front matter"). Any other token is a free-form tag that
        round-trips. Expensive cells (≥400 ms) are otherwise auto-cached to disk and RESTORED after a
        restart instead of recomputing."""),

    # ── Document metadata (front matter) ─────────────────────────────────────────────────────────────
    SlateApiEntry("front matter", "Document", "#%% md id=… title | abstract | bibliography",
        """A notebook is also a PUBLISHABLE document. Author metadata as ordinary cells carrying a ROLE
        tag, in natural reading order; every export target (article PDF, slide deck, HTML) interprets the
        role for placement.
          • `title` — its markdown is the title block: `# Title`, then `## `/`### ` subtitle, then the
            first plain line as the byline. Hoisted to the top on export.
          • `abstract` — hoisted into the title block (academic abstract).
          • `bibliography` — its body is either embedded BibTeX (`@book{key, …}`) OR one-or-more `.bib`
            file paths (one per line), resolved relative to the notebook and copied into the export.
            Inline + external can be mixed; in the live UI it renders an adaptive references card.
        A legacy `---` YAML front-matter block on the first markdown cell still works. Per-notebook
        citation style is `bibstyle` (Settings → Citation style): ieee/apa/chicago-author-date/mla/
        nature/vancouver/harvard."""),
    SlateApiEntry("citation", "Document", "[@key] · [@key, p. 7] · [@a; @b] · @key (prose)",
        """Cite a bibliography key in MARKDOWN prose. Forms: `[@key]` (normal) · `[@key, pp. 33-35]`
        (page/locator) · `[@a; @b]` (multiple) · bare `@key` (prose form: "Knuth (1984)" — for an
        author-year mention; only converts keys actually defined, so emails stay literal). Typing `[@`
        in a markdown cell autocompletes keys. Export renders linked citations + a References list in
        the chosen `bibstyle`; the live notebook shows a references card with cited keys highlighted."""),
    SlateApiEntry("@trace", "Cell tags", "@trace begin … end   (or the `trace` cell tag)",
        """Inspect every intermediate value in a cell — each line's value is collected into a trace
        table. Usually toggled via the cell's 🔍 button / `trace` tag rather than written by hand."""),
]

# ── Renderers ──────────────────────────────────────────────────────────────────────────────────
# Records for the semantic index: one per entry, module "Slate" so module-scoped search includes them.
slate_api_records() = [Dict{String,Any}("module" => "Slate", "name" => e.name,
                                        "doc" => string(e.signature, "\n\n", e.doc)) for e in SLATE_API]

# A content hash so the auto-indexer re-indexes only when the API docs actually change.
slate_api_version() = string(hash(slate_api_records()); base = 16)

_api_categories() = unique(String[e.category for e in SLATE_API])

# Resolve ONE Slate helper by exact name (case-insensitive; tolerant of a leading `@`). The docs UI's
# drill-down / "Related" cross-references resolve a Slate helper's docs from THIS registry (the SSOT),
# NOT from a live binding — a DSL helper like `Checkbox`/`@bind` is an injected constructor/macro with
# no docstring, so a live `module_help` lookup returns "No documentation found". Returns the entry or
# `nothing` (caller then falls back to live package help).
function slate_api_entry(name::AbstractString)
    n = lowercase(strip(String(name)))
    isempty(n) && return nothing
    for e in SLATE_API
        lowercase(e.name) == n && return e
    end
    ns = lstrip(n, '@')
    for e in SLATE_API
        lowercase(lstrip(e.name, '@')) == ns && return e
    end
    return nothing
end

# Full reference (topic empty) or the matching entries (topic = a name/category/word). The full form
# groups by category with signatures + docs; the filtered form returns the complete entry detail.
function slate_api_reference(topic::AbstractString = "")
    t = strip(lowercase(String(topic)))
    io = IOBuffer()
    if isempty(t)
        println(io, _SLATE_CHEATSHEET)
        println(io, "\n---\n# Full reference\n")
        println(io, "Drill into any helper with `slate.api(\"name\")`; search them with ",
                    "`slate.search_docs(\"…\")` (module \"Slate\").\n")
        for cat in _api_categories()
            println(io, "## ", cat)
            for e in SLATE_API
                e.category == cat || continue
                println(io, "\n### ", e.name, "\n`", e.signature, "`\n\n", e.doc)
            end
            println(io)
        end
        return String(take!(io))
    end
    hits = [e for e in SLATE_API if occursin(t, lowercase(e.name)) || occursin(t, lowercase(e.category)) ||
                                     occursin(t, lowercase(e.doc))]
    isempty(hits) && return "No Slate API entry matches \"$topic\". Try `slate.api()` for the full reference, " *
                            "or `slate.search_docs(\"$topic\")`."
    for e in hits
        println(io, "### ", e.name, "  (", e.category, ")\n`", e.signature, "`\n\n", e.doc, "\n")
    end
    return String(take!(io))
end

# Concise cheatsheet inlined in the agent system prompt every turn (kept short on purpose; the full
# per-helper reference is `slate.api()` + `slate.search_docs`).
const _SLATE_CHEATSHEET = """
# Kaimon Slate notebook API (cheatsheet)

Cells run in a REACTIVE notebook: a cell that READS a variable re-runs when that variable changes;
the LAST expression is DISPLAYED. These helpers are injected into every cell (Slate-specific — NOT in
package docs). Full reference: `slate_api()`. Search any helper (incl. `@bind`, `animate`): `slate_search_docs` (module "Slate").

## Display
Return the value to show — a number / String / DataFrame, a CairoMakie figure, `echart(…)`,
`slate_table(df)`, or `animate(frames; …)`. `println` → stdout; a trailing `;` makes a cell quiet.

## Charts — `echart` (Slate's ECharts DSL; NOT Makie's `series`).  Full reference: `slate_api("echart")`
    echart(:line, x, y; title="…", smooth=true)            # Express; kinds: line bar area scatter pie
    #   heatmap(z|xs,ys,z) candlestick(dates,ohlc) radar(inds,vals) boxplot(cats,data) gauge funnel … (+ any raw type)
    echart(:line, x, y; yAxis=(type=:log,))                # LOG axis. Top-level component kwargs (xAxis yAxis
    #   grid dataZoom visualMap toolbox polar radar geo …) go on the OPTION even in Express; other kwargs style the series
    echart(:bar, x, a; stack="total", markLine=(data=[(type=:average,)],))     # series styling passes through
    echart(series(:line, x, a; name="a"), series(:bar, x, b; name="b"); legend=true)   # Composable — many series
    echart(; xAxis=(type=:category, data=x), series=[(type=:bar, data=b)])     # Raw — full ECharts option surface

## Widgets — `@bind name Widget(…)`  (any cell that READS the var recomputes on change)
    @bind n Slider(1:100; label="n");  @bind on Toggle(true);  @bind which Radio(["sin"=>"sine"])
    Select/MultiSelect/MultiCheckBox/Checkbox/NumberField/TextField/TextArea/ColorPicker/DateField/TimeField
    @bind go Button("Run")                                  # value = click count

## Animation — `animate(frames; …)`  (precompute once, play in the browser)
    anim = animate([field(t) for t in times]; kind=:heatmap, clim=:symmetric, x=r, y=r)
    @bind t playhead(anim)                                  # react to the current frame elsewhere

## Live / async
    level = reactive(:level, 0)        # level[] reads, level[] = v pushes to readers
    @onclick go (for v in 0:100; level[]=v; pause(0.1) end)   # pause = cancellable; cancel(:level) stops
    @onchange n (level[] = n)          # runs on change; cell does NOT recompute

## Tables — `slate_table(df)`   ·   Progress — `slate_progress(frac; msg)`

## Cell tags (🏷 in the cell header, or `#%%` header tokens, e.g. `#%% md id=abs abstract`)
    collapsed · hidecode · trace · nocache (skip durable caching) · plus free-form tags.
    Presentation: slide (force a new slide) · notes (speaker notes — presenter view only).
    Document metadata (ROLES): title · abstract · bibliography. Expensive cells (≥400ms) auto-cache.

## Document metadata = role-tagged cells (publishable PDF / slides / HTML)
A notebook is also a publishable document. Tag ordinary cells with a ROLE; exports interpret it:
    #%% md id=ttl title         # H1=title, ## / ### = subtitle, first plain line = byline
    #%% md id=abs abstract      # hoisted into the title block on export
    #%% md id=refs bibliography # BibTeX entries, OR a line that is a `.bib` path (embedded or external)
Cite in markdown prose: `[@key]` · `[@key, p. 7]` (locator) · `[@a; @b]` (multiple) · bare `@key`
(prose: "Knuth (1984)"). Export PDF/slides/HTML renders linked citations + a References list
(style via Settings → Citation style / `bibstyle`).

## Slides (presentation mode)
A `##` heading starts a slide (level configurable); `slide`/`notes` tags give explicit control.
Present in the browser (▶ Present) or Export PDF (slides) — a 16:9 deck.

Worked examples: `examples/echarts_dsl.jl`, `examples/binds_demo.jl`, `examples/frontmatter_demo.jl`.
"""
