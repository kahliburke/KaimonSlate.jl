# Widgets & @bind

Controls in KaimonSlate are **real Julia constructors**, not a static macro DSL. `@bind name
Widget(...)` binds a reactive variable `name` to a widget; because the widget is an ordinary
constructor call, its arguments can be dynamic.

```julia
@bind hi Slider(10:10:200)
@bind n  Slider(1:hi)          # range depends on another binding — updates live
```

Read the bound variable from any other cell and it re-runs when the control changes:

```julia
using CairoMakie; set_theme!(theme_dark())
lines(1:n, sin.(range(0, 4π, n)))
```

## Widget catalog

| Constructor | Renders | Value |
| --- | --- | --- |
| `Slider(range)` / `Slider(lo, hi; step)` | slider | number |
| `RangeSlider(range)` / `RangeSlider(lo, hi; step)` | two-thumb slider | `(lo, hi)` NamedTuple, always sorted and in bounds |
| `NumberField(default; min, max)` | number input | number |
| `Checkbox(default)` / `Toggle(default)` | checkbox / switch | `Bool` |
| `TextField(default)` / `TextArea(default; rows)` | text input | `String` |
| `Select(options)` / `Radio(options)` | dropdown / radio group | chosen option |
| `MultiSelect(options)` / `MultiCheckBox(options)` | multi-select / checkbox group | `Vector` |
| `ColorPicker(default)` | color picker | hex `String` |
| `DateField()` / `TimeField()` | date / time picker | `String` |
| `FileUpload(; accept, maxbytes)` | file picker / drop target | `UploadedFile`, or `nothing` until something is uploaded |
| `Button(label)` | action button | click count |
| `TableSelect(data)` | clickable [table](tables.md) | clicked row as a `NamedTuple` (or `nothing`) |
| `playhead(anim)` | [animation](animation.md) player (driven) | current frame index |

`RangeSlider` binds one interval rather than two numbers, so the reader cannot cross the ends:

```julia
@bind span RangeSlider(400:4000; default = (1500, 1800), label = "region")
lo, hi = span            # destructures · span.lo / span.hi by name
```

`FileUpload` stores the reader's bytes under the notebook's `datadir()` and binds an `UploadedFile`
with `.path` (a real path you can read), `.name`, `.size` and `.mime`:

```julia
@bind datafile FileUpload(; accept = ".csv", label = "Data")
datafile === nothing ? md"Upload a file to begin." : CSV.read(datafile.path, DataFrame)
```

`accept` filters the picker. It is a convenience, not a guarantee, so validate what you got.
`FileUpload` is also one of the few write paths an [app-mode](app-mode.md) visitor is allowed, which
makes it the way a reader gets data into an app.

### Labelled options

Any option may be a bare value or a `value => label` pair. As soon as one is a pair, the bound
variable is a `Choice`: it compares, hashes, prints and interpolates as its value, so it drops into
arithmetic and dictionary keys unchanged, while `.value`, `.label` and `.index` reach the parts.
`MultiSelect` and `MultiCheckBox` bind a `Selection`, an ordered read-only map of those pairs.
`Radio` renders markdown and `$math$` in its labels.

`Button` pairs with [`@onclick`](live-updates.md) to run an action on click. `TableSelect` renders
any [`slate_table`](tables.md)-compatible data and binds the row you click; `playhead` is a
*driven* control that receives an animation's current frame so another cell can react to playback.

Every widget takes a `label` keyword except `Button`, whose text is its first positional argument.
The value **reconciles** across re-runs: re-running a bind cell updates the widget's range/options
but keeps the user's current value (unless its type or domain changed).

`MultiSelect` is the compact dropdown, for a long option list; `MultiCheckBox` is the checkbox list,
for a small discrete set.

!!! tip "Insert a control fast"
    Press **⌘K** and type "bind" to insert any of these as a snippet — at the cursor of the
    selected code cell, or into a fresh cell.

## Gallery

Each control as it renders in a cell.

#### Slider
`Slider(0:100; default = 42, label = "samples")`

![widget: Slider](./assets/widget-slider.png)

#### NumberField
`NumberField(0, 100, 12; label = "count")`

![widget: NumberField](./assets/widget-numberfield.png)

#### Checkbox
`Checkbox(true; label = "I agree")`

![widget: Checkbox](./assets/widget-checkbox.png)

#### Toggle
`Toggle(true; label = "stream", on = "Live", off = "Paused")`

![widget: Toggle](./assets/widget-toggle.png)

#### TextField
`TextField("Ada"; label = "name")`

![widget: TextField](./assets/widget-textfield.png)

#### TextArea
`TextArea("…"; label = "notes")`

![widget: TextArea](./assets/widget-textarea.png)

#### Select
`Select(["red", "green", "blue"], "green"; label = "color")` — the default is the second
*positional* argument (as with `Radio`/`MultiSelect`); `label` is a keyword.

![widget: Select](./assets/widget-select.png)

#### Radio
`Radio(["S", "M", "L"], "M"; label = "size")`

![widget: Radio](./assets/widget-radio.png)

#### MultiSelect
`MultiSelect(["x", "y", "z"], ["x", "z"]; label = "tags")`

![widget: MultiSelect](./assets/widget-multiselect.png)

#### MultiCheckBox
`MultiCheckBox(["a", "b", "c"], ["b"]; label = "flags")`

![widget: MultiCheckBox](./assets/widget-multicheckbox.png)

#### ColorPicker
`ColorPicker("#56d364"; label = "tint")`

![widget: ColorPicker](./assets/widget-colorpicker.png)

#### DateField
`DateField("2026-06-05"; label = "date")`

![widget: DateField](./assets/widget-datefield.png)

#### TimeField
`TimeField("09:30"; label = "time")`

![widget: TimeField](./assets/widget-timefield.png)

#### Button
`Button("Run")`

![widget: Button](./assets/widget-button.png)

## Mixed cells

A cell can declare binds *and* run code. The control(s) render at the top and the cell's
output below — useful for a self-contained "control + plot" unit.

```julia
@bind freq Slider(1:20)
using CairoMakie; set_theme!(theme_dark())
lines(0:0.01:1, sin.(2π*freq .* (0:0.01:1)))
```

## Control strips and the palette

A bound control can be **surfaced** in another cell's *control strip* — drag its grip into a
code cell to place it near the output it drives (it can live in several cells at once; the
variable stays single-sourced). Arrange controls into columns by dropping between them.

Open the **🎛 Controls palette** (top bar or ⌘K) to see every `@bind` declared across the
notebook, its live value, and where it's surfaced. Click a chip to jump to its defining
cell; drag a chip into a cell to surface it; drop it back on the palette to remove it.

![The Controls palette listing every @bind widget with its live value](./assets/controls-palette.png)

## How it stays in sync

Changing a control posts the new value to its defining cell, which restales and recomputes the
readers (see [Reactive Cells](reactivity.md)). While you drag, updates are rate-limited and
coalesced so the kernel isn't flooded; releasing flushes the final value. Every widget bound
to the same variable — strip copies included — stays in lockstep.

## Updating without recomputing

Reading a bound variable makes a cell a *reader*, so every change reruns it. For a cheap cell that
is exactly right. For an expensive one — or a figure whose whole point is that it persists, like an
interactive WebGL scene with a camera you have positioned — rebuilding on every tick is the wrong
shape: the work is redone and the state is lost.

`bind_observable(:name)` gives you the control's value as an `Observable` instead. The name is
quoted, so it is data rather than a read and the cell never restales; the value is pushed into the
Observable and whatever is listening updates in place.

```julia
@bind decay Slider(0.0:0.05:1.5; default = 0.35)

let                                   # runs once — `decay` appears only as a quoted name
    d = bind_observable(:decay)
    t = range(0, 4π; length = 400)
    fig = Figure()
    lines(fig[1, 1], t, lift(v -> @.(exp(-v * t) * sin(4t)), d))
    fig
end
```

The Observable is **cell-local**: a fresh one per run, released when the cell reruns. That is what
makes an ordinary `lift` on top of it safe — it dies with the cell, so nothing accumulates across
reruns. An Observable you create yourself and keep alive across runs does not have that property,
and listeners on it will stack.

Because the name is quoted there is no dependency edge, and cells in a batch evaluate in parallel —
so a control declared in a *different* cell may not exist yet when the observing cell runs. Declare
the `@bind` in the same cell as the figure to remove the race. It does not reintroduce the rerun: a
control reruns its declaring cell only when the changed name is among that cell's reads, and a
quoted name is not a read.

## Controls drawn somewhere else

`hidden(…)` wraps a widget to say the notebook should not draw it: no row in its `@bind` cell, no
entry in a surfaced strip, and it is not offered by the 🎛 palette.

```julia
@bind phase hidden(Slider(0.0:0.1:6.3))
```

It is otherwise an ordinary control. It holds a value, coerces it, fires `@onchange`, feeds
`bind_observable`, and remains a parameter in a static export. Only the chrome is suppressed.

This is for when something else is drawing the control — a widget inside a figure, a custom panel —
and you want one control rather than two copies of it that can drift apart. Extensions reach the
same controls through the execution context; see [Writing an Extension](extensions.md).

## In a static export

An exported HTML page has no Julia behind it, so by default a control renders as real markup and
stays disabled. Marking the expression it drives with `@replay` makes it work anyway: the export
computes every position the control can take and ships the results with the page. See
[Offline interactivity](replay.md).

## Custom widgets

Not enough with the built-ins? You can register your own widget type in JavaScript and bind it with
`@bind x custom_widget("kind")` — see [Front-end Extensions](frontend-extensions.md).
