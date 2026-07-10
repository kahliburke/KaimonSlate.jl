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
    doc::String          # markdown fallback: a sentence or two + at least one example
    docbinding::Union{Nothing,Base.Docs.Binding}   # a REAL function whose own docstring is the SSOT
end
# Most helpers are injected DSL constructs with no reachable docstring → the registry `doc` IS the
# source. A few (`slate_table`, `slate_query`, …) are real exported functions: point `docbinding` at
# them and their OWN docstring drives the api tool / search / prompt, so the two can never drift.
SlateApiEntry(name, category, signature, doc) = SlateApiEntry(name, category, signature, doc, nothing)
# Backed ENTIRELY by a real function's own docstring — no signature or prose duplicated here. The
# docstring (which leads with its own signature lines) is the single source rendered everywhere.
SlateApiEntry(name, category, binding::Base.Docs.Binding) =
    SlateApiEntry(name, category, "", "", binding)

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
    SlateApiEntry("series", "Charts", Base.Docs.Binding(ReportEngine, :series)),

    # ── Animation ── real function, documented in its own docstring (animation.jl) ─────────────────
    SlateApiEntry("animate", "Animation", Base.Docs.Binding(ReportEngine, :animate)),

    # ── Widgets (@bind) ────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("@bind", "Widgets", "@bind name Widget(…)",
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
    SlateApiEntry("TableSelect", "Widgets", "TableSelect(data; default, label, maxrows=200)",
        """A clickable table: renders `data` (a DataFrame / Tables.jl source / Vector of NamedTuples —
        anything `slate_table` takes) and binds the CLICKED ROW as a NamedTuple with a field per column.
        No selection → `nothing`. `@bind sel TableSelect(df)` then `sel.price` / `sel.name` downstream."""),
    SlateApiEntry("playhead", "Widgets", "playhead(anim; label) -> driven control",
        """A DRIVEN control: an animation player pushes its current 1-based frame index here (no input
        of its own). `@bind t playhead(anim)` lets another cell react to playback —
        `frames[t]` / `\"t=\$t\"`. Playback never waits on Julia; updates are throttled."""),

    # ── Live / reactive ────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("reactive", "Live", "reactive(:name, init) -> live value  ·  @reactive name = init",
        """A live value you push to over time: `level = reactive(:level, 0)`; `level[]` reads,
        `level[] = v` pushes to every cell that reads it (re-renders live, no manual refresh). The
        `:name` MUST match the variable — it routes the refresh to the cells that read `name`. Prefer
        the sugar `@reactive level = 0` (= `level = reactive(:level, 0)`), which derives the name from
        the binding so it can never drift."""),
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
    # Real exported functions — documented ONCE in their own docstrings (tables.jl / paged.jl).
    SlateApiEntry("slate_table", "Tables", Base.Docs.Binding(ReportEngine, :slate_table)),
    SlateApiEntry("slate_query", "Tables", Base.Docs.Binding(ReportEngine, :slate_query)),

    # ── Assets & front-end ─────────────────────────────────────────────────────────────────────────
    SlateApiEntry("@asset", "Assets & front-end", "@asset \"path\" -> String   ·   @asset bytes \"path\" -> Vector{UInt8}",
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
        the path is known at author time. See also `readfile`, `@use`, `WebPage`."""),
    SlateApiEntry("readfile", "Assets & front-end", "readfile(path; bytes=false) -> String | Vector{UInt8}",
        """The runtime escape hatch for `@asset` when the path is COMPUTED (not a literal Slate can
        extract). Same resolution — relative to the notebook's project dir, or absolute. UNLIKE
        `@asset`, it is NOT statically tracked: no memo-hash folding and no file-watcher, so a cell
        using `readfile` won't auto-recompute when the file changes and its cache can go stale. Reach
        for it only when the filename is dynamic; otherwise use `@asset "literal"`.
        ```julia
        cfg = readfile("configs/\$name.json")     # path depends on a variable → @asset can't see it
        ```"""),
    SlateApiEntry("@use", "Assets & front-end", "@use \"name\" => \"url\"    (or @use \"name\" \"url\")",
        """DECLARE a browser ES-module import at the NOTEBOOK level — the front-end counterpart of
        `@asset` (a JS module dep instead of a file dep). It's a runtime no-op: the literal pair is
        extracted statically and merged into the page's single `<script type=\"importmap\">`, injected
        in BOTH the live shell `<head>` and the static export `<head>`. So notebook front-end JS (in a
        `WebPage`, an `@asset`ed script, or inline) can `import` the bare specifier, live AND in an
        exported/published page. The import map is fixed at page load, so adding or changing a `@use`
        needs a reload to take effect (editing the JS that uses it stays instant).
        ```julia
        @use \"d3\" => \"https://esm.sh/d3@7\"    # then, in front-end JS:  import * as d3 from \"d3\"
        ```"""),
    SlateApiEntry("WebPage", "Assets & front-end", "WebPage(; html=\"\", css=\"\", js=\"\", obscure=false)",
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

    # ── Progress ───────────────────────────────────────────────────────────────────────────────────
    SlateApiEntry("slate_progress", "Progress", "slate_progress(frac; msg=\"\", id=\"\", done=false)",
        """Report progress (0..1) from a running cell — drives the cell's progress bar + the floating
        run chip. `@progress`/`@withprogress` loops also drive it automatically.
        `for i in 1:n; slate_progress(i/n; msg=\"step \$i\"); end`."""),

    # ── Fingerprints & the memo store ── real functions, documented in their own docstrings ─────────
    SlateApiEntry("slate_fingerprint", "Caching", Base.Docs.Binding(ReportEngine, :slate_fingerprint)),
    SlateApiEntry("slate_memo_stats", "Caching", Base.Docs.Binding(ReportEngine, :slate_memo_stats)),
    SlateApiEntry("slate_memo_entries", "Caching", Base.Docs.Binding(ReportEngine, :slate_memo_entries)),

    # ── Remote execution & worker pools ──────────────────────────────────────────────────────────────
    # A discoverability SIGNPOST for the `slate.*` AGENT tools (not cell helpers). It names each tool
    # and its purpose so `slate_api("remote")` / `slate_search_docs("warm pool")` surface them; the full
    # per-parameter reference is each tool's own schema (its docstring in `create_tools`).
    SlateApiEntry("remote", "Remote & pools",
        "slate.run_on · slate.warm_pool · slate.pools · slate.whereis · slate.remote_workers · slate.reap_worker · slate.sync_memo · slate.check_remote",
        """Run a notebook's worker on another machine, and keep warm workers ready for instant adoption.
        These are `slate.*` AGENT TOOLS — call the tool (they act on a notebook/host from OUTSIDE a cell;
        cell code never calls them). Each tool's schema has the full parameters:
          • `slate.run_on(notebook, host, scope)` — place THIS notebook's worker locally or on an SSH
            host (transport `tunnel`|`direct`; `scope` `session`|`notebook`|`clear`). Reactivity,
            hot-reload and streaming stay transparent. `slate.check_remote(host)` dry-runs + primes a
            host first.
          • `slate.warm_pool(host; n, preload)` — keep `n` prewarmed workers on `host` (optionally with
            a replicated `preload` project) so opening a matching notebook ADOPTS one (~1s) instead of a
            cold boot. `slate.pools()` shows configured pools + parked wires.
          • `slate.remote_workers(host)` — a host's live roster (state + telemetry);
            `slate.reap_worker(host, port)` kills one; `slate.whereis(notebook)` shows where a notebook
            runs right now.
          • `slate.sync_memo(notebook)` — push local durable-cache blobs to a `direct`-transport remote
            so it RESTORES cached results instead of recomputing (companion to `slate_memo_stats` /
            `slate_memo_entries`)."""),

    # ── Cell tags (header) ─────────────────────────────────────────────────────────────────────────
    SlateApiEntry("cell tags", "Cell tags", "#%% code id=… <tag> …    (or the 🏷 tag editor)",
        """Per-cell tags travel in the `#%%` header (set them with the 🏷 button in the cell header, or
        an explicit header token). Behaviour tags: `collapsed` (fold the cell), `hidecode` (hide the
        editor, show output), `trace` (wrap in @trace — inspect every value), `nocache` (opt OUT of
        durable memoization — for impure / side-effecting cells), `cache` (opt IN regardless of
        runtime — persist a pipeline stage's result so it RESTORES instead of recomputing until an
        input actually changes). Presentation tags: `slide` (force a
        new slide), `notes` (speaker notes, presenter-only). Document-metadata ROLE tags: `title`,
        `abstract`, `bibliography` (see "front matter"). Site tags (see "site"): `home` (this notebook is
        the published site's FRONT PAGE), `docindex` (marks where the document listing is injected).
        `needs=<id>,<id>` asserts MANUAL dependency edges on EARLIER code cells — for effects no
        variable carries (a cell reading a DB table another cell CREATEs): the engine treats them as
        real edges (staleness, run ordering, memo keys). Draw/remove them in the DAG pane with
        ⌥-click (two cells to link; a dashed edge to unlink). Any
        other token is a free-form tag that round-trips. Expensive cells (≥400 ms) are otherwise
        auto-cached to disk and RESTORED after a restart instead of recomputing."""),

    # ── Publishing to a site (GitHub Pages) ──────────────────────────────────────────────────────────
    SlateApiEntry("site", "Document", "Export → Publish · `home` + `docindex` tags",
        """Publishing (Export → Publish to GitHub Pages) makes a repo a SITE hosting MANY documents: each
        notebook lands at `/<slug>/` and the site root is a generated blog index (cards → every doc).
        Publishing is additive — other docs are preserved. To author a CUSTOM front page instead of the
        default cards, tag a notebook `home`: it renders to the site ROOT, and a cell tagged `docindex`
        marks where the document listing is injected (re-filled on every publish, so it stays current).
        A `home` notebook is the portfolio/blog landing page — write intro, bio, featured links around
        the `docindex` cell."""),

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
        With no `title` cell, the document title falls back to the first markdown H1 (then the
        filename). Per-notebook citation style is `bibstyle` (Settings → Citation style):
        ieee/apa/chicago-author-date/mla/nature/vancouver/harvard."""),
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
                                        "doc" => _entry_markdown(e)) for e in SLATE_API]

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
                println(io, "\n### ", e.name, "\n", _entry_markdown(e))
            end
            println(io)
        end
        return String(take!(io))
    end
    # Match when EVERY whitespace-separated word of the topic appears somewhere in the entry's
    # name/category/doc — so a multi-word query ("warm pool") finds `warm_pool`/`warm workers`/`pools`.
    words = split(t)
    hits = [e for e in SLATE_API if (c = lowercase(string(e.name, " ", e.category, " ", _entry_doc(e)));
                                     all(w -> occursin(w, c), words))]
    isempty(hits) && return "No Slate API entry matches \"$topic\". Try `slate.api()` for the full reference, " *
                            "or `slate.search_docs(\"$topic\")`."
    for e in hits
        println(io, "### ", e.name, "  (", e.category, ")\n", _entry_markdown(e), "\n")
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
@bind sel TableSelect(df)                               # click a row → sel is a NamedTuple (sel.col)
    # Group several related controls in ONE cell (multiple @bind lines) — they render a single
    # combined control strip. Prefer that to a separate cell per control.
    # EMBED the @bind in the cell that reads it (widget renders there), OR declare it once and
    # SURFACE it beside a figure: slate.surface(notebook, plotcell, "a,b")  (a,b=row; [a,b],c=cols)

## Animation — `animate(frames; …)`  (precompute once, play in the browser)
    anim = animate([field(t) for t in times]; kind=:heatmap, clim=:symmetric, x=r, y=r)
    @bind t playhead(anim)                                  # react to the current frame elsewhere

## Live / async
    level = reactive(:level, 0)        # level[] reads, level[] = v pushes to readers
    @onclick go (for v in 0:100; level[]=v; pause(0.1) end)   # pause = cancellable; cancel(:level) stops
    @onchange n (level[] = n)          # runs on change; cell does NOT recompute

## Tables — `slate_table(df)`  (a bare DataFrame auto-renders; sortable/filterable/paged)
    slate_table(df; format=(Rev=:currency, Pct=(kind=:percent,digits=1)), align=(Name=:left,),
                    viz=(Rev=:bar, Pct=:heat), paged=true)   # per-column format/align/coltype/viz +
    #   server-paging. Presets & the full option list: `slate_api("slate_table")`. SQL source → slate_query(conn, sql)
    #   Progress — `slate_progress(frac; msg)`

## Assets & front-end — include TRACKED files + browser modules
    @asset "app.js"        # read a file (String). Path is a LITERAL → TRACKED: edit the file and the
    #   cell re-runs + its memo won't serve stale (a watcher + memo-hash on the file). @asset bytes "logo.png" → bytes
    readfile("data/\$n.json")            # runtime read for a COMPUTED path — NOT tracked (no watcher/memo)
    @use "d3" => "https://esm.sh/d3@7"  # declare a browser ES-module import (import map; reload to change)
    WebPage(css=@asset("app.css"), js=@asset("app.js"), html=@asset("app.html"))  # self-contained HTML page

## Cell tags (🏷 in the cell header, or `#%%` header tokens, e.g. `#%% md id=abs abstract`)
    collapsed · hidecode · trace · nocache (skip durable caching) · cache (ALWAYS persist — a pipeline
stage restores instead of recomputing) · needs=<id>,… (manual dependency edges on earlier code cells,
for effects no variable carries, e.g. DB tables; ⌥-click two cells in the DAG pane) · plus free-form tags.
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
