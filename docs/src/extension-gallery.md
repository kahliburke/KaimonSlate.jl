# The Extensions gallery

Slate ships with controls, charts and tables built in. **Extensions** add the rest: 3-D globes,
computer algebra, diagram languages, domain widgets. The gallery is where you find them and install
them, without leaving the notebook.

Open it with **⌘K → Extensions**, or **☰ → 🧩 Extensions**.

![The Extensions gallery: searchable list on the left, the selected extension on the right](./assets/extensions-gallery.png)

## Finding something

The left column lists everything in the curated registry. Three things narrow it:

- **Search** matches the name, tagline and description.
- **Category chips** (`visualization`, `controls`, `math`, …) filter to one kind of thing.
- **All / Installed / Updates** switch what the list is *about* — everything available, only what
  this notebook already has, or only what has a newer version waiting.

Those last three are views over one list rather than separate screens, so an extension you've
installed is the same card in the same place, just with a different action on it.

Listings vary in how much their authors have filled in. Some carry a tagline, screenshots and a
starter snippet; others show only the description harvested from their README. A sparse card isn't a
worse package, only a quieter one.

## What a card tells you

![An extension's detail: what it provides, how to start, and the actions available](./assets/extensions-detail.png)

Alongside the description you may find:

- **Provides** — the concrete things the extension adds: `@bind` controls, cell toolbar buttons,
  ⌘K commands, output renderers.
- **Getting started** — the few lines that put it to work.
- **Example notebook** — a runnable demo in the extension's own repository.

## Installing

**Install** adds the package to *this notebook's* environment, exactly as the
[Packages panel](packages.md) would. The notebook is paused while its worker resolves and
precompiles — minutes, for something with a large dependency stack — then the cells re-run.

Two things are worth knowing before you click.

**Installing doesn't activate it.** A package has to be loaded with `using`, so after a successful
install the gallery offers to drop a starter cell in for you. Accepting is the fastest route from
"installed" to "working". If you decline, add `using ThePackage` yourself.

**The first install also adds a registry.** Extensions come from a package registry that sits
alongside Julia's General registry, and adding one affects **every project on your machine**, not
just this notebook. The gallery says so before doing it, and the button reads *Add registry &
install* rather than *Install*. It's a one-time step; later installs don't repeat it.

On a notebook running in a [region](regions.md), the registry is added to the *remote* depot — the
one that notebook actually resolves against.

## Keeping up to date

An installed extension whose registry version has moved on is flagged with an amber **update**
badge, and the **Updates** view collects them.

![The Updates view: an installed extension with a newer version available](./assets/extensions-updates.png)

The card shows the move it will make — `0.1.2 → 0.1.3` — and **Update** performs it, re-running the
notebook afterwards. An extension inherited from the enclosing project is updated there rather than
in the notebook's own environment.

Update information is only as fresh as the catalog, which is cached for several hours so that
opening the gallery doesn't hit the network every time. **Check for updates** at the bottom refetches
it immediately.

## When you're offline

The gallery still opens. It falls back to the last catalog it fetched, and failing that to the
registry already in your Julia depot — which knows every extension's name and version, just not its
description or screenshots. The footer says which of the three you're looking at, so an empty or
sparse list is never ambiguous.

## What an extension can add

Once loaded, an extension isn't confined to a corner of the UI. It can contribute:

- **`@bind` controls** that behave like the built-in ones
- **Output renderers**, so returning one of its values from a cell draws something
- **Cell toolbar buttons** on every cell's header
- **⌘K commands**, badged with the package name — so typing that name in the palette shows
  everything it added, which is the quickest way to find your way around something you just installed
- **Markdown fence renderers**, so a fenced block in prose renders through it

## Where they come from

The registry is curated: an extension is listed because it was registered there. Installing one runs
an ordinary `Pkg.add`, and the package is ordinary Julia code with the same access to your machine as
anything else you install. Treat it with the same judgement.

If you want to publish your own, see [Writing an Extension](extensions.md) — registering the package
is the only requirement to be listed.
