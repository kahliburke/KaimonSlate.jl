# KaimonSlate.jl

A warm-session, **reactive** Julia notebook with a live browser UI — packaged as a
[Kaimon](https://github.com/…/Kaimon.jl) extension.

Edit a cell or drag a `@bind` widget and only the *downstream* cells recompute
(pruned dependency graph). Makie/MIME figures and interactive ECharts render inline.
The source round-trips to a plain `.jl` file, so the agent and the browser share one
source of truth.

Runs **out-of-process on HTTP 2.0** — independent of Kaimon core's HTTP version; the
two talk over the Gate (ZMQ).

## Standalone

```julia
using KaimonSlate
serve_notebook("notebook.jl"; port = 8765)   # blocks; open http://127.0.0.1:8765
```

## As a Kaimon extension

Register this project in `~/.config/kaimon/extensions.json` (or the Extensions tab).
Kaimon manages the subprocess and exposes `slate.open` / `slate.list` / `slate.close`
to the agent. Each notebook runs in its own gate worker, pinned to the Julia project
the notebook file lives in (`Base.current_project`).

See [PLAN.md](PLAN.md) for the architecture and roadmap.

## Status

Phase 0 (extraction) complete: 145 tests pass, serves end-to-end. Phase 2
(per-notebook gate workers + single-server hub) in progress — see PLAN.md.
