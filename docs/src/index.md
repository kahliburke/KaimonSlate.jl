```@raw html
---
layout: home

hero:
  name: KaimonSlate.jl
  text: Reactive Julia notebooks, in the browser
  tagline: A live, reactive notebook that edits a plain .jl file — with @bind widgets, ECharts & Makie figures, a built-in timeline, and an AI agent that builds cells alongside you.
  actions:
    - theme: brand
      text: Get Started
      link: getting-started
    - theme: alt
      text: The AI Agent
      link: agent
    - theme: alt
      text: GitHub
      link: https://github.com/kahliburke/KaimonSlate.jl

features:
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="18" cy="18" r="3"/><circle cx="6" cy="6" r="3"/><path d="M6 21V9a9 9 0 0 0 9 9"/></svg>
    title: Reactive by construction
    link: reactivity
    details: Cells form a dependency DAG. Change a value and every downstream cell restales and recomputes automatically — no manual "run all", no stale state hiding in the kernel.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/></svg>
    title: Real @bind widgets
    link: widgets
    details: Widgets are ordinary Julia constructors — Slider(1:hi), Toggle, Select, ColorPicker, … — so their arguments can be dynamic. Bind a control in one cell, read it in others, and watch them re-render live.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2a2 2 0 0 1 2 2c0 .74-.4 1.39-1 1.73V7h1a7 7 0 0 1 7 7h1a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1h-1v1a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-1H1a1 1 0 0 1-1-1v-3a1 1 0 0 1 1-1h1a7 7 0 0 1 7-7h1V5.73c-.6-.34-1-.99-1-1.73a2 2 0 0 1 2-2z"/><circle cx="8" cy="14" r="1"/><circle cx="16" cy="14" r="1"/></svg>
    title: An AI agent that builds cells
    link: agent
    details: A chat pane drives the notebook through the same tools you do — adding, editing, and running cells one at a time. Scope a turn to a single cell with ✨, reference cells by @id, and pick Sonnet, Opus, Haiku, or a local Ollama model.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v18h18"/><path d="m19 9-5 5-4-4-3 3"/></svg>
    title: Interactive figures
    link: visualization
    details: ECharts for interactive, in-browser charts that animate on reactive updates; CairoMakie for static scientific figures. Both flow through one image interface — so the agent can see your plots, and exports embed them.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v5h5"/><path d="M3.05 13A9 9 0 1 0 6 5.3L3 8"/><path d="M12 7v5l4 2"/></svg>
    title: A built-in timeline
    link: history
    details: Every edit is captured to a durable, content-addressed history. Scrub the rail, diff any checkpoint, restore non-destructively, or ▶ replay the whole buildup of the notebook.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>
    title: Plain .jl, shared with your editor
    link: architecture
    details: The notebook IS a .jl file. Edits round-trip through it, so VS Code, git, and the agent all see the same source. Export a self-contained HTML document (or print to PDF) when you're done.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242"/><path d="M12 12v9"/><path d="m16 16-4-4-4 4"/></svg>
    title: Publish to the web
    link: publishing
    details: Turn notebooks into a site or blog — each lands at its own URL behind a generated front page. One build deploys to GitHub Pages, Cloudflare, Netlify, S3, or your own server, and you can archive a citable DOI to Zenodo at milestones.
---
```

# KaimonSlate.jl

KaimonSlate is a reactive notebook for Julia that runs in your browser and edits a plain
`.jl` file. It is built as a [Kaimon](https://github.com/kahliburke/Kaimon.jl) extension:
cells evaluate in a per-notebook gate worker, the browser stays in sync over server-sent
events, and an AI agent can drive the notebook through the same tool surface you use.

Every cell's output always reflects its current inputs. Cells declare what they read and
write; KaimonSlate builds a dependency graph and recomputes exactly the cells affected by a
change — so **nothing silently goes stale**.

## Quick start

Install [Kaimon](https://github.com/kahliburke/Kaimon.jl) — the recommended runtime, which gives
each notebook its own worker and powers the AI agent — then install the **`slate` app** from the
Pkg REPL:

```julia-repl
pkg> app add KaimonSlate      # puts a `slate` launcher on your PATH
```

Run it:

```sh
slate my_analysis.jl          # start the hub, open the notebook, show a status TUI
```

On first run `slate` offers to register as a Kaimon extension (so the agent gets the `slate.*`
tools). No Kaimon? `slate --own` runs standalone. See [Installation](installation.md) and
[Getting Started](getting-started.md).

![A reactive KaimonSlate notebook — a frequency slider and a toggle driving a live ECharts chart](./assets/hero.png)
