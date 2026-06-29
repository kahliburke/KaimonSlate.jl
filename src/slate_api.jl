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
    SlateApiEntry("echart", "Charts", "echart(kind, x, y; title, smooth, …) | echart(series...; …) | echart(; xAxis=…, series=…)",
        """Slate's ECharts chart DSL (NOT Makie's `series`). Renders live and animates in place on
        updates. Three forms — Express (one series), Composable (many `series(...)`), and Raw (the
        full ECharts option surface). Kinds: line bar scatter area pie heatmap candlestick radar
        boxplot gauge funnel … (plus any raw type).
        ```julia
        echart(:line, x, y; title="f", smooth=true)
        echart(series(:line, x, a; name="a"), series(:bar, x, b; name="b"); legend=true)
        echart(; xAxis=(type=:category, data=x), series=[(type=:bar, data=b)], dataZoom=[(type=:slider,)])
        ```"""),
    SlateApiEntry("series", "Charts", "series(kind, x, y; name, …) -> EChartSeries",
        """One series for the composable `echart(series..., series...; …)` form. Combine different
        kinds in one chart. `echart(series(:bar, x, a; name=\"a\"), series(:line, x, b; name=\"b\"))`."""),

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
        an explicit header token). Built-in: `collapsed` (fold the cell), `hidecode` (hide the editor,
        show output), `trace` (wrap in @trace — inspect every value), `nocache` (opt OUT of durable
        memoization — for impure / side-effecting cells). Any other token is a free-form tag that
        round-trips. Expensive cells (≥400 ms) are otherwise auto-cached to disk and RESTORED after a
        restart instead of recomputing."""),
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

## Charts — `echart` (Slate's ECharts DSL; NOT Makie's `series`)
    echart(:line, x, y; title="…", smooth=true)            # kinds: line bar scatter area pie heatmap …
    echart(series(:line, x, a), series(:bar, x, b); legend=true)
    echart(; xAxis=(type=:category, data=x), series=[(type=:bar, data=b)])

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

## Cell tags (🏷 in the cell header, or `#%%` header tokens)
    collapsed · hidecode · trace · nocache (skip durable caching) · plus free-form tags.
    Expensive cells (≥400ms) auto-cache to disk and RESTORE after a restart (tag `nocache` to opt out).

Worked examples: `examples/echarts_dsl.jl`, `examples/binds_demo.jl`.
"""
