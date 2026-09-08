# Offline interactivity with `@replay`

A static HTML export has no Julia behind it, so a `@bind` control has nothing to recompute. By
default an exported control renders as real markup and stays disabled.

`@replay` changes that. Mark an expression with the control that drives it, and the export evaluates
that expression once for every position the control can take, ships the results with the page, and
wires the control to them. The reader moves the slider and the figure follows, with no kernel
anywhere.

```julia
#%% code id=data
days  = string.(1:24)
sales = Float64[10 + i % 5 for i in 1:24]
movavg(v, w) = [sum(v[max(1,i-w+1):i]) / length(v[max(1,i-w+1):i]) for i in eachindex(v)]

#%% code id=controls
@bind w Slider(1:2:11; default = 3, label = "window")

#%% code id=figure
echart(:line, days, @replay(w, movavg(sales, w)); title = "Rolling mean")
```

`@replay w expr` and `@replay(w, expr)` are the same thing. The first argument is a control's name,
as a bare symbol. Inside the expression that name refers to the value being swept, so the code you
write is the code you would have written without the macro.

While you are authoring, `@replay` is a pass-through. It computes the one value the control is
sitting on, so the cell costs exactly what the bare expression costs. The sweep happens at export.

## What can drive a replay

A control qualifies when its domain is finite and small enough to enumerate.

| Control | Domain |
| --- | --- |
| `Slider` | the min/max/step grid |
| `NumberField` | the same grid, and only when it is bounded |
| `Checkbox` / `Toggle` | `false`, `true` |
| `Select` / `Radio` | the option values |
| `RangeSlider` | the ordered low/high pairs |
| `TableSelect` | the row indices, plus "nothing selected" |
| `MultiSelect` / `MultiCheckBox` | the power set of the options |

Everything else is refused when the cell runs, with a message naming the control's kind: `TextField`,
`TextArea`, `DateField`, `TimeField`, `ColorPicker`, `FileUpload`, `Button` and `playhead` have no
finite domain to sweep. Combinatorial domains are capped at 20,000 positions, which is roughly a
200-stop range slider or 14 checkboxes.

The value your expression sees is the value the live cell sees: a `Choice` for a labelled `Select`,
a row `NamedTuple` for a `TableSelect`, a low/high tuple for a `RangeSlider`.

## What can carry one

### Charts

An ECharts figure carries a replay when the marked array reaches a series the chart DSL knows how to
rewrite: `:line`, `:bar`, `:area`, `:scatter`, `:heatmap` and `:calendar`. The mark records which
part of each drawn point the shipped array feeds, so the page rewrites only that and reuses the
coordinates already drawn.

The other kinds carry no mark. A `@replay` inside a `:pie`, `:candlestick`, `:radar`, `:boxplot`,
`:sankey`, `:graph`, `:treemap`, `:sunburst` or geo `:lines` chart sweeps, ships, and then does
nothing when the reader moves the control. Nothing warns about it.

Makie figures cannot carry a replay either. An exported Makie figure is an image, and nothing walks
it looking for marks.

### Tables

A marked `slate_table` ships the union of its rows across every position, once, plus a per-position
ordering into that union. The reader gets sort, filter, paging and CSV as usual, over whichever rows
the control selects. A control that changes which *columns* show works too. A control that changes
both rows and columns is refused, as is a row union past 20,000 rows. A server-paged table cannot be
replayed at all.

### Prose

Markdown `{{ }}` interpolations follow a control with no `@replay` anywhere. The export works out the
sweep from the dependency graph and ships one string per interpolation per position.

Tables a hop or more downstream of their control are composed the same way, out of the cells between
the two. This is why a table can follow a slider without carrying a mark. Cells that block the
composition are reported as `@info` naming the cell and the reason: a non-code cell, an impure cell, a
top-level `using`/`import`, a `const` or `global`, or another Slate macro in the chain.

## Exporting

Choosing HTML export opens a second step listing every mark: how many positions it has, how long one
takes, and how many bytes it will add. Totals are shown for the export as a whole.

![The replay step of the export dialog: one row per marked control showing its cell, kind, value count and measured size, a stride slider for each slider-driven mark, "all options" for a menu, and the totals with Back and Export buttons](./assets/replay-step.png)

A slider or a bounded `NumberField` can be **strided**, shipping every n-th position instead of all of
them. That divides both the sweep time and the size, and the page snaps the control to the nearest
shipped position so it still feels continuous. Categorical controls cannot be strided, because
dropping positions would delete choices.

Strides are per mark and are remembered in the notebook's config footer, so the next export starts
from the resolution you chose last time.

Publishing does not carry that setting. A published site sweeps every mark at full resolution.

## What the reader gets

Each control is enabled only once its data has loaded, so a control that is live is a control
something can drive. Every copy of the same control, including strip copies, moves together. The page
opens on the position the notebook was in when you exported it.

## Limits

**A worker is required.** Exporting from an in-process kernel silently produces a page with every
control frozen.

**The expression must return a numeric array of the same shape at every position.** The domain is
checked while you write the cell. The shape is checked when you export, so a `@replay` that returns a
scalar, ragged results, or a non-`Real` element type registers fine and then fails at export with a
message naming the problem.

**One mark's failure costs that mark only.** The sweep warns, that control exports frozen, and the
rest of the page is unaffected. A table whose sweep did not resolve degrades to an ordinary static
table.

**A `@replay` cell is never cached.** Restoring a memoized cell skips its body, which would bring the
figure back with no sweep registered and export a control with no data behind it. The exemption costs
nothing, because the macro does no work while you author.

For the same reason, do not `locked` a cell that carries a `@replay`. A locked cell has no computed
key to pin, so it cannot be restored on reopen, and the mark does not exist until the cell has
actually run.

**Region cells.** A cell tagged `region=` runs on a different namespace from the one the export reads,
so a `@replay` in a region cell does not reach the export.

**Browser support for compressed data.** Inlined sweep data is narrowed and gzipped by default, which
needs `DecompressionStream` (Chrome 80, Safari 16.4, Firefox 113). Export with compression off to
trade size for reach.

## See also

- [Widgets & `@bind`](widgets.md) for the controls a replay is built on
- [Export](export.md) for the rest of what an HTML export contains
- [Charts](visualization.md) for the chart kinds named above
- [Tables](tables.md) for what a replayed table keeps
- [Publishing](publishing.md) for what a published site carries
