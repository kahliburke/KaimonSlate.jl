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

Tag a markdown cell `bibliography`. Its body is either **embedded BibTeX** or one-or-more
**`.bib` file paths** (one per line, resolved relative to the notebook and copied into exports).
Inline and external entries can be mixed.

```julia
#%% md id=bib bibliography
@book{knuth1984,
  author = {Donald E. Knuth},
  title  = {The TeXbook},
  year   = {1984},
  publisher = {Addison-Wesley}
}
references.bib
```

In the live notebook, the bibliography renders an adaptive **references card** listing your
entries, with the keys you've actually cited highlighted.

![The live references card listing bibliography entries, cited keys highlighted](./assets/references-card.png)

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

Set the citation style per notebook in **Settings → Citation style** (persisted as `bibstyle` in
the [Notebook config](configuration.md#notebook-config)):

`ieee` · `apa` · `chicago-author-date` · `mla` · `nature` · `vancouver` · `harvard`

Numeric styles (IEEE, Nature, Vancouver) render `[1]` and order the References by first citation;
author–date styles (APA, Chicago, MLA, Harvard) render `(Knuth, 1984)` and order alphabetically.

## Figures

Markdown caption cells become **numbered figures** on export (`Figure N.`), and a reference to a
figure label links to it — the same cross-reference machinery as citations. Figures embed as
vectors where possible (CairoMakie → PDF, ECharts → SVG) so they stay crisp in print. See
[Export](export.md) and [Charts & Tables](visualization.md).

!!! tip "From notebook to paper"
    Add a `title` cell, an `abstract` cell, and a `bibliography` cell; cite with `[@key]`; then
    **Export → PDF (Report, two-column)**. The same notebook is your working analysis *and* the
    manuscript that reproduces it.
