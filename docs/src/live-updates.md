# Live updates

[Reactive cells](reactivity.md) recompute when their *inputs* change. Sometimes you want the
opposite grain: a cell that **pushes** values over time, an action that fires on a **button
click**, or a recompute driven by an **external file** changing on disk. These helpers cover
those imperative, live-updating patterns — without breaking the reactive guarantees.

## `@reactive` — a value you push to

`@reactive name = init` declares a live value you update imperatively. Reading it subscribes;
writing it pushes to every subscriber and re-renders them live — no cell re-run, no manual refresh.

```julia
#%% code id=level
@reactive level = 0      # a live Int, initially 0

#%% code id=gauge
echart(:bar, ["level"], [level[]]; title = "live level")   # reads level[] → updates on every push
```

`level[]` reads the current value; `level[] = v` pushes a new one. It's the building block for
streaming readouts and progress meters that update between (or during) cell runs.

!!! tip "The macro names the value for you"
    `@reactive level = 0` expands to `level = reactive(:level, 0)`. The explicit `reactive(:name, init)`
    form still works, but the macro derives the name from the variable — so the symbol that routes
    updates can never drift out of sync with the binding.

## Buttons and actions — `@onclick`

A `Button` widget's value is its click count, but usually you want a click to *run something*
rather than recompute a cell. `@onclick` binds a handler to a button; the cell **does not
recompute** — the body fires directly, and a **new click cancels the still-running prior run**.

```julia
#%% code id=go
@bind go Button("Sweep")

#%% code id=run
@onclick go for v in 0:2:100
    level[] = v      # push to the live value above — the gauge animates
    pause(0.1)       # a cancellable sleep (see below)
end
```

`@onchange control (body)` is the same idea for any control: run a body on each change, with the
new value bound, without recomputing the cell — `@onchange n (level[] = n)`.

### `pause` and `cancel`

Inside an `@onclick`/`@onchange` body, use **`pause(seconds)`** instead of `sleep` — it's a
*cancellable* sleep. A new click (or an explicit `cancel(:name)`) stops the run at its next
`pause`. This is what makes a long sweep interruptible instead of runaway.

```julia
cancel(:level)     # cooperatively stop the running handler at its next pause
```

## Progressive results from a long cell — `slate_refresh`

A long-running cell can push results *as it computes them*. Calling `slate_refresh(:data)` from
the cell's async task restales the **readers** of `data` (not the producer), recomputes them, and
pushes a lightweight live update — so streaming and async workflows stay reactive without
re-triggering themselves. (Also surfaced in [Reactive Cells](reactivity.md#async-updates).)

## Progress bars — `slate_progress`

Report progress `0..1` from a running cell to drive its progress bar and the floating run chip.
`@progress` / `@withprogress` loops drive it automatically.

```julia
for i in 1:n
    slate_progress(i / n; msg = "step $i")
    heavy(i)
end
```

## Reacting to files — `@asset`

`@asset "path"` reads a file **relative to the notebook's project directory**, and — because the
path is a literal in the source — the file becomes a **first-class reactive input**. KaimonSlate
watches it: when the file changes on disk (you edit it in another editor, an agent regenerates
it), every cell that reads it via `@asset` restales and recomputes, and the change is pushed to
the browser instantly — the same live patch as a `@bind` change.

```julia
#%% code id=data
rows = @asset "data/measurements.csv"    # re-reads + recomputes when the file changes on disk
```

- `@asset "path"` returns the file's contents as a `String`; `@asset bytes "path"` returns raw
  bytes for binary data.
- The path must be a **string literal** to be tracked (a computed path — `readfile(x)` — is
  invisible to the watcher; that's the dynamic caveat).
- Paths resolve against the notebook's project dir, so an exported [self-contained
  `.jl`](export.md#self-contained-single-source-jl) or a published page carries them.

!!! tip "Front-end code — `@use`, `WebPage`, `slateCall`"
    Beyond files, a notebook can ship its own JavaScript, import ES modules with `@use`, call Julia
    from the browser, and register custom widgets. See [Front-end Extensions](frontend-extensions.md).
