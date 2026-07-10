#%% md id=ttl title
# Slides Gauntlet
## Every presentation & citation feature, one deck
QA Notebook · Kaimon Slate

#%% md id=abs abstract
A QA notebook for the document/presentation surface: role-tagged front matter, heading-driven
slide segmentation, explicit `slide`/`notes` tags, every citation form, display math, and a
figure — exported as both an article and a 16:9 deck.

#%% md id=sec_cites
## Citations, every form

Normal [@knuth1984], with a locator [@lamport1994, p. 7], grouped [@knuth1984; @strang2009],
and the prose form: @strang2009 showed that linear algebra is unreasonably effective.
An email like kahli@example.com must stay literal (undefined keys never convert).

#%% md id=sec_math
## Display math on a slide

Inline $e^{i\pi} + 1 = 0$ and display:

$$\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}$$

#%% code id=fig
using CairoMakie
set_theme!(theme_dark())
let xs = range(0, 4π; length = 300)
    fig = Figure(size = (720, 300))
    ax = Axis(fig[1, 1]; title = "a figure on a slide")
    lines!(ax, xs, sin.(xs) .* exp.(-xs ./ 8); linewidth = 3)
    fig
end

#%% md id=forced slide
## A forced slide break

This cell carries the `slide` tag — it must start a fresh slide even without a heading
change forcing one.

#%% md id=speaker notes
Speaker notes: mention the citation styles toggle, then demo the deck export. This text
must NOT appear on any slide — presenter/notes section only.

#%% md id=sec_close
## The last slide

With {{ 2 + 2 }} interpolated inline, because slides are still reactive cells.

#%% md id=refs bibliography
@book{knuth1984,
  author = {Knuth, Donald E.},
  title = {The {TeX}book},
  publisher = {Addison-Wesley},
  year = {1984}
}
@book{lamport1994,
  author = {Lamport, Leslie},
  title = {LaTeX: A Document Preparation System},
  publisher = {Addison-Wesley},
  year = {1994}
}
@book{strang2009,
  author = {Strang, Gilbert},
  title = {Introduction to Linear Algebra},
  publisher = {Wellesley-Cambridge Press},
  year = {2009}
}
