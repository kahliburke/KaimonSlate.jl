# Publishing

Publishing turns notebooks into **published documents on the web** — a personal site or blog
where each notebook lands at its own URL and a generated front page links to them all — and, at
milestones, into **permanent citable archives**. It's built around a small, durable model so the
same notebook can deploy to GitHub Pages, Cloudflare, Netlify, your own server, or Zenodo without
re-authoring anything.

There are two surfaces:

- **Publish a notebook** — **☰ → ☁ Publish…** in the notebook menu.
- **Manage everything** — the **☁ Publishing** manager on the notebook hub's front page (also
  reachable from **☰ → 🗂 Publishing manager…**).

## The model

| Concept | What it is |
| --- | --- |
| **Document** | One notebook, as a publishable unit. Its identity (`docId`) is embedded in the `.jl` itself, so it survives file moves, renames, and repo changes — the ledger always knows it's the same document. |
| **Site** | A portfolio/blog: **one** local build (`/sites/<name>/`) that gathers **many** documents, newest-first, behind a generated index. Publishing into a site is **additive** — other documents are preserved. |
| **Target** (destination) | Where a site **deploys**: GitHub Pages, Cloudflare Pages, Netlify, S3, R2, or rsync to your own box. A site can have several — its one build syncs to all of them. A site attaches to a target at an optional **subpath**, so several sites can share one repo or bucket. |
| **Secret** | A credential (an API token) a target needs. Stored **only on your machine** (in the config home, `chmod 600`) and referenced by name — secret **values never enter the ledger** or any published output. |
| **Ledger** | The record of what's published where, with history. Kept in a secret GitHub **gist** (or a local file), so it **syncs across your machines** and carries **no secrets**. |
| **Zenodo archive** | A permanent, immutable, **citable DOI** version of a notebook — a separate action from live-site publishing (see [below](#Archive-a-citable-version-Zenodo)). |

The relationship in one line: a **notebook** publishes into a **site**; the site accumulates it
into one build; the site **syncs** that build to its **destination targets**.

Blank subpath means the target's root. Cloudflare Pages and Netlify are root-only. Saving a site is
refused if another site already claims the same target and subpath.

### Copying a notebook copies its identity

Because the `docId` lives in the `.jl`, copying the file gives you two files that are **one
document**: one history, one agent transcript, one published slot. Slate notices and offers two
answers. **☰ → ⑂ Split from copy…** forks this copy into a document of its own, copying the stores so
neither side loses anything. Or keep sharing and silence the notice, which is recorded against this
path so the other copy still gets told.

## Publish a notebook

Open **☰ → ☁ Publish…**. The panel lists your sites. Tick one to add this notebook to it, use **★**
to make the notebook that site's front page, and set:

- **▶ Run live** — embed the reproducible bundle and a launcher so a visitor can rehydrate and run
  the notebook (see [Export → self-contained `.jl`](export.md#Self-contained-single-source-.jl)).
- **Include source** — cell source on the page, or uncheck for a clean reading page.
- **Git history** — with Run live on, ship the project's full history so a visitor can branch and
  open a pull request with matching commits. Off ships a source-only snapshot, which is safer for a
  public page.
- **Outputs** — all, figures only, or none.
- **Theme** — *As-is* (default, keeps the notebook's live palette), or *Light* / *Dark*, which force
  one and re-render native Makie figures to match.
- **Renderer** — how charts are drawn on the published page: *Auto* keeps each chart's own setting,
  *SVG* renders them all as vector.
- **Width** — the content column of the published page; the far end is full width.
- **Document path** (`slug`) — the `/<slug>/` this document lives at; auto-filled from the title.
  Re-publishing the same slug **updates it in place**.

Then press that site's **☁ Publish**. KaimonSlate renders this notebook into the site's local build
at `/sites/<name>/`, then **syncs** the whole build to every destination. When it finishes, a live
URL appears; **Already published** shows where this document currently lives.

Sites themselves, their titles and their destinations are created in the
[Publishing manager](#The-Publishing-manager), linked from the bottom of the panel. The site title and
the new-site destination checklist live in **More export options…**, next to it.

![The Publish panel: the sites this notebook belongs to (each with a front-page star and a ☁ Publish action), the publish options (run-live bundle, source, git history, outputs, theme, width, document path), and an "Already published" column showing where it's live](./assets/publish-panel.png)

!!! tip "A site with no destinations is a local staging area"
    If a site has no destinations yet, publishing just builds it locally — preview it at
    `http://<hub>/sites/<name>/`. Add destinations in the manager and hit **▶ Sync** when you're
    ready to go live. It's the perfect way to get a portfolio looking right before it's public.

### Front page and document listing

By default a site's root is a generated blog index (a card per document, newest first). To author
your own landing page instead, tag a notebook **`home`** and mark where the document listing goes
with a **`docindex`** cell — see [Documents & Citations](documents.md) and
[Cell tags](cell-tags.md#Site-tags). The `home` notebook renders to the site root; the card grid
is injected at the `docindex` cell and refreshed on every publish.

## The Publishing manager

The front-page **☁ Publishing** dashboard is the control room for everything — organized around
your **sites** and **targets**, not individual notebooks.

![The Publishing manager: a Sites section with a portfolio site and its destinations, and a Publish targets section with GitHub Pages, Cloudflare, and Zenodo targets](./assets/publishing-manager.png)

**Sites** — a tile per site, showing its destinations and document count, with:

- **▶ Sync** — redeploy the current build to all destinations (use after editing a site, below).
- **⇅ Arrange & sections** — drag-reorder documents and group them into named sections, then
  re-push.
- **Front page** — which notebook is the `home` page (or a nudge to tag one).
- Add or remove documents, create a **new site**, or delete one.

Deleting a site removes its definition and its local build at `/sites/<name>/`. Deleting a site or a
target also offers to **purge** the deployed side. That genuinely tears down an rsync-serve
destination, stopping its server and removing the served directory. GitHub Pages, Cloudflare, Netlify
and buckets are left live and have to be cleaned up in the host's own console.

**Publish targets** — a tile per target (name + kind + a live link). **+ Add target** to create
one; a target opens as one page with three sections, a single **Save changes** button, and a delete
action at the bottom:

- **Content** — which sites deploy here (for Zenodo, the archived versions).
- **Config** — the target's settings (repo, project id, bucket, URL, …).
- **Policies** — per-kind switches (private repo, mirror-delete, deploy branch, Zenodo sandbox, …).

**⚙ Secrets** — set the API tokens targets need, by reference name. Values are stored only in your
config home (`chmod 600`) and **never** written to the ledger, a gist, or any published page.

The hub's front page also carries a **Sites** strip — a quick launcher for each published site,
with a local **Preview** link and a chip per live destination:

![The front-page Sites strip: a portfolio site card showing 4 docs, 2 destinations, and Preview / GitHub Pages / Cloudflare links](./assets/sites-strip.png)

## Targets (destinations)

Every static-hosting target receives the **same** site build, so you can mirror one portfolio to
several hosts at once.

| Kind | Deploys via | Configure | Credential | Notes |
| --- | --- | --- | --- | --- |
| **GitHub Pages** | force-push to a `gh-pages` branch, Pages enabled | repo, branch, subdir | your **`gh` CLI** login | needs `gh` + `gh auth login`; can create the repo; a private repo's Pages needs GitHub Pro |
| **Cloudflare Pages** | `wrangler pages deploy` | project, account id | Cloudflare API token (secret) | free, unlimited bandwidth; `<project>.pages.dev` |
| **Netlify** | `netlify deploy --prod` | site id | Netlify auth token (secret) | 100 GB/mo free tier |
| **S3** | `aws s3 sync` | `s3://bucket/prefix` | AWS creds (environment/profile) | optional mirror-delete |
| **R2** | `aws s3 sync --endpoint-url …` | dest + R2 endpoint | AWS-style creds | Cloudflare R2 |
| **rsync** | `rsync -az` over ssh | `user@host:/var/www` | your ssh keys | self-hosted |
| **Zenodo** | mints a DOI (not a site host) | deposition id | Zenodo API token (secret) | see [below](#Archive-a-citable-version-Zenodo) |

CLI-based targets (Pages, S3/R2, rsync) use the credentials already on your machine; Cloudflare,
Netlify, and Zenodo take an API token you save as a **secret** and reference by name.

## Sync — one build, many destinations

Publishing (and re-syncing) always deploys **one canonical local build** to **every** destination,
identically. So:

- **Building/staging** writes `/sites/<name>/` locally.
- **Syncing** pushes that exact directory to the remote destinations.

Edits that only touch the local build — **⇅ Arrange & sections**, removing a document — don't go
live until you hit **▶ Sync**, which re-deploys without needing to open a notebook.

## Archive a citable version (Zenodo)

**📄 Archive → mint DOI** deposits the notebook's fully reproducible standalone bundle to
[Zenodo](https://zenodo.org) and mints a **permanent, citable DOI**. Each archive of the same
notebook becomes a **new version** under a shared concept DOI.

The control is in the export dialog, under *Archive a version (Zenodo, permanent DOI)*, reached from
**☰ → ⬆ Export…** or from **More export options…** in the Publish panel. It needs a zenodo target
with its token saved in Secrets.

!!! warning "Permanent and immutable"
    A published Zenodo version **cannot be edited or deleted**. Archive at milestones — a release, a
    paper — not on every tweak. Use a target's **Zenodo sandbox** policy to mint throwaway test DOIs
    first.

## The ledger

The ledger is a small structured record of your documents, targets, sites, and publish history. By
default it lives in a **secret, self-locating GitHub gist** (git-versioned for free), so it
follows you across machines and never forks; without `gh` it falls back to a local file. A no-network
cache paints the front page instantly. Force a backend with `KAIMONSLATE_LEDGER_BACKEND=local|gist`.

A secret gist is unlisted, not access-controlled: anyone with the URL can read it. That is exactly
why the ledger carries **no secrets**, only target config and `secretRef` names.

## From the agent

Under [Kaimon](agent.md), the agent can drive publishing through MCP tools:

Publishing is **site-first** here exactly as it is in the UI: a notebook is built into a site's
canonical local copy, and the site deploys to its destinations.

- **`slate_publish`** — publish a notebook into the site it belongs to (`site=` picks one when it
  belongs to several). `targets=` is the escape hatch for a standalone document that isn't in a site.
  It refuses Zenodo targets: a deposit is immutable, so it is never something that rides along with a
  site push.
- **`slate_archive`** — deposit the standalone bundle to a Zenodo target and mint a DOI. `target=` is
  needed only when several archive targets exist.
- **`slate_site_membership`** — read which sites a notebook belongs to, join or leave one, and
  set/clear it as the site's front page.
- **`slate_site_publish`** — stage and deploy a whole site. Defaults to a **dry run** that returns
  the plan (every member, what ships, what's stale); pass `dry_run="false"` to actually deploy.
- **`slate_sites`** — list, create/update, or delete site definitions and their targets.
- **`slate_publish_targets`** — list, add/update, or delete targets.
- **`slate_publish_history`** — the publish history / ledger view.

Secret **values** are never returned by these tools — only reference names.

## See also

- [Remotes](remotes.md) — the front page's other power feature: run a notebook's worker on a
  remote host, with warm pools and a cache that follows you.
- [Export](export.md) — the self-contained HTML / PDF / reproducible `.jl` outputs a site is built from.
- [Documents & Citations](documents.md) — title/abstract/bibliography front matter and the `home` +
  `docindex` site-authoring tags.
