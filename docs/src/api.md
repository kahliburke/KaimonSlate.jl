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

## Everything else

```@autodocs
Modules = [KaimonSlate]
```
