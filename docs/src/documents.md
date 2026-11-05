# Documents & Citations

A notebook is also a **publishable document**. Beyond code and prose it can carry academic front
matter — a title block, an abstract, a bibliography — and cite sources inline. Every export
target (article/report PDF, slide deck, HTML, a published site) reads the same authored metadata
and places it correctly.

You author document metadata as **ordinary cells** carrying a *role tag* (set with the 🏷
[tag editor](cell-tags.md) or a token in the cell header), in natural reading order. Nothing is
a special syntax — a `title` cell is just a markdown cell that the export hoists.

## Front matter

| Role tag | The cell becomes | Placement on export |
| --- | --- | --- |
| `title` | the title block: `# Title`, then `##`/`###` subtitle, then the first plain line as byline | hoisted to the top |
| `abstract` | an academic abstract | hoisted into the title block |
| `bibliography` | the reference database (see below) | not shown; drives citations + References |

```julia
#%% md id=fm title
# Spectral Methods for the Heat Equation
### A reproducible study
Ada Lovelace · Analytical Engine Lab

#%% md id=abs abstract
We compare Chebyshev and Fourier spectral discretizations on the 1-D heat
equation, and show the reactive notebook that produced every figure.
```

With no `title` cell, the document title falls back to the first markdown `# H1`, then the
filename. The title block also feeds the PDF/HTML title, the [published-site](publishing.md) card,
and the OG social-card metadata.

## Bibliography

Tag a markdown cell `bibliography`. Its body is **either** embedded BibTeX **or** one or more
sources, one per line: a **`.bib` file path** (resolved relative to the notebook and copied into
exports) or the **address of a knowledge base** (see below). One cell cannot hold both: a cell
containing any `@entry{…}` is read as embedded BibTeX and its other lines are ignored. To use both,
write two bibliography cells.

```julia
#%% md id=bib bibliography
@book{knuth1984,
  author = {Donald E. Knuth},
  title  = {The TeXbook},
  year   = {1984},
  publisher = {Addison-Wesley}
}

#%% md id=bibfile bibliography
references.bib
```

In the live notebook, the bibliography renders an adaptive **references card** listing your
entries, with the keys you've actually cited highlighted.

![The live references card listing bibliography entries, cited keys highlighted](./assets/references-card.png)

### A knowledge base's bibliography

A line holding a site's address takes the bibliography of a [Zemi](https://github.com/kahliburke/Zemi.jl)
knowledge base: every paper, upload and record you may read there, keyed as Zemi keys them
(`[@arXiv:2401.01234]`, `[@doc-…]`, `[@rec-…]`).

```julia
#%% md id=kb bibliography
https://kb.example.org
```

The hub fetches it from the site's `api/bib` with your API token, keeps a copy, and checks for a newer
one when the notebook opens and every few minutes after; the notebook works from the copy, offline
too. A line ending in `.bib` is fetched as given, so any BibTeX file on the web works the same way.

A Zemi site needs sign-in. Create a token on the site under **Account → API tokens**, with the
**read** permission (see [Zemi's documentation](https://kahliburke.github.io/Zemi.jl/)); the
references card then shows **Add token** beside the site, which saves it on the hub
(`secrets.json` in the config home) for that host. The token is never written into the notebook. A
Zemi run for one person on this machine takes its local key in the same place.

A library can hold thousands of entries. `[@` asks the hub for the keys matching what you type, and
the card lists only the cited entries once there are more than a few. A PDF, HTML or Markdown export,
and a self-contained `.jl`, carry only the entries the notebook cites.

## Citing in prose

Cite a bibliography key from any **markdown** cell. Typing `[@` autocompletes keys.

| Form | Renders (numeric style) | Use |
| --- | --- | --- |
| `[@knuth1984]` | `[1]` | a normal citation |
| `[@knuth1984, pp. 33-35]` | `[1, pp. 33–35]` | with a page/locator |
| `[@a; @b]` | `[1, 2]` | several at once |
| `@knuth1984` | `Knuth (1984)` | a prose (author–year) mention |

The bare `@key` prose form only converts keys that are actually defined, so an email address or
a stray `@handle` stays literal. On export, citations render **linked** to the References section
and a References list is generated in your chosen style; the live notebook mirrors this with the
references card.

## Citation style

Pick the citation style per notebook in **Settings → Export → Citation style** (persisted as
`bibstyle` in [Settings, under This notebook](settings.md#This-notebook)):

`ieee` · `american-physics-society` · `american-institute-of-physics` · `nature` · `vancouver` ·
`apa` · `chicago-author-date` · `harvard-cite-them-right` · `mla` · `author-year-brackets`

Numeric styles (IEEE, APS, AIP, Nature, Vancouver) render `[1]` and order the References by first
citation. Author–date styles (APA, Chicago, Harvard, MLA) render `(Knuth, 1984)` and order
alphabetically. `author-year-brackets` is Slate's own: it cites as `[Knuth 1984]`, adds `a`, `b`, …
when two works share an author and year, and keys each References entry by the same label.

## Figures

Tag a markdown cell **`caption`** and it captions the output of the cell above it, becoming a
**numbered figure** on export (`Figure N.`). Give it a `label=` to cross-reference it, and `for=` to
caption a cell other than the one directly above:

```julia
#%% md id=cap1 caption label=scaling
Throughput against core count.
```

Refer to it from any markdown cell with `[@fig:scaling]`, the same cross-reference machinery as
citations. That renders as a link in the live notebook and as plain `Figure N` in the PDF.

Figures embed as vectors where possible (CairoMakie → PDF, ECharts → SVG) so they stay crisp in
print. See [Export](export.md) and [Charts & Tables](visualization.md).

!!! tip "From notebook to paper"
    Add a `title` cell, an `abstract` cell, and a `bibliography` cell; cite with `[@key]`; then
    **Export → PDF (Report, two-column)**. The same notebook is your working analysis *and* the
    manuscript that reproduces it.
