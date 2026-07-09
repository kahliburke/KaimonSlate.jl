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
| **Target** (destination) | Where a site **deploys**: GitHub Pages, Cloudflare Pages, Netlify, S3, R2, or rsync to your own box. A site can have several — its one build syncs to all of them. |
| **Secret** | A credential (an API token) a target needs. Stored **only on your machine** (in the config home, `chmod 600`) and referenced by name — secret **values never enter the ledger** or any published output. |
| **Ledger** | The record of what's published where, with history. Kept in a private GitHub **gist** (or a local file), so it **syncs across your machines** and carries **no secrets**. |
| **Zenodo archive** | A permanent, immutable, **citable DOI** version of a notebook — a separate action from live-site publishing (see [below](#archive-a-citable-version-zenodo)). |

The relationship in one line: a **notebook** publishes into a **site**; the site accumulates it
into one build; the site **syncs** that build to its **destination targets**.

## Publish a notebook

Open **☰ → ☁ Publish…**. Choose (or create) the **site** to publish into and set:

- **Site title** — the heading on the site's blog front page (set once; kept on later publishes).
- **Document path** (`slug`) — the `/<slug>/` this document lives at; auto-filled from the title.
  Re-publishing the same slug **updates it in place**.
- **Theme** — *Dark* (matches the UI) or *Light* (publication).
- **Source** — include cell source, or uncheck for a clean reading page.
- **Runnable** — embed the reproducible bundle + a "Run live" launcher so a visitor can rehydrate
  and run the notebook (see [Export → self-contained `.jl`](export.md#self-contained-single-source-jl)).
- **Git history** — ship the project's full git history in the bundle (for branch/PR with matching
  commits), or a source-only snapshot (safer for a public page).
- **Destinations** — for a **new** site, tick where it should deploy (Pages, Cloudflare, …). An
  existing site's destinations are managed in the [manager](#the-publishing-manager).

Click **☁ Publish into site**. KaimonSlate renders this notebook into the site's local build at
`/sites/<name>/`, then **syncs** the whole build to every destination. When it finishes, a live
URL appears; **Already published** shows where this document currently lives.

![The Publish panel: outputs, theme, source/runnable/git-history options, the site to publish into with its destinations, a Zenodo archive action, and site title / document path](./assets/publish-panel.png)

!!! tip "A site with no destinations is a local staging area"
    If a site has no destinations yet, publishing just builds it locally — preview it at
    `http://<hub>/sites/<name>/`. Add destinations in the manager and hit **▶ Sync** when you're
    ready to go live. It's the perfect way to get a portfolio looking right before it's public.

### Front page and document listing

By default a site's root is a generated blog index (a card per document, newest first). To author
your own landing page instead, tag a notebook **`home`** and mark where the document listing goes
with a **`docindex`** cell — see [Documents & Citations](documents.md) and
[Cell tags](cell-tags.md#site-tags). The `home` notebook renders to the site root; the card grid
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

**Publish targets** — a tile per target (name + kind + a live link). **+ Add target** to create
one; drill into any target for three tabs:

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
| **Zenodo** | mints a DOI (not a site host) | deposition id | Zenodo API token (secret) | see [below](#archive-a-citable-version-zenodo) |

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

From the Publish panel, **📄 Archive → mint DOI** deposits the notebook's fully reproducible
standalone bundle to [Zenodo](https://zenodo.org) and mints a **permanent, citable DOI**. Each
archive of the same notebook becomes a **new version** under a shared concept DOI.

!!! warning "Permanent and immutable"
    A published Zenodo version **cannot be edited or deleted**. Archive at milestones — a release, a
    paper — not on every tweak. Use a target's **Zenodo sandbox** policy to mint throwaway test DOIs
    first.

## The ledger

The ledger is a small structured record of your documents, targets, sites, and publish history. By
default it lives in a **private, self-locating GitHub gist** (git-versioned for free), so it
follows you across machines and never forks; without `gh` it falls back to a local file. It carries
**no secrets** — only target config and `secretRef` names — and a no-network cache paints the
front page instantly. Force a backend with `KAIMONSLATE_LEDGER_BACKEND=local|gist`.

## From the agent

Under [Kaimon](agent.md), the agent can drive publishing through MCP tools:

- **`slate_publish`** — publish a notebook to one or more targets.
- **`slate_publish_targets`** — list, add/update, or delete targets.
- **`slate_publish_history`** — the publish history / ledger view.

Secret **values** are never returned by these tools — only reference names.
