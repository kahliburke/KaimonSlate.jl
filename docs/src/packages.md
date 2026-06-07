# Packages

A notebook running on a gate worker can manage its own dependencies from the UI — open the
**📦 Packages** panel (☰ → Packages).

## What it does

- **Lists** the notebook project's direct dependencies (name + version).
- **Adds** a package — `Pkg.add` in the worker's active project, then re-runs the notebook so
  a `using` lights up live.
- **Removes** a package — `Pkg.rm`, confirmed first.

Adding may take a while the first time (the package is installed and precompiled); the kernel
dot pulses while it works.

## Requirements

Package management needs a **gate worker** — i.e. the notebook lives inside a Julia project.
For an in-process notebook (no enclosing project) the panel is read-only and explains why:
there is no notebook-local environment to manage.

::: warning Operates on the enclosing project
Add/remove currently mutate the notebook's **enclosing** project (`Project.toml` /
`Manifest.toml`) — the worker's active environment. A Pluto-style *notebook-local* layered
environment is a planned refinement.
:::

## Under the hood

The UI calls `GET /api/<id>/packages` (which uses `project_deps`) and `POST /api/<id>/package`
(`{op: "add"|"rm", name}`). The op runs through a worker tool (`__slate_pkg`) and, on success,
restales and re-evaluates the notebook so dependent cells pick up the change.
