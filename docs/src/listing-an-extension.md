# Listing an Extension

Once your extension is written, getting it into the [Extensions gallery](extension-gallery.md) is a
separate job: registering the package, and then filling in as much of the card as you care to.

Registering is the only requirement. Everything below it is optional, and a listing improves one
field at a time.

This is the card the keys on this page produce: the title, tagline and icon in the header, the
screenshots, the Provides list, and the starter snippet.

![An extension's detail card in the gallery: icon and title, tagline, description, a Provides list, a Getting started snippet, and the install action](./assets/extensions-detail.png)

## Register the package

Extensions are listed because they are in `SlateRegistry`, a curated package registry that sits
alongside General.

```julia
using LocalRegistry
register("/path/to/YourPkg.jl"; registry = "SlateRegistry", push = true)
```

Two things to get right: push the package commit before you register, because the registry records a
git tree hash that has to be reachable, and register from a clean working tree.

At that point you are listed, with your name, version, repository and Julia compat bound.

## What gets filled in for you

The catalog build clones your default branch and reads a description out of it, trying in this order:

1. the `description` field of your `Project.toml`
2. the first prose paragraph of your `README.md`, with the title, badges, fenced blocks and banner
   images stripped, truncated at 400 characters
3. the docstring on your module, if the README produced nothing usable

The third is what keeps a package with no README off the bottom tier. It is found by looking for a
`"""..."""` immediately before `module YourPkg`, so a docstring attached with `@doc`, or separated
from the `module` line by a comment, will not be picked up.

Your `[deps]` are read too, and shown as a "Depends on" line.

Nothing else is inferred. A tagline, an icon, a category, a screenshot and the "Provides" list all
come from a file you write.

## Fill in the card

Add `SlateExtension.toml` at your package root, or at `docs/SlateExtension.toml`. If your package
lives in a subdirectory of a monorepo, put it at that subdirectory's root, matching the `subdir` the
registry records.

```toml
title       = "Star Rating"
tagline     = "A ★ rating control for @bind"
description = "Longer prose, if the harvested blurb is not what you want."
icon        = "★"
categories  = ["controls", "examples"]
screenshots = ["https://github.com/you/YourPkg.jl/releases/download/media/shot.png"]
video       = "https://github.com/you/YourPkg.jl/releases/download/media/demo.mp4"
docs        = "https://you.github.io/YourPkg.jl/"
example     = "notebooks/stars_demo.jl"
provides    = ["@bind control: Stars(; max)"]
snippet     = """
using StarRating
@bind rating Stars(; max = 5)
"""
```

| Key | Type | What it does |
| --- | --- | --- |
| `title` | string | Display name. Defaults to the package name. |
| `tagline` | string | One line on the card, above the description. |
| `description` | string | Overrides the harvested blurb. |
| `icon` | string | An emoji (up to 4 characters) or an image URL. |
| `categories` | list | The category chips. Also searched. `category = "x"` works for one. |
| `screenshots` | list | Image URLs, or paths relative to your repository. |
| `video` | string | A demo clip. Your first screenshot becomes its poster and leaves the strip. |
| `docs` | string | The "Documentation ↗" link. |
| `example` | string | A demo notebook, relative to your repository. Linked from the card, and used to generate screenshots. |
| `provides` | list | Free text, one line per thing your extension adds. Nothing derives this. |
| `snippet` | string | The starter cell offered right after install. |

`snippet` is the one worth writing first. Installing a package does not load it, so after a successful
install the gallery offers to drop your snippet into a cell. That is the shortest path a reader has
from "installed" to "working".

A parse error in this file is ignored silently, and your card falls back to the harvested description.

## Screenshots

If your package has an `example` notebook, Slate can photograph it for you. From a KaimonSlate
checkout:

```sh
node docs/generate_extension_assets.mjs --path /path/to/YourPkg.jl
```

It builds a throwaway project, installs whatever your notebook imports, runs it headless in a dark
theme, waits for the notebook to settle, and frames the first cell whose output is a chart, image or
canvas rather than the top of the document. The result lands in a scratch directory outside your
package, so nothing is written into your repository.

`--cell <id>` picks a different cell, `--full` captures the whole page, and `--notebook` overrides the
notebook. It needs `julia` on your `PATH` and Chromium once, via `npx playwright install chromium`.

Videos are not generated. Record those yourself.

## Host your images, do not commit them

Point `screenshots`, `video` and an image `icon` at a URL: a GitHub Pages site, a release asset, or a
CDN. The catalog build mirrors what it can fetch into its own artifact, so the gallery serves one
origin and your host only has to be up when the catalog is built.

Keep each asset under 8 MB. Over that, or if the fetch fails, the build logs it and the card links
your original URL directly instead. Either way the build succeeds and the rest of the card is
unaffected.

Repository-relative paths work as well, and resolve against your default branch. It means committing
binaries that get replaced often, which is why both of the worked examples in this repository use a
release tag instead.

## When it shows up

The catalog rebuilds nightly, and on any push to the registry.

Because prose and images are read from your default branch while versions come from the registry, a
description or screenshot fix needs no release and no registry commit. It lands within a day. The two
are allowed to disagree.

To check: open `https://kahliburke.github.io/SlateRegistry/#YourPkg`, or open the gallery in a
notebook and press **Check for updates**, which bypasses the six-hour client cache.

![The Extensions gallery list: entries with icons, taglines and category chips, one of them showing an installed badge](./assets/extensions-gallery.png)

## Private repositories

If your repository is not readable anonymously, none of the above is published. The build suppresses
the harvested prose and your `SlateExtension.toml` together, and the listing carries only its registry
facts. The package stays installable by name for anyone with access.

Getting prose onto a private package's card needs the registry maintainer to opt it in.

## Curating

The registry maintainer can overlay any of the same fields per package, without waiting on the author.
The overlay wins field by field, so adding a category does not erase an author's screenshots. It also
carries two keys authors do not have: hiding a package from the catalog while leaving it installable,
and opting a private repository's prose into being published.

The overlay files, the catalog builder and how to run it locally are documented in `SlateRegistry`'s
own README.

## See also

- [Writing an Extension](extensions.md) for the code side
- [The Extensions gallery](extension-gallery.md) for what a reader sees
- [Installation](installation.md) for adding the registry by hand
