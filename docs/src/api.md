# API Reference

KaimonSlate is normally used through the [`slate` app](installation.md), its UI, and the agent's
`slate.*` tools. The serving layer below is a small public Julia API for **embedding** the hub in
your own scripts — the app is the everyday entry point.

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

## Exports

The names `using KaimonSlate` brings into scope. Their docstrings live in the submodules below, but
these are the public spellings.

```@docs
KaimonSlate.expand
KaimonSlate.standalone!
KaimonSlate.export_app
KaimonSlate.app_defaults
KaimonSlate.register_extension
```

## Configuration accessors

The persisted settings behind [Running the Hub](hub.md), readable and settable from Julia.

```@autodocs
Modules = [KaimonSlate]
```

## Extension SDK

`SlateExtensionsBase` is the separate, dependency-light package an extension builds against — see
[Writing an Extension](extensions.md). It is public API: unlike the submodules below, these are the
names a third-party package is meant to use.

```@autodocs
Modules = [SlateExtensionsBase]
```

## The notebook API

The helpers you call from inside a cell — `slate_table`, `echart`, `animate`, `@bind`, `@replay`,
`save_asset` and the rest — are public, and their guide pages are [Charts](visualization.md),
[Tables](tables.md), [Widgets](widgets.md), [Animation](animation.md),
[Live Updates](live-updates.md) and [Offline Interactivity](replay.md).

Their docstrings are rendered below under **Report engine**, because that is the module they live in.
Everything else in that section, and the two sections after it, is internal: the serving and
rendering layers, listed for contributors and the curious.

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

## Publish ledger

The record behind [Publishing](publishing.md): documents, sites, targets and events, and the gist
and local backends that persist them.

```@autodocs
Modules = [KaimonSlate.PublishLedger]
```

## Memo store

The content-addressed store behind [Memoization & Caching](memoization.md): manifests, blobs,
pinning and garbage collection.

```@autodocs
Modules = [KaimonSlate.NotebookServer.MemoStore]
```

## Effect store

Durable per-cell declared-effect records, keyed by cell source digest.

```@autodocs
Modules = [KaimonSlate.EffectStore]
```

## State homes

Where Slate keeps its config, data and cache, as described under
[Configuration](hub.md#Where-Slate-keeps-its-state).

```@autodocs
Modules = [KaimonSlate.SlateHome]
```
