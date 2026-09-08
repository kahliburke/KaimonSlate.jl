# Live updates

[Reactive cells](reactivity.md) recompute when their *inputs* change. Sometimes you want the
opposite grain: a cell that **pushes** values over time, an action that fires on a **button
click**, or a recompute driven by an **external file** changing on disk. These helpers cover
those imperative, live-updating patterns — without breaking the reactive guarantees.

## `@reactive` — a value you push to

`@reactive name = init` declares a live value you update imperatively. Reading it subscribes.
Writing it restales the cells that read it, and their dependents, recomputes those, and pushes a
patch of just those cells to the browser.

What does not re-run is the cell or handler that did the writing, which is why a streaming handler
does not loop on itself.

A reactive is **written on the kernel that declared it** and read anywhere. A cell running on a
[region](regions.md) can read one, but writing it there throws. Put the write in a cell on the
declaring kernel.

![A cell reading a reactive value, rendering it as a live chart that redraws on every push](./assets/reactive-gauge.png)

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

![A Button widget rendered in a cell, the control an @onclick handler is bound to](./assets/onclick-button.png)

`@onchange control (body)` is the same idea for any control: run a body on each change, with the
new value bound, without recomputing the cell — `@onchange n (level[] = n)`.

### Driving a control from code — `set_bind`

`set_bind(:name, value)` moves one of the notebook's own `@bind` controls from cell code, taking the
same path a browser change takes: the control moves, its reader cells recompute, and the value
persists. Use it to keep a control from contradicting what the app is showing, for example snapping a
slider to a value a handler settled on. It is a no-op if nothing declares `name`, and inert on a
standalone script run.

### `pause` and `cancel`

Inside an `@onclick`/`@onchange` body, use **`pause(seconds)`** instead of `sleep` — it's a
*cancellable* sleep. A new click (or an explicit `cancel(:name)`) stops the run at its next
checkpoint, which is either a `pause` **or** a reactive write. A streaming loop that only pushes
values is therefore interruptible too; only a handler with neither is not.

`cancel` names the **control** whose handler is running, not the reactive value being written:

```julia
cancel(:go)     # stop the handler registered with @onclick go, at its next pause
```

A cancelled handler unwinds with **`Cancelled`**. A handler that catches its own errors should
branch on it, or it will report the reader pressing Stop as a computation failure:

```julia
try
    ...
catch e
    msg[] = e isa Cancelled ? "Stopped." : sprint(showerror, e)
end
```

Two ordering facts decide whether a handler is correct. Every reactive write is a cancellation
checkpoint, so a cancelled run throws at the first write after the cancel: put anything you do not
want discarded last. And the checkpoint fires only once per run, so writes in `catch` and `finally`
still land, and cleanup always runs.

## Progressive results from a long cell — `slate_refresh`

A long-running cell can push results *as it computes them*. Calling `slate_refresh(:data)` from
the cell's async task restales the **readers** of `data` (not the producer), recomputes them, and
pushes a lightweight live update — so streaming and async workflows stay reactive without
re-triggering themselves. (Also surfaced in [Reactive Cells](reactivity.md#Async-updates).)

## Progress bars — `slate_progress`

Report progress `0..1` from a running cell to drive its progress bar and the floating run chip.
`@progress` / `@withprogress` loops drive it automatically.

```julia
for i in 1:n
    slate_progress(i / n; msg = "step $i")
    heavy(i)
end
```

![A cell mid-run with its progress bar filled part way, labelled "reducing 23/40 · 57%", and the cell badged RUNNING](./assets/progress-bar.png)

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
  `.jl`](export.md#Self-contained-single-source-.jl) or a published page carries them.
- The [Files panel](project-files.md) is where you browse and edit those files without leaving the
  browser.

## Writing files out

`save_asset(name, data)` is the write side of `@asset`. It registers generated bytes with the page
and returns an `AssetRef` that interpolates to a stable page-local path, which client-side code
loads with `Slate.asset(ref)`. It takes a `String`, a `Vector{UInt8}` (give `mime`), a numeric array
(packed as raw binary a `Float32Array` can read directly), or any JSON-able value.

`download_button(name, data; label)` puts those exact bytes behind a button the reader can press:

```julia
io = IOBuffer(); CSV.write(io, results)
download_button("results.csv", String(take!(io)); label = "Download the results")
```

This matters most in an [app](app-mode.md), where a reader has no cell to run and no filesystem to
look in, so anything they are meant to keep needs an explicit way out. The bytes ride along inlined
in a static export, so the button still works on a page with no kernel behind it.

!!! tip "Front-end code — `@use`, `WebPage`, `slateCall`"
    Beyond files, a notebook can ship its own JavaScript, import ES modules with `@use`, call Julia
    from the browser, and register custom widgets. See [Front-end Extensions](frontend-extensions.md).
