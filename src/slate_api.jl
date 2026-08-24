# Part of NotebookServer — the SINGLE SOURCE OF TRUTH for Slate's notebook API (the helpers injected
# into every cell: echart, @bind + widgets, animate, reactive/@onclick, slate_table, slate_progress,
# cell tags …). These are NOT in package docstrings, so they're documented HERE and fed to three
# consumers, all from this one registry:
#   • the `slate.api` tool — `slate_api_reference()`: an INDEX by default, one or more entries in
#     full when given names, and the whole reference on `("all")`;
#   • semantic search — `slate_api_records()` is indexed into `slate_docs` (module "Slate"), so
#     `slate.search_docs("@bind")` finds these helpers alongside package docs;
#   • the agent system prompt — `_SLATE_CHEATSHEET`, rendered from this registry, is inlined every turn.
# Add or change a helper? Edit the entry here and all three stay in sync.
#
# Each entry has TWO tiers, and the split is the point: a one-line `summary` + routing `keywords` for
# the cheap index surfaces, and the full `doc`/`docbinding` behind an explicit drill-down. The index
# is lossy ON PURPOSE — it names what exists so the reader knows to ask, and withholds enough that
# writing a call from it isn't tempting. `test_slate_api.jl` fails if a helper injected into the cell
# namespace never reaches this registry, which is what keeps "what exists" honest.

"""
One documented Slate helper.

`summary` + `keywords` drive the cheap INDEX surfaces (the `slate.api` table of contents and the
cheatsheet inlined in the agent prompt); `signature` + `doc` (or `docbinding`) drive the full
per-helper detail. The split is deliberate: an index line says a helper EXISTS and what it is for,
and is lossy on purpose so an agent drills in rather than guessing from a summary.

`keywords` are ROUTING terms — the words someone would search for who doesn't know the helper's
name ("log axis" → `echart`, "clickable row" → `TableSelect`). They need not appear in the docs.
"""
struct SlateApiEntry
    name::String
    category::String
    summary::String              # ONE line for the index: what it is, why you'd reach for it
    keywords::Vector{String}     # routing terms for a name-blind lookup (never rendered as prose)
    signature::String
    doc::String          # markdown fallback: a sentence or two + at least one example
    docbinding::Union{Nothing,Base.Docs.Binding}   # a REAL function whose own docstring is the SSOT
end
# Most helpers are injected DSL constructs with no reachable docstring → the registry `doc` IS the
# source. A few (`slate_table`, `slate_query`, …) are real exported functions: point `docbinding` at
# them and their OWN docstring drives the api tool / search / prompt, so the two can never drift.
SlateApiEntry(name, category, summary, keywords, signature, doc) =
    SlateApiEntry(name, category, summary, keywords, signature, doc, nothing)
# Backed ENTIRELY by a real function's own docstring — no signature or prose duplicated here. The
# docstring (which leads with its own signature lines) is the single source rendered everywhere.
# The index summary still lives here: a docstring's first line is too long (and too variable) to
# make a scannable index line.
SlateApiEntry(name, category, summary, keywords, binding::Base.Docs.Binding) =
    SlateApiEntry(name, category, summary, keywords, "", "", binding)

# The markdown shown for an entry: a real function's own docstring when `docbinding` is set and it
# carries one, else the registry `doc`. Empty only if a binding entry's function somehow lost its doc.
function _entry_doc(e::SlateApiEntry)
    b = e.docbinding
    b === nothing && return e.doc
    return Base.Docs.hasdoc(b.mod, b.var) ? strip(string(Base.Docs.doc(b))) : e.doc
end

# The one-line signature for the reference/index. Registry entries carry their own; binding-backed
# entries have none of their own (the docstring already leads with the signature), so return "" and
# renderers skip the separate signature line.
_entry_signature(e::SlateApiEntry) = e.signature

# One entry rendered to markdown: its `signature` (if any) then its doc — the live docstring for
# binding-backed entries, the registry `doc` otherwise. Shared by the api tool, the filtered form,
# and the docs drill-down so every surface shows exactly the same text.
function _entry_markdown(e::SlateApiEntry)
    sig = _entry_signature(e)
    doc = _entry_doc(e)
    isempty(sig) ? doc : string("`", sig, "`\n\n", doc)
end

const SLATE_API = SlateApiEntry[
    # ── Display ──────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("display", "Display",
        "The cell's LAST expression renders; a trailing `;` silences it. Cells are REACTIVE.",
        ["output", "show", "return", "render", "print"],
        "<last expression of a cell>",
        """The cell's LAST expression is shown. Return a number / String / DataFrame, a CairoMakie
        figure, an `echart(…)`, a `slate_table(df)`, or an `animate(…)`. `println` writes stdout. A
        trailing `;` makes the cell quiet (no value shown). Cells are REACTIVE: a cell that READS a
        variable re-runs when that variable changes."""),

    # ── Charts ───────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("echart", "Charts",
        "Interactive chart DSL (ECharts) — the default for any plot you can zoom/pan/hover.",
        ["plot", "graph", "log axis", "zoom", "geo map", "heatmap", "pie", "scatter", "bar"],
        "echart(kind, x, y; title, smooth, yAxis=(type=:log,), …) | echart(series...; …) | echart(; xAxis=…, series=…)",
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
        - `:sankey` `(links)` or `(nodes, links)` — link `(source,target,value)` or `src=>tgt=>val`; nodes auto-derived
        - `:graph` `(edges)` or `(nodes, edges)` — edge `(source,target)` or `src=>tgt`; force-directed network
        - `:treemap` / `:sunburst` `(tree)` — hierarchy: `name=>value` leaf, `name=>[children…]` branch, or NamedTuple nodes
        - `:lines` `(from, to)` — geo trajectories/flows; coords `(lon,lat)`; binds `coordinateSystem="geo"` (see GEO MAPS)
        - `:calendar` `(dates, values)` — calendar heatmap; brings the calendar component + a `visualMap`
        - any other ECharts type via `series(:kind; data=…, …)` — gauge, funnel, tree, …

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

        DEFAULTS: the Slate palette theme (drawn from the active UI theme's colours) + transparent bg
        (`theme=false` to opt out); `tooltip=true`; a `legend` appears when ≥2 series are named
        (`legend=<spec>` to place it, `legend=false` to drop it); `title="…"`. Reactive charts
        re-`setOption` (~300 ms transition; `animation=false` to snap). To make MAKIE figures match this
        look, call `use_slate_theme!()` (needs Makie loaded) or `set_theme!(slate_theme())`.

        SIZE: `height=520` / `width="80%"` (px number or any CSS length) size the chart's box.

        GEO MAPS: `registerMap=(name="world", url="/assets/maps/world.json")` fetches + registers
        GeoJSON before render (Slate serves a vendored world map at that URL); then
        `geo=(map="world", roam=true)` plus series with `coordinateSystem="geo"` draw on real
        coastlines. NOTE `silent=true` on the geo kills roam (it swallows the mouse) — disable
        hover-highlight with `emphasis=(disabled=true,)` instead. Geo-bound and heatmap series
        default to `progressive=0` (ECharts' progressive layers keep a stale blit under a roaming
        coordinate system — the dots stop following the map); pass an explicit `progressive=N` to
        re-enable for huge data.
        Worked examples: `examples/echarts_dsl.jl`, `examples/seismic_month.jl`. See also `series`."""),
    # Real functions — documented in their own docstrings (echarts_dsl.jl / animation.jl).
    SlateApiEntry("zoom", "Charts",
        "Make a chart zoomable — ECharts does NOT zoom by default. `zoom=true` adds the gesture AND visible buttons.",
        ["zoom", "pan", "datazoom", "scroll", "magnify", "range", "slider", "toolbox", "reset"],
        "echart(…; zoom = true | :inside | :slider | :both)",
        """Make a chart zoomable. ECharts does **not** zoom at all unless a `dataZoom` component is
declared, and `dataZoom=[(type="inside",)]` alone is a trap: it is invisible (Slate also gates the
wheel behind click-to-activate so a chart can't hijack page scroll), and once zoomed there is no
way back. `zoom = true` gives the gesture plus the affordances that make it usable.
- `true` / `:buttons` — gesture + toolbox (zoom to a region · undo · reset)
- `:inside` — the gesture only  ·  `:slider` — a range bar  ·  `:both`
Applies to EVERY x axis, so a multi-panel chart (a plot over its residual) zooms as one thing. An
explicit `dataZoom`/`toolbox` always wins."""),
    SlateApiEntry("valuefmt", "Charts",
        "Number formatting for a chart's TOOLTIP — the same format vocabulary `slate_table` uses.",
        ["format", "decimals", "digits", "tooltip", "rounding", "scientific", "percent", "currency",
         "units", "precision"],
        "echart(…; valuefmt = :fixed)  ·  valuefmt = (kind = :fixed, digits = 5)",
        """Number formatting for a chart's tooltip. ECharts prints whatever it was handed, so small
or wide-ranging values arrive as a mix of `0.000317515` and `5.789e-5` in one column. `valuefmt`
takes the SAME spec as `slate_table(…; format=…)` — presets `:fixed :scientific :percent :integer
:currency :bytes`, or `(kind, digits, sep, prefix, suffix)` — and applies it with the same
renderer, so a number reads identically in a table cell and a chart tooltip.
```julia
echart(:line, x, y; valuefmt = (kind = :fixed, digits = 5))
echart(series(:line, x, a; valuefmt = :percent),      # per series wins over top-level —
       series(:line, x, b; valuefmt = :currency))     # for a mixed-unit chart
```
Note a JS function CANNOT be passed here (or to any `formatter`): an option is serialised to JSON
with no reviver, so a function-shaped string arrives as a string, and ECharts calling it throws on
every tooltip update — which wedges the crosshair rather than failing visibly. `valuefmt` exists
precisely because that route doesn't work."""),
    SlateApiEntry("series", "Charts",
        "One named series of a multi-series `echart` (mixed kinds, dual axes).",
        ["overlay", "legend", "multiple", "dual axis"],
        Base.Docs.Binding(ReportEngine, :series)),

    SlateApiEntry("use_slate_theme!", "Charts",
        "Make MAKIE figures match the interactive `echart` look (shared palette + transparent bg).",
        ["makie", "theme", "palette", "dark", "match", "consistent"],
        Base.Docs.Binding(ReportEngine, :use_slate_theme!)),
    SlateApiEntry("slate_theme", "Charts",
        "The Slate look as a Makie `Theme` — `set_theme!(slate_theme())`, or a local override.",
        ["makie", "theme", "palette", "colours"],
        Base.Docs.Binding(ReportEngine, :slate_theme)),

    # ── Animation ── real function, documented in its own docstring (animation.jl) ─────────────────
    SlateApiEntry("animate", "Animation",
        "Precompute frames once, play them in the browser with a scrubber.",
        ["movie", "frames", "playback", "time series", "evolution"],
        Base.Docs.Binding(ReportEngine, :animate)),

    # ── Widgets (@bind) ────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("@bind", "Widgets",
        "Declare a reactive input control; every cell that READS the var recomputes on change.",
        ["widget", "control", "input", "interactive", "knob", "parameter"],
        "@bind name Widget(…)",
        """Declare a reactive input control: `name` holds the live value, and any cell that READS
        `name` recomputes when the control changes. Widgets: Slider, NumberField, Checkbox, Toggle,
        TextField, TextArea, Select, Radio, MultiSelect, MultiCheckBox, ColorPicker, DateField,
        TimeField, Button, TableSelect, playhead. `@bind n Slider(1:100; label=\"n\")`. Group several
        related controls in ONE cell (multiple `@bind` lines → a single combined control strip)
        rather than a cell per control.

        Two placement patterns: EMBED — put the `@bind` in the SAME cell that reads it, and its widget
        renders right there (best for a control local to one plotting cell). SURFACE — declare the
        `@bind`s once (e.g. a hidden `hidecode` setup cell) and place the live knobs BESIDE a figure
        with `slate.surface(notebook, plotcell, \"a,b\")` (layout grammar: `a,b`=row, `[a,b],c`=columns;
        `\"\"` clears). Presentation only — no re-eval. Prefer surfacing so a reader tweaks the knobs
        next to the figure they drive."""),
    SlateApiEntry("Slider", "Widgets", "A range slider.", ["number", "range", "drag"],
        "Slider(range; default, label) | Slider(lo, hi, default; step, label)",
        """A range slider. `@bind n Slider(1:100; label=\"n\")` or `@bind x Slider(0.0, 1.0, 0.5; step=0.01)`."""),
    SlateApiEntry("NumberField", "Widgets", "A numeric input box.", ["number", "spinner", "entry"],
        "NumberField(default=0; min, max, label)",
        """A numeric input box. `@bind k NumberField(10; min=0, max=100)`."""),
    SlateApiEntry("Checkbox", "Widgets", "A boolean checkbox.", ["bool", "flag", "on off"],
        "Checkbox(default=false; label)",
        """A boolean checkbox. `@bind on Checkbox(true)`."""),
    SlateApiEntry("Toggle", "Widgets", "A boolean toggle with optional on/off labels.",
        ["bool", "switch", "flag"], "Toggle(default=false; label, on, off)",
        """A boolean toggle with optional on/off labels. `@bind live Toggle(true; on=\"Live\", off=\"Paused\")`."""),
    SlateApiEntry("TextField", "Widgets", "A single-line text input.", ["string", "entry", "name"],
        "TextField(default=\"\"; label)",
        """A single-line text input. `@bind name TextField(\"hi\")`."""),
    SlateApiEntry("TextArea", "Widgets", "A multi-line text input.", ["string", "prose", "paragraph"],
        "TextArea(default=\"\"; rows=3, label)",
        """A multi-line text input. `@bind note TextArea(\"\"; rows=5)`."""),
    SlateApiEntry("Select", "Widgets", "A dropdown; options may be bare values or `value => label`.",
        ["dropdown", "choice", "menu", "pick one"], "Select(options, default; label)",
        """A dropdown. Options are bare values or `value => label` pairs (the bound var takes `value`;
        `.label` reaches the label). `@bind f Select([\"sin\"=>\"sine\", \"cos\"=>\"cosine\"])`."""),
    SlateApiEntry("Radio", "Widgets", "A radio group (rich / \$math\$ labels render).",
        ["choice", "option", "exclusive"], "Radio(options, default; label)",
        """A radio group (rich/`\$math\$` labels rendered). `@bind which Radio([1=>\"one\", 2=>\"two\"])`."""),
    SlateApiEntry("MultiSelect", "Widgets", "A multi-select listbox; the value is a Vector.",
        ["many", "list", "subset", "columns"], "MultiSelect(options, default=[]; label)",
        """A multi-select listbox; the bound value is a Vector. `@bind picks MultiSelect(cols)`."""),
    SlateApiEntry("MultiCheckBox", "Widgets", "A checkbox list for small discrete sets; value is a Vector.",
        ["many", "flags", "subset"], "MultiCheckBox(options, default=[]; label)",
        """A checkbox list (small discrete sets); value is a Vector. `@bind picks MultiCheckBox([:a,:b,:c])`."""),
    SlateApiEntry("ColorPicker", "Widgets", "A colour picker; the value is a hex String.",
        ["colour", "hex", "palette"], "ColorPicker(default=\"#3aa0ff\"; label)",
        """A color picker; value is a hex String. `@bind c ColorPicker(\"#56d364\")`."""),
    SlateApiEntry("DateField", "Widgets", "A date input.", ["calendar", "day", "when"],
        "DateField(default; label)", """A date input. `@bind d DateField(\"2026-01-01\")`."""),
    SlateApiEntry("TimeField", "Widgets", "A time input.", ["clock", "hour", "when"],
        "TimeField(default; label)", """A time input. `@bind t TimeField(\"09:00\")`."""),
    SlateApiEntry("RangeSlider", "Widgets",
        "A slider with TWO thumbs; binds an interval as a `(lo, hi)` NamedTuple.",
        ["range", "interval", "span", "between", "two", "window", "min max", "region", "limits"],
        "RangeSlider(range; default, label)",
        """A slider with two thumbs, binding an interval as a `(lo, hi)` NamedTuple. For a span
where the two ends are ONE decision (a region of a signal, a date window, axis limits) — two
separate sliders let the reader cross them; this cannot be put into that state.
```julia
@bind span RangeSlider(400:4000; default = (1500, 1800), label = "region")
lo, hi = span            # destructures  ·  span.lo / span.hi by name
```"""),
    SlateApiEntry("FileUpload", "Widgets",
        "A file the READER supplies; binds an `UploadedFile` with a real `.path` under `datadir()`.",
        ["upload", "file", "csv", "import", "attach", "drop", "browse", "data"],
        "FileUpload(; accept, label, maxbytes)",
        """A file the READER supplies (browse or drag-and-drop). The bytes are stored under the
notebook's `datadir()` and the control binds an `UploadedFile` — `.path` (a real path you can
`CSV.read`), `.name`, `.size`, `.mime` — so reader cells recompute exactly as for any other
control. `nothing` until something is uploaded. `accept` is the picker filter (`".csv"`), a
convenience not a guarantee — validate what you got. `maxbytes` caps the size.
```julia
@bind datafile FileUpload(; accept = ".csv", label = "Data")
datafile === nothing ? md"Upload a file to begin." : CSV.read(datafile.path, DataFrame)
```"""),
    SlateApiEntry("Button", "Widgets", "An action button; the value is the click count. Pair with `@onclick`.",
        ["click", "trigger", "run", "action", "go"], "Button(label=\"Click\")",
        """An action button; value is the click count (Int, 0,1,2,…). Drive an action with `@onclick`.
        `@bind go Button(\"Run\")`."""),
    SlateApiEntry("TableSelect", "Widgets",
        "A clickable table — binds the CLICKED ROW as a NamedTuple (`sel.price`).",
        ["row", "pick", "dataframe", "selection", "drill down"],
        "TableSelect(data; default, label, maxrows=200)",
        """A clickable table: renders `data` (a DataFrame / Tables.jl source / Vector of NamedTuples —
        anything `slate_table` takes) and binds the CLICKED ROW as a NamedTuple with a field per column.
        No selection → `nothing`. `@bind sel TableSelect(df)` then `sel.price` / `sel.name` downstream."""),
    SlateApiEntry("custom_widget", "Widgets",
        "Bind a control of a THIRD-PARTY kind — the Julia half of the widget extension point.",
        ["extension", "plugin", "package", "third party", "register", "custom control"],
        "custom_widget(kind, default=\"\"; params...)",
        """The escape hatch from the built-in widget list: `kind` is any string, and its `params` cross
        to the browser as the widget spec. Pair it with a front-end `slateRegisterWidget("<kind>", …)`
        that renders and wires the control — which is how an external package adds a control Slate has
        never heard of, without Slate knowing about the package.
        ```julia
        @bind ans custom_widget("mathfield"; label = "your answer")
        ```
        The value round-trips through the identity coercion (an unknown kind passes through untouched),
        so a string-valued custom widget needs no server-side support at all. A package can also
        register a real per-kind coercion through the same seam the built-ins use — see
        SlateExtensionsBase. Otherwise it behaves exactly like any `@bind` control."""),
    SlateApiEntry("@replay", "Widgets",
    "Mark an expression as answerable WITHOUT a kernel, so its control keeps working in a static export.",
    ["offline", "export", "standalone", "bind", "precompute", "no kernel", "interactive"],
    "@replay control expr",
    """Mark `expr` as computable across `control`'s whole domain, so the control still works in a
    **standalone export**, where there is no Julia to recompute anything.

    ```julia
    @bind w Slider(1:2:15)
    Plot(scatter(x = xs, y = @replay(w, movavg(infl, w))))
    ```

    LIVE this is a pass-through: only the control's current value is computed, so the cell costs exactly
    what the bare expression costs. The macro's job is to leave behind a MARK. At EXPORT time Slate
    evaluates the expression once per value the control can take, packs the results as one binary array,
    and ships it — moving the control then indexes shipped data instead of calling Julia.

    You never restate the domain: it is read from the control, so it cannot drift. You never name a trace
    or a field either — the value is an ordinary array, and the renderer finds it wherever you put it.

    REQUIREMENTS: the control must have a finite domain, and `expr` must return a numeric array of the
    same shape for every value. Both are checked as you write the cell, not at export.

    Every control whose domain can be enumerated qualifies, which is more of them than it sounds:

      `Slider` `Select` `Radio` `Checkbox` `Toggle`  — the value itself
      `RangeSlider`   — ordered `(lo, hi)` pairs, so n stops give n(n+1)/2 positions (not n²)
      `TableSelect`   — its ROWS; the swept value is the row NamedTuple, exactly as live
      `MultiSelect` / `MultiCheckBox` — the power set of the options
      `NumberField`   — when you bounded it with `min`/`max`

    Refused: free text, a date, a colour, an unbounded number field — and a *combinatorial* domain past
    ~20 000 positions (a range slider beyond ~200 stops, a multi-select beyond ~14 options), which is a
    size nothing should enumerate. Coarsen the control's own `step`, or offer fewer options.

    The swept value is the one a CELL sees, not the wire value — `@replay(sel, f(sel.product))` over a
    `TableSelect` gets row NamedTuples, and `@replay(span, g(span.lo, span.hi))` gets the pair.

    A `@replay` cell is never restored from the durable cache — the mark is established by RUNNING, so a
    restored cell would export a control with no data behind it.

    The export dialog shows what each mark will cost and offers a **resolution** (ship every n-th
    position) for the controls that sweep ONE number — a slider or a bounded number field. A categorical
    or composite domain is never strided: there is no coarser version of a choice.
    See also `@bind`, `save_asset`."""),
SlateApiEntry("playhead", "Widgets",
        "A DRIVEN control: an animation player pushes its current frame index here.",
        ["frame", "scrub", "player", "time"], "playhead(anim; label) -> driven control",
        """A DRIVEN control: an animation player pushes its current 1-based frame index here (no input
        of its own). `@bind t playhead(anim)` lets another cell react to playback —
        `frames[t]` / `\"t=\$t\"`. Playback never waits on Julia; updates are throttled."""),

    # ── Live / reactive ────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("reactive", "Live",
        "A live value you PUSH to over time; reader cells re-render with no recompute.",
        ["stream", "live", "observable", "update", "progress", "monitor"],
        "reactive(:name, init) -> live value  ·  @reactive name = init",
        """A live value you push to over time: `level = reactive(:level, 0)`; `level[]` reads,
        `level[] = v` pushes to every cell that reads it (re-renders live, no manual refresh). The
        `:name` MUST match the variable — it routes the refresh to the cells that read `name`. Prefer
        the sugar `@reactive level = 0` (= `level = reactive(:level, 0)`), which derives the name from
        the binding so it can never drift."""),
    SlateApiEntry("@onclick", "Live",
        "Run a body when a Button is clicked — the cell does NOT recompute.",
        ["handler", "event", "action", "button"], "@onclick button begin … end",
        """Run a body when a Button is clicked (a NEW click cancels the still-running prior run). The
        cell does NOT recompute — the handler fires directly.
        ```julia
        @onclick go for v in 0:2:100; level[] = v; pause(0.1) end
        ```"""),
    SlateApiEntry("@onchange", "Live",
        "Run a body on each change of a control — the cell does NOT recompute.",
        ["handler", "event", "watch"], "@onchange control (body)",
        """Run a body on each change of a control; the new value is bound and the cell does NOT
        recompute. `@onchange n (level[] = n)`."""),
    SlateApiEntry("pause", "Live", "A CANCELLABLE sleep, for use inside `@onclick`/`@onchange` bodies.",
        ["sleep", "delay", "wait", "throttle"], "pause(seconds)",
        """A CANCELLABLE sleep for use inside `@onclick`/`@onchange` bodies — a new click or `cancel`
        stops the run at its next `pause`. `pause(0.1)`."""),
    SlateApiEntry("cancel", "Live", "Cooperatively stop a running `@onclick` handler.",
        ["stop", "abort", "interrupt", "kill"], "cancel(:name)",
        """Cooperatively stop a running `@onclick` handler (it stops at its next `pause`). `cancel(:level)`."""),
    SlateApiEntry("Cancelled", "Live",
        "The exception a cancelled handler unwinds with — lets a `catch` tell a stop from a failure.",
        ["cancel", "stop", "exception", "error", "catch", "interrupt"], "e isa Cancelled",
        """The exception type a handler unwinds with when it is cancelled — by `cancel(:name)`, or by a
        new click superseding the running one. Without it a `catch` cannot tell "the reader pressed
        Stop" from "the computation failed", and reports the reader's own action as an error:
        ```julia
        @onclick fit begin
            busy[] = true
            try
                result[] = expensive(x)          # written LAST: reaching it means we finished
            catch e
                msg[] = e isa Cancelled ? "Stopped." : "Failed: " * sprint(showerror, e)
            finally
                busy[] = false                   # runs even when cancelled — see below
            end
        end
        ```
        Every reactive write is a cancellation checkpoint, so a cancelled handler throws at the FIRST
        write after the cancel — which is why anything you don't want discarded (here `result`) goes
        last. The checkpoint fires only ONCE per run, so writes in `catch`/`finally` still land and
        your cleanup (clearing a busy flag, a progress bar) always runs."""),
    SlateApiEntry("set_bind (in a cell)", "Live",
        "Drive one of the notebook's OWN `@bind` controls from cell code — the control moves with it.",
        ["set", "drive", "move", "control", "programmatic", "sync", "override", "select"],
        "set_bind(:name, value)",
        """Set a `@bind` from cell code. The control itself moves, its reader cells recompute, and
the value persists — it takes the SAME path a browser change takes, so a value set here is
indistinguishable from one the reader typed.
```julia
@onchange upload set_bind(:sample, "— uploaded file —")   # an upload takes over the picker
```
Use it when the app knows something the control doesn't yet: an upload that should override a
dropdown, a chart selection that should move its slider, a "reset" button. Without it a control can
sit visibly contradicting what the app is showing, with no way to correct it.
No-op if nothing declares `name`, and inert on a standalone run. Distinct from the AGENT tool
`slate.set_bind` below, which drives a control from OUTSIDE the notebook."""),
    SlateApiEntry("set_bind", "Live",
        "AGENT TOOL — drive a `@bind` from outside the browser (headless); omit `value` to CLICK a Button.",
        ["drive", "click", "headless", "test", "simulate", "agent"],
        "slate.set_bind(notebook, name; value=\"\")",
        """A `slate.*` AGENT TOOL (not a cell helper) — DRIVE a `@bind` from OUTSIDE the browser, the
        write-half of the reactive loop (`slate.read`/`slate.inspect` observe state; this CHANGES it).
        Routes through the same path as a browser change: coerces `value` against the widget, updates
        the registry, restales the reader cells, and fires any `@onclick`/`@onchange` handler — all
        HEADLESS (no open tab needed). `name` is the bound variable (e.g. \"njobs\"), NOT a cell id;
        `value` is JSON (a number \"42\", bool, string, or array). For a Button, OMIT `value`: a
        valueless set is a CLICK — the server increments the click count and fires the handler, so you
        never need to know (or race) it.
        `slate.set_bind(nb, \"njobs\", value=\"50\")` then `slate.set_bind(nb, \"launch\")`  # set a slider, then click a button."""),

    # ── Tables ─────────────────────────────────────────────────────────────────────────────────────
    # Real exported functions — documented ONCE in their own docstrings (tables.jl / paged.jl).
    SlateApiEntry("slate_table", "Tables",
        "Render tabular data — sortable, filterable, paged, per-column format/align/viz.",
        ["dataframe", "grid", "columns", "csv", "rows", "currency", "sparkline"],
        Base.Docs.Binding(ReportEngine, :slate_table)),
    SlateApiEntry("slate_query", "Tables",
        "Render a SQL query's result set as a live table.",
        ["sql", "duckdb", "database", "connection"],
        Base.Docs.Binding(ReportEngine, :slate_query)),
    SlateApiEntry("slate_matrix", "Matrices",
        "Render a Matrix explicitly (a bare Matrix already auto-renders).",
        ["array", "numeric", "grid", "linear algebra"],
        Base.Docs.Binding(ReportEngine, :slate_matrix)),

    # ── Session tools ──────────────────────────────────────────────────────────────────────────────
    # Real functions — documented once in their own docstrings (tools.jl).
    SlateApiEntry("slate_tool", "Session tools",
        "Call one of this session's gate tools (the ones an AGENT sees) and render the call.",
        ["mcp", "agent", "gate tool", "invoke", "extension verb", "tool call"],
        Base.Docs.Binding(ReportEngine, :slate_tool)),
    SlateApiEntry("@tool", "Session tools",
        "Call syntax for `slate_tool`: `@tool start_job(size = 4)`.",
        ["mcp", "agent", "call a tool", "invoke", "sugar"],
        "@tool name(arg = value, …)",
        """Sugar over [`slate_tool`](@ref), so a tool call reads the way its own documentation
        does, which is the form an agent would have used:
        ```julia
        @tool start_job(target = "MyPkg.Widget", size = 40)
        @tool list_jobs()
        ```
        Keyword arguments only. The value is a `ToolCall`, rendered as a panel showing the tool's
        FULL declared parameter list (type, required, and whether this call supplied it) beside
        the result — a wrong call is visible rather than merely failing.

        The point of writing a tool call as a cell is that agent actions become part of the
        document: durable, inspectable, and re-runnable, instead of happening off-page in a
        transcript nobody keeps."""),
    SlateApiEntry("slate_tools", "Session tools",
        "List the gate tools this session exposes, with parameter counts and summaries.",
        ["what tools", "available", "discover", "mcp", "agent", "registry"],
        Base.Docs.Binding(ReportEngine, :slate_tools)),
    SlateApiEntry("tool_handle", "Session tools",
        "The run id a background tool call returned, for threading into the next call.",
        ["run id", "job id", "handle", "background", "poll", "async", "status"],
        Base.Docs.Binding(ReportEngine, :tool_handle)),

    # ── Assets & front-end ─────────────────────────────────────────────────────────────────────────
    SlateApiEntry("@asset", "Assets & front-end",
        "Read a sibling file's CONTENTS as a TRACKED cell input — edit the file, the cell re-runs.",
        ["file", "include", "css", "js", "html", "watch", "source"],
        "@asset \"path\" -> String   ·   @asset bytes \"path\" -> Vector{UInt8}",
        """Read a sibling file's contents into the cell. The path resolves relative to the notebook's
        PROJECT dir (or an absolute path). Because the path is a SOURCE LITERAL, Slate can see the
        dependency WITHOUT running the cell and treats the file as a first-class cell INPUT — this is
        what makes the asset system reactive:
        - the cell's durable memo folds the file's content hash, so editing the file invalidates the
          cache (a changed asset never serves a stale cell);
        - a file-watcher RE-RUNS the reading cell (and its dependents) when the file changes on disk —
          the same lightweight live refresh as a `@bind` change (edit `app.css` → the page updates).

        `@asset bytes "logo.png"` returns raw `Vector{UInt8}` (images/binaries) instead of a String.
        Assets are ALSO served by a real URL under the notebook (`asset/<path>`), so front-end JS can
        `<script src="asset/app.js">` (cacheable, debuggable, source-mapped) rather than inlining.
        The primary use is feeding TRACKED source into `WebPage` / display HTML.
        ```julia
        WebPage(css=@asset("app.css"), js=@asset("app.js"), html=@asset("app.html"))  # edits stay live
        logo = @asset bytes "logo.png"        # raw bytes
        ```
        DYNAMIC caveat: a COMPUTED path can't be tracked statically — use `readfile(path)` for that
        (an escape hatch with no memo-invalidation and no watcher). Prefer `@asset "literal"` whenever
        the path is known at author time. See also `readfile`, `@use`, `WebPage`, `datadir`."""),
    SlateApiEntry("datadir", "Assets & front-end",
        "The notebook's portable data dir; `@sfile \"f.csv\"` is a PATH into it (read AND write).",
        ["path", "csv", "read", "write", "portable", "data file", "duckdb"],
        "datadir() -> String   ·   @sfile \"name\" -> String (path)",
        """The notebook's canonical DATA directory and portable references into it. `datadir()` returns
        `<project>/data` (created on demand) — a stable place to read AND write data files WITHOUT
        hardcoding a machine path, so the notebook stays portable between machines. `@sfile "flights.csv"`
        is sugar for `joinpath(datadir(), "flights.csv")` — it returns a PATH (contrast `@asset`, which
        reads a file's CONTENTS), so it suits big files and read/write data:
        ```julia
        df = CSV.read(@sfile("flights.csv"), DataFrame)     # read a data file by portable path
        CSV.write(@sfile("summary.csv"), result)            # write output to the same portable place
        con = DBInterface.connect(DuckDB.DB, @sfile("warehouse.duckdb"))
        ```
        Unlike `@asset`, `@sfile` is NOT folded into the memo key (it's a read/write store, not tracked
        source). Roadmap: files referenced here transfer content-addressed over the DATA CHANNEL to
        remote workers (the same transport as memo/boundary blobs — dedup-aware, fetched by sha on
        demand), so a notebook's data follows it across sites. See also `@asset`, `readfile`."""),
    SlateApiEntry("readfile", "Assets & front-end",
        "Untracked runtime read for a COMPUTED path — the escape hatch from `@asset`.",
        ["file", "dynamic path", "escape hatch"],
        "readfile(path; bytes=false) -> String | Vector{UInt8}",
        """The runtime escape hatch for `@asset` when the path is COMPUTED (not a literal Slate can
        extract). Same resolution — relative to the notebook's project dir, or absolute. UNLIKE
        `@asset`, it is NOT statically tracked: no memo-hash folding and no file-watcher, so a cell
        using `readfile` won't auto-recompute when the file changes and its cache can go stale. Reach
        for it only when the filename is dynamic; otherwise use `@asset "literal"`.
        ```julia
        cfg = readfile("configs/\$name.json")     # path depends on a variable → @asset can't see it
        ```"""),
    SlateApiEntry("@use", "Assets & front-end",
        "Declare a browser ES-module import (import map) so front-end JS can `import` it.",
        ["import", "esm", "cdn", "module", "d3", "npm"],
        "@use \"name\" => \"url\"    (or @use \"name\" \"url\")",
        """DECLARE a browser ES-module import at the NOTEBOOK level — the front-end counterpart of
        `@asset` (a JS module dep instead of a file dep). It's a runtime no-op: the literal pair is
        extracted statically and merged into the page's single `<script type=\"importmap\">`, injected
        in BOTH the live shell `<head>` and the static export `<head>`. So notebook front-end JS (in a
        `WebPage`, an `@asset`ed script, or inline) can `import` the bare specifier, live AND in an
        exported/published page. A NEW specifier reaches an already-open page too (the import map is
        extended in place); re-pointing one that page already declares needs a reload, since a
        specifier can't be redefined once the document declares it.
        ```julia
        @use \"d3\" => \"https://esm.sh/d3@7\"    # then, in front-end JS:  import * as d3 from \"d3\"
        ```"""),
    SlateApiEntry("WebPage", "Assets & front-end",
        "Compose ONE self-contained HTML page from CSS/HTML/JS strings (what a `web` cell builds).",
        ["html", "custom widget", "frontend", "javascript", "visualisation"],
        "WebPage(; html=\"\", css=\"\", js=\"\", obscure=false)",
        """Compose a self-contained HTML page from CSS/HTML/JS strings — RETURN it from a cell to render
        ONE `text/html` output (`<style>` + body + `<script>`). It behaves identically in the live
        notebook (its `<script>` is revived by the frontend) and in a static export/publish
        (self-contained — no external requests). Pass the pieces via `@asset` so the source files on
        disk stay TRACKED (edit → the cell re-runs, the memo won't serve stale) and remain plain and
        debuggable. `obscure=true` base64-packs the JS (trivially reversible, but keeps it out of a
        casual View-Source). Pairs with `@use` for bare-specifier imports.
        ```julia
        WebPage(css=@asset("app.css"), js=@asset("app.js"), html=@asset("app.html"))
        ```"""),

    # Real function — documented in its own docstring (capture.jl). Injected into cells as `save_asset`.
    SlateApiEntry("download_button", "Assets & front-end",
        "A button that saves a generated result to the READER's disk (live, standalone and published).",
        ["download", "save", "export", "csv", "results", "file", "give", "take away"],
        "download_button(name, data; label, mime)",
        """A button that saves a generated result to the reader's disk — `name` is the filename they
get. `data` is anything `save_asset` accepts (String, bytes, numeric array, JSON-able value). Works
live, in a standalone export and on a published page. The way a reader LEAVES with a result they
have no cell to run and no filesystem to look in.
```julia
io = IOBuffer(); CSV.write(io, results)
download_button("results.csv", String(take!(io)); label = "Download the results")
```
See also `save_asset`, `FileUpload`."""),
    SlateApiEntry("save_asset", "Assets & front-end",
        "Publish GENERATED bytes/arrays as a named cell asset — the write-side dual of `@asset`.",
        ["binary", "large data", "float32", "json", "client", "download", "generated"],
        Base.Docs.Binding(ReportEngine, :_save_asset)),

    # ── Web cells ──────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("web cell", "Web cells",
        "A first-class HTML/CSS/JS cell with `{{ }}` interpolation and a live JS↔Julia bridge.",
        ["javascript", "html", "css", "custom ui", "d3", "canvas", "frontend", "widget", "preact"],
        "#%% web   →   @web(html\"\"\"…\"\"\" css\"\"\"…\"\"\" js\"\"\"…\"\"\")",
        """A `web` cell is a THIRD cell kind alongside `code` and `md`: native CM6 panes for HTML, CSS
        and JS. Its source really is a runnable `@web(...)` call that evaluates to a `WebPage`, so it
        behaves like any code cell — live, reactive, and in a static export.

        CREATE: `slate_add_cell(kind="web", source=…)` (agent) · command-mode `w` · the `+` insert menu
        · the kind chips in the cell header. Panes are OPTIONAL — a fresh cell is JS-only, and any
        subset is legal (`@web(js\"\"\"…\"\"\")`).

        DATA IN — `{{ julia_expr }}` inline, escaped PER SECTION (JS → a JSON literal, HTML → entity
        escaped, CSS → token validated), so an interpolated value can't break out of its context.
        JSON-friendly values only (String/Real/Bool/nothing and Vector/Tuple/Dict/NamedTuple of those);
        `\$` and `\${}` are LEFT ALONE — only `{{ }}` interpolates. Big/binary arrays go via
        `save_asset`, NOT `{{ }}`. Reads inside `{{ }}` JOIN THE REACTIVE GRAPH: a `@bind` or
        `reactive` change re-runs the web cell and regenerates the page (cheap — string assembly).

        JS SCOPE (the fragment runs as `Slate.runFragment(root, echo)`):
        - `root` — the cell's OWN output element. Render with `root.querySelector(…)` / `root.append(…)`;
          never `document.getElementById` (scoped and collision-free, so a re-run can't cross-talk).
        - `echo(…)` — print a line into the cell (and the console).
        - top-level `await` works (`await import(…)`, `await Slate.asset(…)`); a thrown/rejected error
          renders ONTO the cell. A JS *syntax* error can't be caught (the script never parses) — the
          in-pane linter flags it instead.

        JS → JULIA and back: `await window.slateCall("chan", args, onProgress?)` invokes a
        `slate_on("chan", …)` handler in the notebook and returns its result (see `slate_on`).
        JULIA → JS one-way, no recompute: `slate_emit("chan", value)` → `slateOnStream("chan", cb)`.

        ```julia
        #%% web id=plot
        @web(html\"\"\"<div id="out"></div>\"\"\",
             css\"\"\"#out { height: 240px }\"\"\",
             js\"\"\"const xs = {{ collect(1:n) }};                     // Julia value → JSON literal
                   root.querySelector("#out").textContent = xs.length;
                   const r = await window.slateCall("stats", {k: 3});  // → slate_on("stats", …)
                   echo(`mean = \${r.mean}`);\"\"\")
        ```
        STATIC EXPORT: client-only fragments render offline, but `slateCall` needs a live kernel — a
        server-backed widget is live-only. See also `WebPage`, `slate_on`, `slate_emit`, `save_asset`."""),

    # ── Progress ───────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("slate_progress", "Progress",
        "Report progress (0..1) from a running cell → its progress bar + the run chip.",
        ["bar", "percent", "status", "long running", "loop"],
        "slate_progress(frac; msg=\"\", id=\"\", done=false)",
        """Report progress (0..1) from a running cell — drives the cell's progress bar + the floating
        run chip. `@progress`/`@withprogress` loops also drive it automatically.
        `for i in 1:n; slate_progress(i/n; msg=\"step \$i\"); end`."""),

    # ── Live custom stream ───────────────────────────────────────────────────────────────────────
    SlateApiEntry("slate_emit", "Live stream",
        "PUSH a value to browser JS on a channel — no recompute, no output swap (Julia → JS).",
        ["stream", "push", "live", "javascript", "low latency", "custom renderer"],
        "slate_emit(channel::AbstractString, value)",
        """Push any JSON-serializable Julia VALUE (Dict / NamedTuple / Vector / number / String) to a
        browser-side handler on `channel`, with NO cell recompute and NO output swap — the low-latency
        path for a custom JS renderer or web-cell fragment that owns its cell's output. Pass the value
        ITSELF — the server JSON-encodes it — NOT a pre-encoded `JSON.json(…)` string (that
        double-encodes: the browser would receive a quoted string, not an object). In the browser a
        handler registers `slateOnStream(channel, data => …)` and receives the parsed value.
        Region-transparent (works when the cell runs on a remote worker).
        `slate_emit("mypanel", (node = "x", phase = "forward"))`."""),

    SlateApiEntry("slate_on", "Live stream",
        "Answer CALLS from browser JS — register a handler that `window.slateCall` invokes (JS → Julia).",
        ["callback", "handler", "rpc", "slatecall", "request", "javascript", "interactive"],
        "slate_on(channel, f)  ·  slate_off(channel)  ·  slate_call(channel, args)",
        """The request/response counterpart to `slate_emit`'s one-way push. A cell registers a handler;
        browser JS calls it and awaits the result:
        ```julia
        slate_on("stats", args -> (mean = mean(data[1:args.k]),))   # args arrives as a NamedTuple
        ```
        ```javascript
        const r = await window.slateCall("stats", {k: 3}, p => echo(p.msg));   // → {mean: …}
        ```
        A TWO-ARG handler `(args, progress) -> …` may stream frames back while it works —
        `progress((msg = "…",))` lands on the JS `onProgress` callback, correlated by call id (no token
        to thread). The return value is JSON-encoded, so return JSON-friendly data.

        `slate_off(channel)` drops a handler (a package wiring a TRANSIENT per-cell handler removes it
        on teardown so a re-run doesn't leak dead closures). `slate_call(channel, args)` invokes a
        handler FROM Julia in-process — for testing one, or wiring it to a control:
        `@onclick go slate_call("compute", (n = n_slider,))`. It errors if the channel isn't registered.

        The registry is per-namespace and per-channel: a cell re-run REPLACES its channel's handler, and
        a namespace rebuild drops them all. Pairs with `web cell` (its JS is the usual caller)."""),
    SlateApiEntry("slate_on_cleanup", "Live stream",
        "Release a LIVE per-cell resource before the cell re-runs or is deleted.",
        ["teardown", "dispose", "leak", "connection", "task", "subscription", "lifecycle"],
        "slate_on_cleanup(f)",
        """Register a callback that Slate runs — and clears — BEFORE this cell re-evaluates, when the
        cell is DELETED, and before a namespace rebuild. The lifecycle hook for anything a cell holds
        open that a re-run would otherwise leak: a spawned task, a subscription, a socket, a session.
        ```julia
        t = @async feed_loop()
        slate_on_cleanup(() -> stop!(t))     # a re-run stops the old loop before starting a new one
        ```
        Keyed by the executing cell, so each cell cleans up only what it set up. Distinct from the
        `resource` cell tag (which is about CACHING an external-resource cell, not tearing it down)."""),

    # ── Fingerprints & the memo store ── real functions, documented in their own docstrings ─────────
    SlateApiEntry("slate_fingerprint", "Caching",
        "Canonical content hash of a value — what durable memo keys are built from.",
        ["hash", "cache key", "identity", "changed"],
        Base.Docs.Binding(ReportEngine, :slate_fingerprint)),
    SlateApiEntry("slate_memo_stats", "Caching",
        "Shape and size of the durable memo store.",
        ["cache", "disk", "size", "stats"],
        Base.Docs.Binding(ReportEngine, :slate_memo_stats)),
    SlateApiEntry("slate_memo_entries", "Caching",
        "List durable memo entries — what is cached, how big, how old.",
        ["cache", "listing", "inspect", "evict"],
        Base.Docs.Binding(ReportEngine, :slate_memo_entries)),

    # ── Advanced seams ─────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("slate_refresh", "Advanced",
        "Low-level: announce that globals changed so their reader cells recompute.",
        ["restale", "recompute", "async", "background", "progressive"],
        "slate_refresh(:name, …)",
        """The primitive under `reactive`: a background task inside a cell announces that some globals
        changed, and the server recomputes the cells that READ those names, pushing a live update.
        ```julia
        @async for chunk in stream; global data = vcat(data, chunk); slate_refresh(:data) end
        ```
        PREFER `reactive` / `@reactive` — same effect with the name derived from the binding (so it
        can't drift) and no manual `global`. Reach for `slate_refresh` when the value is an ordinary
        global you can't restructure. A no-op on a standalone run."""),
    SlateApiEntry("slate_effect", "Advanced",
        "Declare a cell EFFECT the host acts on — e.g. re-establish this on every worker.",
        ["everywhere", "distributed", "package", "seam", "declare", "region"],
        "slate_effect(kind; names=…, data...)  ·  slate_everywhere(:name, …)",
        """The outbound seam from cell code (or a package it calls) to Slate: the running statement
        DECLARES something for the host to act on, and Slate harvests it with the cell's output. It is
        transport-free (a task-local push) and a no-op outside a harvesting eval, so a package can call
        it unconditionally without depending on KaimonSlate.

        `slate_everywhere(:f, :g)` is the ergonomic case — the notebook/region analogue of
        `Distributed.@everywhere`: mark these names so Slate re-establishes them on EVERY worker
        (including one adopted later). Call it from inside the registering statement so the effect is
        attributed there. No `@everywhere` MACRO is injected — it would clash with `Distributed`'s."""),

    # ── Remote execution & regions ─────────────────────────────────────────────────────────────────
    # Discoverability SIGNPOSTS for the `slate.*` AGENT tools (not cell helpers), so `slate_api("remote")`
    # / `slate_search_docs("region")` surface them; each tool's own schema (in `create_tools`) has the
    # full per-parameter reference.
    SlateApiEntry("remote", "Remote & regions",
        "AGENT TOOLS — run a WHOLE notebook's worker on another machine (SSH), transparently.",
        ["ssh", "host", "offload", "gpu", "cluster", "move", "elsewhere"],
        "slate.run_on · slate.check_remote · slate.whereis · slate.remote_workers · slate.reap_worker · slate.sync_memo",
        """Run a WHOLE notebook's worker on another machine. These are `slate.*` AGENT TOOLS — call the
        tool (they act on a notebook/host from OUTSIDE a cell; cell code never calls them):
          • `slate.run_on(notebook, host, scope)` — place THIS notebook's worker locally or on an SSH
            host (transport `tunnel`|`direct`; `scope` `session`|`notebook`|`clear`). Reactivity,
            hot-reload and streaming stay transparent. `slate.check_remote(host)` dry-runs + primes a
            host first.
          • `slate.remote_workers(host)` — a host's live roster (state + telemetry);
            `slate.reap_worker(host, port)` kills one; `slate.whereis(notebook)` shows where a notebook
            runs right now.
          • `slate.sync_memo(notebook)` — push local durable-cache blobs to the remote (either transport)
            so it RESTORES cached results instead of recomputing (companion to `slate_memo_stats` /
            `slate_memo_entries` / `slate_memo_trace`).
        To run only SOME cells elsewhere (and keep workers warm), see the `regions` entry."""),
    SlateApiEntry("regions", "Remote & regions",
        "Run SOME cells on another kernel/host; boundary values cross as content-addressed blobs.",
        ["distributed", "warm pool", "offload", "per cell", "second kernel", "hybrid"],
        "slate.region · slate.region_on · slate.regions  ·  cell tag `region=<name>`",
        """Run SOME of a notebook's cells on a second kernel (another host) while the rest stay local —
        boundary values cross automatically as content-addressed blobs (a DataFrame crosses as Arrow IPC;
        unchanged values dedup to nothing). AGENT TOOLS define the compute; cell TAGS assign the work:
          • `slate.region(name; host, transport, warm, preload, data_root, …)` — define/update a global
            named region: a host over `tunnel`|`direct`, `warm` workers kept booted for instant adoption
            (a region with warm>0 IS a warm pool), an optional `preload` project replicated on the host,
            and a remote `data_root`. Many regions may point at one host.
          • `slate.region_on(notebook, "name1,name2")` — choose which regions a notebook uses (durable in
            its footer). `slate.regions()` lists the registry + parked wires.
          • Tag a cell `region=<name>` (the 🏷 tag editor's "Run on") to run it there. Keep the main kernel
            and `@bind` cells local; a region cell should PRODUCE values, not mutate main-kernel state (v1).
        A SHARED KERNEL cell — `using X` plus the functions the region cells call — needs no annotation:
        its imports and DEFINITIONS (functions, types, literal `const`s) are re-established on every
        worker, while data-dependent compute in the same cell stays behind. Its own upstream data reads
        are staged across first, so a definition that references an outer global still resolves. Tag a
        cell `everywhere` to override that and re-run it WHOLE on every worker — for the cell whose
        compute genuinely belongs on each side (a registration call, a process-global config) rather than
        a definition. Values that a region cell reads from another side cross as blobs; functions and
        consts a notebook defines never do (they live in its anonymous module, which the far side can't
        decode) — those are always re-established by this priming path."""),

    # ── Cell tags (header) ─────────────────────────────────────────────────────────────────────────
    SlateApiEntry("cell tags", "Cell tags",
        "Per-cell behaviour/presentation/role tags carried in the `#%%` header.",
        ["hidecode", "nocache", "collapsed", "needs", "slide", "trace", "cache", "header"],
        "#%% code id=… <tag> …    (or the 🏷 tag editor)",
        """Per-cell tags travel in the `#%%` header (set them with the 🏷 button in the cell header, or
        an explicit header token). Behaviour tags: `collapsed` (fold the cell), `hidecode` (hide the
        editor, show output), `trace` (wrap in @trace — inspect every value), `nocache` (opt OUT of
        durable memoization — for impure / side-effecting cells), `cache` (opt IN regardless of
        runtime — persist a pipeline stage's result so it RESTORES instead of recomputing until an
        input actually changes), `resource` (an EXTERNAL-resource initializer — a DB connection or
        file/socket handle: the live handle can't be cached so the cell re-inits every open, but
        unlike `nocache` it does NOT poison downstream — cells reading it stay cacheable, keyed by
        this cell's source; pair with an `@asset` on the backing file if the resource can drift
        externally), `everywhere` (re-run this cell WHOLE on every region worker — see "regions").
        Presentation tags: `slide` (force a
        new slide), `notes` (speaker notes, presenter-only). Document-metadata ROLE tags: `title`,
        `abstract`, `bibliography` (see "front matter"). Site tags (see "site"): `home` (this notebook is
        the published site's FRONT PAGE), `docindex` (marks where the document listing is injected).
        `needs=<id>,<id>` asserts MANUAL dependency edges on EARLIER code cells — for effects no
        variable carries (a cell reading a DB table another cell CREATEs): the engine treats them as
        real edges (staleness, run ordering, memo keys). Draw/remove them in the DAG pane: 🔗 arms
        link mode, then click two cells to link (click a dashed edge to unlink). Any
        other token is a free-form tag that round-trips. Expensive cells (≥150 ms) are otherwise
        auto-cached to disk and RESTORED after a restart instead of recomputing."""),

    # ── Publishing to a site (GitHub Pages) ──────────────────────────────────────────────────────────
    SlateApiEntry("site", "Document",
        "Publish a repo as a SITE of many documents (GitHub Pages), with a custom front page.",
        ["publish", "pages", "blog", "home", "deploy", "portfolio"],
        "Export → Publish · `home` + `docindex` tags",
        """Publishing (Export → Publish to GitHub Pages) makes a repo a SITE hosting MANY documents: each
        notebook lands at `/<slug>/` and the site root is a generated blog index (cards → every doc).
        Publishing is additive — other docs are preserved. To author a CUSTOM front page instead of the
        default cards, tag a notebook `home`: it renders to the site ROOT, and a cell tagged `docindex`
        marks where the document listing is injected (re-filled on every publish, so it stays current).
        A `home` notebook is the portfolio/blog landing page — write intro, bio, featured links around
        the `docindex` cell."""),

    # ── Document metadata (front matter) ─────────────────────────────────────────────────────────────
    SlateApiEntry("front matter", "Document",
        "Document metadata as ROLE-tagged cells: `title`, `abstract`, `bibliography`.",
        ["title", "author", "byline", "abstract", "bibtex", "pdf", "paper"],
        "#%% md id=… title | abstract | bibliography",
        """A notebook is also a PUBLISHABLE document. Author metadata as ordinary cells carrying a ROLE
        tag, in natural reading order; every export target (article PDF, slide deck, HTML) interprets the
        role for placement.
          • `title` — its markdown is the title block: `# Title`, then `## `/`### ` subtitle, then the
            first plain line as the byline. Hoisted to the top on export.
          • `abstract` — hoisted into the title block (academic abstract).
          • `bibliography` — its body is either embedded BibTeX (`@book{key, …}`) OR one-or-more `.bib`
            file paths (one per line), resolved relative to the notebook and copied into the export.
            Inline + external can be mixed; in the live UI it renders an adaptive references card.
        With no `title` cell, the document title falls back to the first markdown H1 (then the
        filename). Per-notebook citation style is `bibstyle` (Settings → Citation style):
        ieee/apa/chicago-author-date/mla/nature/vancouver/harvard."""),
    SlateApiEntry("citation", "Document",
        "Cite a bibliography key in markdown prose: `[@key]`, `[@key, p. 7]`, bare `@key`.",
        ["bibtex", "reference", "cite", "bibliography", "footnote"],
        "[@key] · [@key, p. 7] · [@a; @b] · @key (prose)",
        """Cite a bibliography key in MARKDOWN prose. Forms: `[@key]` (normal) · `[@key, pp. 33-35]`
        (page/locator) · `[@a; @b]` (multiple) · bare `@key` (prose form: "Knuth (1984)" — for an
        author-year mention; only converts keys actually defined, so emails stay literal). Typing `[@`
        in a markdown cell autocompletes keys. Export renders linked citations + a References list in
        the chosen `bibstyle`; the live notebook shows a references card with cited keys highlighted."""),
    SlateApiEntry("slides", "Document",
        "Present the notebook as a 16:9 deck — a `##` heading starts a slide.",
        ["presentation", "deck", "present", "talk", "speaker notes"],
        "▶ Present  ·  Export PDF (slides)  ·  `slide` / `notes` cell tags",
        """The same notebook is also a PRESENTATION. A `##` heading starts a new slide (the heading
        level is configurable in Settings), so a well-structured document usually needs no extra
        markup. For explicit control, tag a cell `slide` (force a new slide here) or `notes` (speaker
        notes — presenter view only, never rendered in the deck or the article).
        Present live in the browser (▶ Present) or Export PDF → slides for a 16:9 deck. See also
        `cell tags`, `front matter`."""),
    SlateApiEntry("markdown", "Document",
        "Prose cells (`#%% md`) with `{{ expr }}` interpolation of live values; `@md` is their skin.",
        ["md", "text", "prose", "interpolation", "narrative", "template", "standalone"],
        "#%% md id=…    ·    {{ expr }}    ·    !!! note \"Title\"    ·    @md\"\"\"…\"\"\"",
        """A markdown cell is prose, and `{{ expr }}` splices a LIVE value into it — the expression is
        evaluated in the notebook namespace and its string form substituted, so the prose stays true as
        upstream values change (the reads join the reactive graph, exactly like a `web` cell's).
        ```markdown
        The model converged in {{ n_iters }} iterations ({{ round(elapsed; digits=1) }} s).
        ```
        Prose is CommonMark with GFM tables, `\$…\$`/`\$\$…\$\$` LaTeX (KaTeX), and Julia-style admonitions —
        `!!! note "Title"` with the body indented four spaces. The category is free-form, so a notebook
        can coin its own (`!!! answer`) and style `.admonition.answer`; note/info/tip/hint/answer/
        warning/danger already carry a colour.
        In the saved `.jl` a markdown cell is wrapped in an `@md\"\"\"…\"\"\"` skin so the notebook is
        ALSO a runnable plain-Julia script: `julia notebook.jl` prints the rendered prose to stdout
        (`KAIMONSLATE_QUIET_MD=1` suppresses it for a code-only run) and `standalone!` supplies the rest
        of the notebook contract (`@bind` falls back to widget defaults, live-only helpers no-op). Inside
        the Slate engine the skin is unwrapped at parse time — you never write `@md` by hand.
        Role tags (`title`, `abstract`, `bibliography`) go on markdown cells — see `front matter`.
        A FENCED block whose language an extension claimed (SlateExtensionsBase
        `register_fence_renderer!`) renders as that extension's output instead of a code block, through
        the same machinery a returned value uses — so it works live and in a static export. A language
        nobody claimed stays an ordinary code block, so this costs an existing notebook nothing."""),
    SlateApiEntry("@trace", "Cell tags",
        "Inspect EVERY intermediate value in a cell (usually via the 🔍 button / `trace` tag).",
        ["debug", "values", "inspect", "step through"],
        "@trace begin … end   (or the `trace` cell tag)",
        """Inspect every intermediate value in a cell — each line's value is collected into a trace
        table. Usually toggled via the cell's 🔍 button / `trace` tag rather than written by hand."""),
]

# ── Renderers ──────────────────────────────────────────────────────────────────────────────────
# Records for the semantic index: one per entry, module "Slate" so module-scoped search includes them.
# The summary + routing keywords are folded in so a name-blind search ("log axis", "clickable row")
# retrieves the entry even when the prose never spells the phrase.
slate_api_records() = [Dict{String,Any}("module" => "Slate", "name" => e.name,
                                        "doc" => string(e.summary, "\n\n", _entry_markdown(e),
                                                        isempty(e.keywords) ? "" :
                                                        string("\n\nkeywords: ", join(e.keywords, ", "))))
                       for e in SLATE_API]

# A content hash so the auto-indexer re-indexes only when the API docs actually change.
slate_api_version() = string(hash(slate_api_records()); base = 16)

_api_categories() = unique(String[e.category for e in SLATE_API])

# Resolve ONE Slate helper by exact name (case-insensitive; tolerant of a leading `@`). The docs UI's
# drill-down / "Related" cross-references resolve a Slate helper's docs from THIS registry FIRST — a
# DSL helper like `Checkbox`/`@bind` is an injected constructor/macro with no reachable docstring, so a
# live `module_help` lookup returns "No documentation found". An entry backed by `docbinding` (a real
# function like `slate_table`) still renders that function's OWN docstring via `_entry_markdown`.
# Returns the entry or `nothing` (caller then falls back to live package help).
function slate_api_entry(name::AbstractString)
    n = lowercase(strip(String(name)))
    isempty(n) && return nothing
    # A cross-reference from the docs UI qualifies a Slate helper under its pseudo-module — the ref
    # arrives as "Slate.slate_table". Drop that qualifier so it resolves to the registry entry rather
    # than falling through to a live `Slate.slate_table` binding lookup (which never exists).
    n = String(chopprefix(n, "slate."))
    for e in SLATE_API
        lowercase(e.name) == n && return e
    end
    ns = lstrip(n, '@')
    for e in SLATE_API
        lowercase(lstrip(e.name, '@')) == ns && return e
    end
    return nothing
end

# Every entry of a category, in registry order.
_api_in_category(cat::AbstractString) = [e for e in SLATE_API if lowercase(e.category) == lowercase(cat)]

# Resolve a category by name, tolerant of the spacing/punctuation a caller won't remember
# ("assets", "assets & front-end", "web cells", "webcells"). Returns the canonical name or nothing.
# A prefix counts, but only from 3 characters — shorter than that a stray token would drag a whole
# category in ahead of the name/phrase paths.
function _api_category_match(t::AbstractString)
    norm(s) = filter(c -> !isspace(c) && c != '&' && c != '-', lowercase(s))
    nt = norm(t)
    isempty(nt) && return nothing
    cats = _api_categories()
    i = findfirst(c -> norm(c) == nt, cats)
    i === nothing && length(nt) >= 3 && (i = findfirst(c -> startswith(norm(c), nt), cats))
    return i === nothing ? nothing : cats[i]
end

# ── The INDEX (what `slate.api()` returns) ────────────────────────────────────────────────────
# One scannable line per helper, grouped by category: name, its one-line summary, and the routing
# keywords that let a caller who doesn't know the NAME still land on the right entry. Deliberately
# LOSSY — an index line is enough to choose what to read, never enough to write the call from. The
# full detail is one `slate.api("name")` away, and several names can be fetched in ONE call.
function slate_api_toc()
    return string("# Kaimon Slate notebook API — index ($(length(SLATE_API)) helpers)\n\n",
        """
        Slate-specific helpers injected into every cell. They are NOT in package docs, and a
        package-docs search for "chart"/"series" returns Makie, which will lead you astray.

        These lines are SUMMARIES — read one, then drill in BEFORE writing your first use:
          slate_api("echart")             one helper, in full
          slate_api("echart @bind web")   SEVERAL at once — batched into one call
          slate_api("Widgets")            a whole category   ·   slate_api("all") = every entry

        """, _api_toc_body())
end

# The index BODY — one line per helper, grouped by category. Shared by the `slate.api` index and the
# cheatsheet, which frame it differently but must list exactly the same helpers.
#
# `keywords` are shown in the TOOL's index (where the reader is deciding what to fetch next, and a
# routing term turns "log axis" into `echart`) and omitted from the CHEATSHEET, where they'd be dead
# weight: an agent holding the prompt doesn't need to guess a search term, it just calls the tool.
function _api_toc_body(; keywords::Bool = true)
    io = IOBuffer()
    w = maximum(length(e.name) for e in SLATE_API)
    for cat in _api_categories()
        println(io, "## ", cat)
        for e in _api_in_category(cat)
            kw = (keywords && !isempty(e.keywords)) ? string("  [", join(e.keywords, " · "), "]") : ""
            println(io, "  ", rpad(e.name, w), "  ", e.summary, kw)
        end
        println(io)
    end
    return String(take!(io))
end

# Render one or more entries in full, deduped, in registry order.
function _render_entries(io::IO, entries)
    seen = Set{String}()
    for e in SLATE_API
        e.name in seen && continue
        any(x -> x.name == e.name, entries) || continue
        push!(seen, e.name)
        println(io, "### ", e.name, "  (", e.category, ")\n", _entry_markdown(e), "\n")
    end
    return io
end

# Nearest entries to a topic that matched NOTHING, so a miss routes somewhere instead of dead-ending.
# Ranked by cheap, explainable signals — a shared prefix, a substring either way, or an overlapping
# keyword — which is all it takes to turn "binding"/"chart"/"colour" into the right suggestion.
function _api_suggestions(t::AbstractString; limit::Int = 6)
    score(e) = begin
        # Compare against the BARE name: with the sigil, "bindings" matches neither end of "@bind"
        # and the nearest entry to an obvious near-miss goes unsuggested.
        n = lowercase(lstrip(e.name, '@')); s = 0
        (startswith(n, t) || startswith(t, n)) && (s += 4)
        (occursin(t, n) || occursin(n, t)) && (s += 3)
        any(k -> occursin(t, k) || occursin(k, t), lowercase.(e.keywords)) && (s += 2)
        occursin(t, lowercase(e.summary)) && (s += 1)
        s
    end
    scored = [(score(e), e) for e in SLATE_API]
    filter!(p -> p[1] > 0, scored)
    sort!(scored; by = p -> -p[1])
    return [p[2] for p in scored[1:min(limit, length(scored))]]
end

"""
    slate_api_reference(topic = "") -> String

The `slate.api` tool's text.

- `""` → the INDEX (`slate_api_toc`): one line per helper. Cheap; the default on purpose.
- `"all"` / `"full"` → every entry in full (what the index replaced as the default).
- `"name"` / `"name1 name2 …"` → those entries in full — BATCHED, so a cell needing three helpers
  costs one call rather than three.
- a CATEGORY (`"Widgets"`, `"charts"`) → every entry in it.
- anything else → entries whose name/category/keywords/doc contain every word of the topic; failing
  that, a "did you mean" list of the nearest entries rather than a dead end.
"""
function slate_api_reference(topic::AbstractString = "")
    t = strip(lowercase(String(topic)))
    io = IOBuffer()
    isempty(t) && return slate_api_toc()
    if t in ("all", "full", "everything")
        println(io, _SLATE_CHEATSHEET)
        println(io, "\n---\n# Full reference\n")
        println(io, "Drill into any helper with `slate.api(\"name\")`; search them with ",
                    "`slate.search_docs(\"…\")` (module \"Slate\").\n")
        for cat in _api_categories()
            println(io, "## ", cat)
            for e in _api_in_category(cat)
                println(io, "\n### ", e.name, "\n", _entry_markdown(e))
            end
            println(io)
        end
        return String(take!(io))
    end
    # An exact helper NAME wins over everything else — `slate.api("display")` means the helper, even
    # though "Display" is also a category.
    tokens = filter(!isempty, split(replace(t, ',' => ' ')))
    if length(tokens) == 1
        e = slate_api_entry(t)
        if e !== nothing
            _render_entries(io, [e])
            return String(take!(io))
        end
    end
    # BATCHED drill-down: every token naming an entry → return them all. Commas optional, so
    # `slate_api("echart, @bind")` and `slate_api("echart @bind")` both work. Only when EVERY token
    # resolves — otherwise the topic is prose ("warm region"), handled as a phrase query below.
    if length(tokens) > 1
        found = [slate_api_entry(tok) for tok in tokens]
        if all(!isnothing, found)
            _render_entries(io, SlateApiEntry[e for e in found])
            return String(take!(io))
        end
    end
    # A whole category — "Widgets", "assets", "web cells".
    cat = _api_category_match(t)
    if cat !== nothing
        println(io, "# ", cat, "\n")
        _render_entries(io, _api_in_category(cat))
        return String(take!(io))
    end
    # Phrase query: every word of the topic must appear somewhere in the entry — now including its
    # summary and routing KEYWORDS, so "log axis" finds `echart` and "clickable row" finds TableSelect.
    words = tokens
    hits = [e for e in SLATE_API
            if (c = lowercase(string(e.name, " ", e.category, " ", e.summary, " ",
                                     join(e.keywords, " "), " ", _entry_doc(e)));
                all(w -> occursin(w, c), words))]
    if isempty(hits)
        # PARTIAL batch: some tokens named a helper and the rest didn't (`"echart binding"`). Answering
        # with a bare "no match" would be a silent mode switch — the caller named a real helper and got
        # nothing for it. Serve what resolved, and say what didn't (with its own suggestions), so the
        # response never depends on a rule the caller can't see. This runs only AFTER the phrase query
        # fails, so `"slate_table format"` still works as a filter rather than fragmenting into parts.
        resolved = Pair{String,Union{Nothing,SlateApiEntry}}[String(tok) => slate_api_entry(tok) for tok in tokens]
        if length(tokens) > 1 && any(p -> p.second !== nothing, resolved)
            _render_entries(io, SlateApiEntry[p.second for p in resolved if p.second !== nothing])
            for (tok, e) in resolved
                e === nothing || continue
                near = _api_suggestions(tok; limit = 3)
                println(io, "> No entry named `", tok, "`",
                        isempty(near) ? ". `slate.api()` lists every helper." :
                        string(" — did you mean ", join(string.("`", getfield.(near, :name), "`"), ", "), "?"))
            end
            return String(take!(io))
        end
        near = _api_suggestions(t)
        isempty(near) && return "No Slate API entry matches \"$topic\". `slate.api()` lists every helper; " *
                                "`slate.search_docs(\"$topic\")` searches the notebook's package docs too."
        return "No Slate API entry matches \"$topic\". Did you mean: " *
               join(string.("`", getfield.(near, :name), "`"), ", ") *
               "?  (`slate.api(\"" * near[1].name * "\")`, or `slate.api()` for the full index.)"
    end
    _render_entries(io, hits)
    return String(take!(io))
end

# The cheatsheet inlined in the in-app agent's system prompt. It is an INDEX WITH TRIGGERS, not a
# mini-manual — and it is RENDERED FROM THE REGISTRY, so a helper added there appears here without
# anyone remembering to update prose (the old hand-written version had silently fallen behind: web
# cells, the JS bridge and `save_asset` shipped without ever reaching the agent's prompt).
#
# Why an index and not a digest: a summary complete enough to write a call from is complete enough to
# write a WRONG call from, confidently, without ever consulting the real reference. The digest form
# taught `echart(:line, x, y)` but not that `yAxis`/`grid` belong on the option rather than the
# series — so the agent guessed. Naming the helper and withholding its signature makes the tool call
# the cheap path instead of the redundant one.
const _SLATE_CHEATSHEET = string("""
# Kaimon Slate notebook API

Cells run in a REACTIVE notebook: a cell that READS a variable re-runs when that variable changes,
and a cell's LAST expression is what renders (`println` → stdout; a trailing `;` keeps a cell quiet).

The helpers below are injected into EVERY cell. They are Slate-specific and NOT in package docs —
`echart` is Slate's chart DSL, not Makie's `series`, and a package-docs search for "chart"/"series"
returns Makie, which will lead you astray.

**Call `slate_api("name")` before your first use of any helper below.** These one-liners say what
EXISTS; they are not signatures, and a cell written from a summary is a cell written from a guess.
One call takes several names — `slate_api("echart @bind slate_table")` — so a cell needing three
helpers still costs one call. `slate_search_docs("…")` searches these alongside the notebook's
package docs (module "Slate"); `slate_api("all")` is the whole reference at once.

""", _api_toc_body(; keywords = false), """
Worked examples: `examples/echarts_dsl.jl`, `examples/binds_demo.jl`, `examples/frontmatter_demo.jl`.
""")
