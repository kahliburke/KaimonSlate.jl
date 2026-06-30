#%% md id=title title
# Reactive Notebooks as Publishable Documents
### Front-matter roles in Slate
Kahli Burke · Seaworthy Machine Learning · 2026-06-30

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

#%% md id=method
## Method

We draw $n = 1000$ samples from a standard normal and summarize them. The interactive
table below is computed live; in the exported PDF it is frozen to a static table.

#%% code id=tbl
slate_table((x = 1:5, x2 = (1:5).^2, sqrt_x = round.(sqrt.(1:5); digits=3)))

#%% md id=discussion
## Discussion

The numeric citation style links each reference to its entry and renders a numbered
list at the end [@turing1936computable]. Author–year styles are a one-word switch.

#%% md id=refs bibliography
references.bib
