try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 📄 Print formatting

You author in Markdown and LaTeX; the PDF is typeset by **Typst**. Markdown cells go through the
`cmarker` package, math through `mitex`. There is no Typst cell kind and you never write a `.typ`
file — but two markers let a cell address the screen and the page separately.

**How to use this notebook:** read it here, then **☰ → Export → PDF** and compare. Each section
below says what should differ. Nothing here needs a package, so it opens cold in a second.
"""

#%% md id=h_math
@md raw"""
## Math: four spellings, one result

KaTeX (on screen) and mitex (in print) now accept the same four delimiters. All four of these
should render as maths in **both** views:

- Dollars, inline: $E = mc^2$
- Dollars, display: $$\frac{\alpha}{\beta} + \nabla \times \vec{v}$$
- Parens, inline: \(E = mc^2\)
- Brackets, display: \[ \frac{\alpha}{\beta} + \nabla \times \vec{v} \]

The bracket forms are rewritten to the dollar forms on the way to Typst, because `cmarker` only
recognizes dollars. Before that, they reached the PDF as literal text with the backslashes eaten —
prose that read correctly on screen and came out as rubbish in print.
"""

#%% md id=h_printonly
@md"""
## Writing for one surface only

Two HTML comments are honoured. Being comments, neither disturbs the other view.

`raw-typst` passes its body through as **Typst code**. The screen sees a comment and shows
nothing; the PDF gets the real thing. The next line inserts a coloured note that exists only
in print:

<!--raw-typst #block(fill: rgb("#fff4d6"), inset: 8pt, radius: 3pt)[This box is typeset by Typst and appears only in the PDF.] -->

Above this sentence, the PDF has a pale box that the browser does not.
"""

#%% md id=h_screenonly
@md"""
## …and the mirror

`typst-begin-exclude` is the inverse: the enclosed markdown renders normally on screen and is
dropped from the PDF. Useful for a live control, a note about interactivity, or anything that
only makes sense in a running notebook.

<!--typst-begin-exclude-->
> **Screen only.** This blockquote is visible in the live notebook and absent from the PDF.
> If you are reading this in a PDF, the exclusion did not work.
<!--typst-end-exclude-->

Both markers are all there is. Typst written loose in a cell is escaped and printed as ordinary
text, because a markdown cell is CommonMark first — the next section shows that.
"""

#%% md id=h_literal
@md"""
## Loose Typst is not executed

This line contains `#text(fill: red)[not executed]` and it prints verbatim in both views. The
same is true of a bare `#pagebreak()` or a Typst call inside an HTML tag: without the
`raw-typst` marker it is text, not code.

That is deliberate. A markdown cell shouldn't silently become a program because it happened to
contain a `#`.
"""

#%% md id=h_admon
@md"""
## Admonitions

Typst's markdown renderer is plain CommonMark and has no admonition rule, so each callout is
lowered to a titled blockquote on the way in. The colour band is the one thing that does not
survive the trip.

!!! note "Rendered both ways"
    On screen this is a coloured callout. In the PDF it is a blockquote whose first line is the
    bold title.

!!! warning "Also lowered"
    Any category works, including ones you coin yourself.
"""

#%% md id=h_table
@md raw"""
## Tables and code

GFM tables cross intact, with alignment:

| construct | screen | PDF |
|---|:---:|---:|
| `$…$` | KaTeX | mitex |
| `raw-typst` | hidden | typeset |
| `typst-begin-exclude` | shown | dropped |

Fenced code is left exactly alone — including anything that *looks* like maths. This block shows
the bracket delimiters rather than typesetting them, which is the point:

```latex
\[ this is a code listing, not an equation \]
```

Inline code behaves the same: `\(also literal\)`.
"""

#%% md id=checklist
@md raw"""
## What to check in the exported PDF

1. All four math spellings in **Math** are typeset — none appear as raw text or stray brackets.
2. A pale box appears under **Writing for one surface only**, and nothing appears there on screen.
3. The blockquote in **…and the mirror** is present on screen and **absent** from the PDF.
4. **Loose Typst is not executed** prints its Typst call as text in both views.
5. The admonitions are blockquotes with bold titles.
6. The `latex` code block still shows its backslashes and brackets.

## A note on the saved file

Like any Slate notebook this one is also a runnable script — `julia typst_print.jl` prints the
prose and runs the code. Prose carrying LaTeX makes that slightly awkward, and the file shows how
it is handled: look at the source and you'll see most cells wrapped in `@md"""…"""` while the ones
containing backslash commands use `@md raw"""…"""`.

The reason is that Julia validates escape sequences inside an ordinary string literal even where
it does not process them, so `\frac` is accepted (`\f` is an escape letter) while a summation or
an integral is a syntax error. Which commands trip it is pure accident. The raw literal accepts
any backslash, and is used only for the cells that need it, so ordinary notebooks keep the
familiar skin and their diffs stay quiet.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 5a55a2d9-1534-467e-a953-17a62cb24dea
# ╚═╡
