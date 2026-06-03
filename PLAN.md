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

- [x] **Phase 0 — Extraction.** `src/report/*` → `~/devel/KaimonSlate.jl`; wrapper
      module `KaimonSlate`; `Project.toml` (HTTP=2, Otera/CommonMark/EE/CairoMakie);
      `start_server` (non-blocking) split out of `serve_notebook`. Package loads +
      precompiles; **145 tests pass**; serves the demo end-to-end from the package.
- [ ] **Phase 2 — gate-worker eval + single-server hub** (we skip an in-process-hub
      interim; ambitious path):
  1. **Kernel abstraction** — refactor `eval.jl` behind `Kernel`; keep current behavior
     as `InProcessKernel`.
  2. **Capture preamble** — extract `_eval_capture` into injectable worker code (Base64-only).
  3. **GateKernel** — spawn per-notebook worker session via `Main.Kaimon`; project
     discovery via `Base.current_project`; inject preamble; dispatch `execute_via_gate`.
  4. **Notebook hub** — `id → (LiveNotebook, kernel)`; per-notebook SSE listeners + watcher.
  5. **Notebook-scoped routes** — `/n/<id>`, `/api/<id>/*`; index page at `/`.
  6. **SPA** — derive `<id>` from the URL, prefix API/EventSource calls; index/switcher UI.
  7. **Extension wiring** — `kaimon.toml` ([extension] namespace=slate, module=KaimonSlate,
     tools_function=create_tools, shutdown_function=on_shutdown, tui_file); register in
     `~/.config/kaimon/extensions.json`.
  8. **Lean the core deps** — drop CairoMakie/plotting from KaimonSlate (they live in
     each notebook's project now); worker needs only Base64.

## Open / later

- Streaming stdout during long cells (gate PUB → SSE) — the gate already streams; wire
  it through per-notebook SSE.
- Worker lifecycle: idle shutdown, restart-on-crash (Kaimon's session monitor may cover this).
- Static export (ECharts in `render.jl`) — pre-existing TODO, carried over.
- Standalone (`InProcessKernel`) is a fallback; the extension path is primary.
