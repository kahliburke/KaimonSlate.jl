# KaimonSlate — reactive notebook as a Kaimon extension

A warm-session, **reactive** Julia notebook with a live browser UI. Extracted from
Kaimon's `src/report/` into a standalone package so it can adopt **HTTP 2.0**
without dragging Kaimon core (HTTP 1.x) along. Runs as a **Kaimon extension**:
managed subprocess, own environment, talks to Kaimon over the Gate (ZMQ).

Rhymes with KaimonGate, on purpose.

---

## Why a separate package (not `lib/` in the monorepo, not `src/report/`)

One Julia environment resolves exactly **one** version of each package — you cannot
run HTTP 1.x and 2.x together. The report builder wants HTTP 2.0 (current release);
Kaimon core stays 1.x until a full audit. A separate package gets its own env (own
HTTP) **and** runs out-of-process, so the two never share an HTTP stack. They
communicate over the Gate (ZMQ), never HTTP.

`src/report/` was never wired into the Kaimon module (only a `/tmp` launcher loaded
it), so the only coupling was the shared `Project.toml`. Clean to lift out.

---

## Architecture (three layers)

```
┌─ KaimonSlate extension process ────────────────┐         ┌─ gate worker (per notebook) ─┐
│  single HTTP 2.0 server, ONE port              │  ZMQ    │  julia --project=<nb project> │
│  • view: SPA + index page (switch notebooks)   │ ◀─────▶ │  Kaimon.Gate.serve()          │
│  • reactive orchestration:                     │  eval   │  evals cell source +          │
│    parse, dep graph (ExpressionExplorer),      │         │  rich-captures (stdout, MIME, │
│    staleness, pruned recompute ordering, render│         │  figures→png, echarts spec)   │
│  • notebook hub: id → LiveNotebook + worker    │         │  own packages (CairoMakie…)   │
└────────────────────────────────────────────────┘         └───────────────────────────────┘
              ▲ MCP tools (slate.*) over the Gate to Kaimon ▲
```

- **One server, one port, many notebooks.** Routes are notebook-scoped: `/n/<id>`
  serves the SPA, `/api/<id>/state`, `/api/<id>/cell/{cid}`, `/api/<id>/events`
  (per-notebook SSE). `/` is an index page (Pluto-style notebook switcher).
- **Per-notebook gate worker.** Each notebook's cells eval in their **own gate
  process** → crash/loop isolation (restart one without touching others) and
  **per-notebook package environments**.
- **Control plane = `slate.*` MCP tools** over ZMQ: `open(path)`, `list()`,
  `close(path)`. `open` returns `http://127.0.0.1:<port>/n/<id>`.

### Kernel / frontend split

MIME/figure capture must happen where the live value lives → **in the worker**.
So the eval+capture logic runs gate-side; everything else stays server-side.

| Server-side (extension process) | Worker-side (gate process) |
|---|---|
| hybrid `.jl` parse, cell model | eval cell source in a module |
| dep graph (ExpressionExplorer), staleness, ordering | capture stdout |
| markdown render (CommonMark/OteraEngine) | capture richest MIME (text/html, image/png figures via Base64) |
| HTTP server, SSE hub, notebook registry | capture ECharts spec (raw Dict; server JSON-encodes) |
| `@bind` widget model + value assignment | return serialized `CellOutput` NamedTuple |

The worker needs **only Base64** (stdlib) beyond the notebook's own deps — the
capture preamble (`__slate_eval(source)`) is injected into the worker session once;
the worker never depends on KaimonSlate.

---

## Dependency model (no reinvented resolver)

A notebook's environment **is** the Julia project it lives in.

- Resolve via `Base.current_project(dirname(abspath(notebook)))` — walks up for a
  `Project.toml`, exactly like `julia --project=@.`. Spawn the worker with
  `--project=<that dir>`. A notebook at `proj/notebooks/foo.jl` inherits `proj`'s deps.
- **Standalone notebooks (no enclosing project): not supported, by design.** Error
  clearly ("place this notebook inside a Julia project"). Pluto's bespoke per-notebook
  package management caused friction; we don't reinvent it — Julia's environments
  already solve this.

---

## Eval dispatch — reuse Kaimon, don't reinvent

The gate client + session spawner already exist in Kaimon (`gate_client.jl`,
`session_manager.jl`). KaimonSlate runs as an extension, so `Main.Kaimon` is present
in its subprocess (LOAD_PATH includes Kaimon's project). The `GateKernel` therefore:

1. `proj = Base.current_project(dirname(abspath(path)))` — error if `nothing`.
2. Spawn a Kaimon **managed session** pinned to `proj` (reuse `session_manager`).
3. Inject the capture preamble (`__slate_eval`) into the session once.
4. Per cell: `Main.Kaimon.execute_via_gate("__slate_eval(\$src)"; session=id)` →
   deserialize the rich `CellOutput`.

`CellOutput` fields (stdout::String, mime chunks, echarts Dict, value_repr::String,
exception, backtrace, duration_ms) are all serialization-friendly — figures travel
as base64 PNG strings.

### Pluggable kernel

`Kernel` interface with two impls:
- **`InProcessKernel`** — today's isolated-module eval. Used standalone (no Kaimon).
- **`GateKernel`** — per-notebook worker session via `Main.Kaimon`. Used as an extension.

Default: `GateKernel` when `Main.Kaimon` is available, else `InProcessKernel`.

---

## Status

- [x] **Phase 0 — Extraction.** `src/report/*` → `~/devel/KaimonSlate.jl`; wrapper module
      `KaimonSlate`; `Project.toml` (HTTP=2, Otera/CommonMark/EE/CairoMakie); `start_server`
      (non-blocking) split from `serve_notebook`. Loads/precompiles; serves the demo. (`ea94a66`)
- [x] **Kernel abstraction** — `eval.jl` behind `Kernel` (`prepare!`/`reset!`/`eval_capture`/
      `assign!`); `InProcessKernel` default, threaded through all eval paths. (`ea94a66`)
- [x] **Shared capture** — `capture.jl` `run_capture(mod,src)` → wire-form NamedTuple
      (primitives; no cross-process struct identity). `_eval_capture` wraps it. **158 tests.** (`ea94a66`)
- [x] **SlateWorker** (`src/worker.jl`) — worker-side capture tools (`__slate_eval`/`assign`/
      `reset`) over `KaimonGate.serve(mode=:tcp,…)`; validated in a live session. (`3a59c92`)
- [x] **Extension works end-to-end** — registered in `~/.config/kaimon/extensions.json`;
      `slate.open/list/close` exposed; `slate.open` starts the **HTTP 2.0** server *inside the
      extension process* and serves SPA + SSE. HTTP isolation confirmed (stacked-env gives
      KaimonSlate 2.0; Kaimon loaded but HTTP-dormant; `Main.Kaimon` available).
- [ ] **GateKernel** — the per-notebook gate worker. Currently eval is **in-process
      (`InProcessKernel`) + multi-port** (works, but not the target). Remaining:
  1. `GateKernel <: Kernel`: `prepare!` → `Base.current_project(dir)` (error if none) →
     spawn `SlateWorker` (`julia --project=<proj>`, KaimonGate on LOAD_PATH, fixed TCP port)
     → `Main.Kaimon.connect_tcp!(mgr, "127.0.0.1", port; stream_port)`.
  2. `eval_capture` → `Main.Kaimon._req_send_recv(conn, (type=:tool_call, name="__slate_eval",
     args=Dict("source"=>src)))` → rebuild `CellOutput` from `r.response.value` (wire form).
     `assign!`/`reset!` → `__slate_assign`/`__slate_reset`. Lifecycle: kill worker on close.
  3. `LiveNotebook` picks `GateKernel` when `Main.Kaimon` present, else `InProcessKernel`.
- [ ] **Single-server hub** — one server, one port, many notebooks: `id → (LiveNotebook,
      kernel)`, routes `/n/<id>` + `/api/<id>/*` (per-notebook SSE + watcher), `/` index/switcher.
      SPA derives `<id>` from the URL and prefixes API/EventSource calls. (Replaces multi-port.)
- [ ] **Lean core deps** — once eval is gate-side, drop CairoMakie/plotting from KaimonSlate
      (they live in each notebook's project); worker needs only Base64.

---

## Backlog — UX round (user feedback 2026-06-02; next session)

Extension is working well; next round is mostly **presentation/UX + two reactivity bugs**.
Prioritized:

### P1 — Controls laid out *with* the output (the headline)
The win: bridge "notebook" → "mini-app". `@bind` already splits a **reactive variable** from a
**widget**; today they're glued 1:1 in a cell, and controls render far from the figures they
drive. Decouple presentation from definition — a pure presentation-layer feature, no engine change
(the value POST drives recompute regardless of where the widget renders).
- **A — attach controls to a cell.** An output cell declares which bound controls to surface,
  rendered in a control strip in its own output area. In `.jl`: cell metadata, e.g.
  `#%% code id=plot controls=freq,amp,phase`. Source `@bind` cells get marked "hosted" and
  collapse (variable stays live). → "configure the plot cell to incorporate the controls."
- **B — layout editor.** Drag available bound controls (chips) into a cell's control strip,
  reorder (rows/groups later); persist layout to the cell metadata. The drag-and-drop arrangement.
- **C — app view** (hide code, show controls + outputs only) falls out of A+B.

### P1 — File switcher = the single-server hub
"Switch to a different file" is the hub above (one server, `/n/<id>`, index/switcher page).
Currently each `slate.open` = its own port, no in-UI switcher. Prioritize the hub *with* GateKernel.

### P2 — Bug: scroll/position resets on update
Hypothesis: value-only updates (slider drag) patch DOM in place (`updateStates`, scroll kept), but
**structural** changes (reorder, file-watch version bump) fall back to full `renderAll` → scroll
lost. Matches the intermittence (seen while reordering/editing, not on plain drags). Fix: finer
reconciliation, or save/restore scroll across `renderAll`. (notebook.html)

### P2 — Bug: a bound control sometimes doesn't drive recompute (`phase`)
Hypothesis: a **dependency-inference** gap — recompute fires only if the dep graph links the
consumer (`signal`, uses `phase`) to the bound var. If a bind cell isn't reliably registered as
*defining* its variable, dragging it won't mark the consumer stale. Look at how bind cells register
their def in `deps.jl` / `build_dependencies!`.

### P3 — Drag-reorder drop indicator too subtle
CSS polish in notebook.html — make the drop target a clear, bright insertion line.

## Open / later

- Streaming stdout during long cells (gate PUB → SSE) — the gate already streams; wire through.
- Worker lifecycle: idle shutdown, restart-on-crash (Kaimon's session monitor may cover this).
- Static export (ECharts in `render.jl`) — pre-existing TODO, carried over.
- Standalone (`InProcessKernel`) is a fallback; the extension path is primary.
