#%% md id=title title
# Reactive Notebooks as Publishable Documents
### Front-matter roles in Slate
Kahli Burke · Seaworthy AI · 2026-06-30

#%% md id=abstract abstract
This notebook demonstrates Slate's document-metadata **roles** — `title`, `abstract`,
and `bibliography` — authored as ordinary cells in natural reading order. Each role
renders in place in the live notebook, and every export target (article PDF, slide
deck, HTML) interprets the role for placement: title and abstract are hoisted into the
title block, and the bibliography is collected for the references section.

#%% md id=intro
## Introduction

A Slate notebook is a reactive document. With front-matter roles it is *also* a
publishable artifact — the same cells you compute with become a typeset article. Prior
work on literate computing [@knuth1984literate] and reproducible research motivates
keeping prose, code, and citations in one live document.

#%% code id=setup
using Statistics
samples = randn(1000)
(; mean = round(mean(samples); digits=3), sd = round(std(samples); digits=3))

#%% code id=hist
let edges = -4:0.5:4, h = [count(x -> edges[i] <= x < edges[i+1], samples) for i in 1:length(edges)-1]
    echart(:bar, string.(round.(edges[1:end-1]; digits=1)), h; title = "Sample histogram")
end

#%% md id=histcap caption label=fig:hist
Histogram of the $n = 1000$ standard-normal draws — a `caption`-tagged cell binds to the
figure above (auto-numbered, and referenceable as `[@fig:hist]`). Captions are ordinary
markdown, so **bold**, `code`, and math like $\mu \approx 0$ all render.

#%% md id=method
## Method

We draw $n = 1000$ samples from a standard normal and summarize them. The interactive
table below is computed live; in the exported PDF it is frozen to a static table.

#%% code id=tbl
slate_table((x = 1:5, x2 = (1:5).^2, sqrt_x = round.(sqrt.(1:5); digits=3)))

#%% md id=discussion
## Discussion

Citations link to the bibliography in the live notebook and render in the chosen `bibstyle`
on export. Each row shows what you **type** (left) and how it **renders** (right):

| You write | Renders |
| --- | --- |
| `[@turing1936computable]` | [@turing1936computable] |
| `[@knuth1984literate, p. 97]` | [@knuth1984literate, p. 97] |
| `[@knuth1984literate; @turing1936computable]` | [@knuth1984literate; @turing1936computable] |
| `@knuth1984literate` (prose) | @knuth1984literate |

(The left column is in `backticks`, so it stays literal; the right column is a real citation.)

#%% md id=styles
## Citation styles

The reference style is a per-notebook setting (**Settings → Citation style**, persisted in
the `Slate.config` footer as `bibstyle`). Slate uses Typst's CSL engine, so the same
notebook can render in any of these — switch and re-export to compare:

| `bibstyle` | citation | reference list |
| --- | --- | --- |
| `ieee` *(default)* | `[1]` | numbered |
| `apa` | (Knuth, 1984) | author–date |
| `chicago-author-date` | (Knuth 1984) | author–date |
| `chicago-notes` | footnote¹ | notes + bibliography |
| `mla` | (Knuth) | works cited |
| `nature` | superscript¹ | numbered |
| `vancouver` | (1) | numbered |
| `harvard-cite-them-right` | (Knuth, 1984) | author–date |

#%% md id=refs bibliography
references.bib

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   parallel = false
#   bibstyle = ieee
# ╚═╡
