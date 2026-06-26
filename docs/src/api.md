# API Reference

KaimonSlate is normally used through its UI and the agent's `slate.*` tools, but the serving
layer is a small public Julia API. Most users only need [`serve_notebook`](#).

## Serving a notebook

```@docs
KaimonSlate.NotebookServer.serve_notebook
KaimonSlate.NotebookServer.start_server
KaimonSlate.NotebookServer.stop_server
```

## Hub (multiple notebooks)

A `Hub` is one HTTP server hosting many notebooks.

```@docs
KaimonSlate.NotebookServer.start_hub
KaimonSlate.NotebookServer.open_notebook!
KaimonSlate.NotebookServer.close_notebook!
KaimonSlate.NotebookServer.stop_hub
```

## Top-level

```@autodocs
Modules = [KaimonSlate]
```

The sections below document the internal submodules. These are not part of the stable public
API — they're listed for contributors and the curious. Each `@autodocs` block picks up every
remaining docstring in its module (the entry points above are not repeated).

## Notebook server

The HTTP/WebSocket serving layer, live-notebook state, history, and agent integration.

```@autodocs
Modules = [KaimonSlate.NotebookServer, KaimonSlate.NotebookServer.SlateHistory]
```

## Report engine

The reactive evaluation core — parsing `.jl` notebooks, the dependency graph, kernels, cells,
binds, and paged tables.

```@autodocs
Modules = [KaimonSlate.ReportEngine]
```

## Report rendering

Turning evaluated cells into HTML/markdown output.

```@autodocs
Modules = [KaimonSlate.ReportRender]
```
