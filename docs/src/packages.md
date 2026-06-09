# Packages & environments

A notebook running on a gate worker manages its own dependencies from the UI — open the
**📦 Packages** panel (☰ → Packages).

## The environment model: fork-and-extend

A notebook never pollutes the repo it lives in, and it always runs in **one** consistent,
fully-resolved environment (never a stacked `LOAD_PATH`, so there are never two versions of a
shared dependency). It runs in one of three modes, chosen automatically:

- **Base** — the notebook has no packages of its own, so it runs **directly in the enclosing
  project**. Zero overhead, exactly like a plain script.
- **Forked** — the first time you add a package, the notebook **forks** off its parent into
  its own environment (kept under the depot), seeded from the parent (the parent package is
  `dev`'d in and its deps + `Manifest` are copied, versions preserved) and resolved as one
  environment. Adds and pins re-resolve the whole env, so the notebook can **override the
  base**. The parent's `Project.toml` is never touched.
- **Detached** — no enclosing project, so the notebook environment *is* everything.

If the enclosing project's `Manifest.toml` later changes, a forked notebook **auto-resyncs**
on open: it re-seeds from the parent and re-adds your packages (preserved), keeping it one
consistent environment.

## The panel

The panel shows the environment with **provenance**, in two groups:

- **Notebook** — the packages this notebook added (removable ✕).
- **Parent project** `‹dir›` — inherited from the enclosing project (read-only).

The status line reads e.g. `3 notebook · 41 from parent` (or `· detached`).

- **Add** — `Pkg.add` in the notebook's own env (forking first if needed), then the notebook
  re-runs so a `using` lights up live. The first add can take a while (seed + resolve +
  precompile); the kernel dot pulses while it works.
- **Remove** — `Pkg.rm` from the notebook env, confirmed first. Parent rows can't be removed.

## The reproducibility footer

When a notebook has packages of its own, the `.jl` carries an auto-maintained, human-readable
footer recording just that **delta** (the packages beyond the parent), with versions + UUIDs:

```julia
# ╔═╡ Slate.env · notebook packages (auto-maintained — manage via the package panel)
#   CSV 0.10.14 336ed68f-0bac-5ca0-87d4-7b16caf5d00b
#   Plots 1.40.5 91a5bcdd-7333-5406-abb4-e4a6da0a7c5c
# ╚═╡
```

It round-trips cleanly (it's never parsed as a cell), only changes when your packages change,
and is **reconstructed on open**: if you `git clone` a notebook whose env dir is gone, opening
it rebuilds the environment from the footer (seed from parent, add the pinned packages). For a
*fully* self-contained artifact — the complete `Project` + `Manifest` + local source — see
[Export → self-contained `.jl`](export.md#self-contained-single-source-jl).

## Requirements

Package management needs a **gate worker** — i.e. the notebook lives inside a Julia project (or
is detached but gate-capable). For an in-process notebook the panel is read-only and explains
why: there is no notebook environment to manage.

## Under the hood

The UI calls `GET /api/<id>/packages` (provenance via the set difference *active − parent −
parent-package*) and `POST /api/<id>/package` (`{op: "add"|"rm", name}`). Operations run
through worker tools (`__slate_pkg`, and `__slate_fork` / `__slate_sync_parent` /
`__slate_reconstruct` for the env lifecycle); on success the notebook restales and re-runs and
the footer refreshes.
