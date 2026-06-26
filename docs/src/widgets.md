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
| `Slider(range)` / `Slider(lo, hi; step)` | range slider | number |
| `NumberField(default; min, max)` | number input | number |
| `Checkbox(default)` / `Toggle(default)` | checkbox / switch | `Bool` |
| `TextField(default)` / `TextArea(default; rows)` | text input | `String` |
| `Select(options)` / `Radio(options)` | dropdown / radio group | chosen option |
| `MultiSelect(options)` | multi-select | `Vector` |
| `ColorPicker(default)` | color picker | hex `String` |
| `DateField()` / `TimeField()` | date / time picker | `String` |
| `Button(label)` | action button | click count |

All accept a `label` keyword. The value **reconciles** across re-runs: re-running a bind cell
updates the widget's range/options but keeps the user's current value (unless its type or
domain changed).

::: tip Insert a control fast
Press **⌘K** and type "bind" to insert any of these as a snippet — at the cursor of the
selected code cell, or into a fresh cell.
:::

## Gallery

Each control as it renders in a cell:

**`Slider(0:100; default = 42, label = "samples")`**
![widget: Slider](./assets/widget-slider.png)

**`NumberField(0, 100, 12; label = "count")`**
![widget: NumberField](./assets/widget-numberfield.png)

**`Checkbox(true; label = "I agree")`**
![widget: Checkbox](./assets/widget-checkbox.png)

**`Toggle(true; label = "stream", on = "Live", off = "Paused")`**
![widget: Toggle](./assets/widget-toggle.png)

**`TextField("Ada"; label = "name")`**
![widget: TextField](./assets/widget-textfield.png)

**`TextArea("…"; label = "notes")`**
![widget: TextArea](./assets/widget-textarea.png)

**`Select(["red", "green", "blue"], "green"; label = "color")`** — the default is the second
*positional* argument (as with `Radio`/`MultiSelect`); `label` is a keyword.
![widget: Select](./assets/widget-select.png)

**`Radio(["S", "M", "L"], "M"; label = "size")`**
![widget: Radio](./assets/widget-radio.png)

**`MultiSelect(["x", "y", "z"], ["x", "z"]; label = "tags")`**
![widget: MultiSelect](./assets/widget-multiselect.png)

**`MultiCheckBox(["a", "b", "c"], ["b"]; label = "flags")`**
![widget: MultiCheckBox](./assets/widget-multicheckbox.png)

**`ColorPicker("#56d364"; label = "tint")`**
![widget: ColorPicker](./assets/widget-colorpicker.png)

**`DateField("2026-06-05"; label = "date")`**
![widget: DateField](./assets/widget-datefield.png)

**`TimeField("09:30"; label = "time")`**
![widget: TimeField](./assets/widget-timefield.png)

**`Button("Run")`**
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
