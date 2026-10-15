try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=cover bg=aurora layout=title
@md"""
# Slides Studio
### Every deck feature, one notebook
"""

#%% md id=n_cover notes
@md"""
Testbed for the presentation work: layouts, builds, reactive steps, transitions, media, timing,
recording. Each slide exercises one feature.
"""

#%% md id=builds
@md"""
## Builds, without copies

::: incremental
- Each item arrives on its own click
- The slide keeps its layout as they appear
- Nothing on the slide is duplicated to make the build
:::

. . .

A pause marker reveals everything after it in one step.
"""

#%% md id=effects transition=zoom
@md"""
## Step effects

::::: columns
:::: column
::: {.step .fade-left}
**fade-left** slides in from the left
:::
::: {.step .fade-right}
**fade-right** slides in from the right
:::
::: {.step .zoom}
**zoom** grows into place
:::
::: {.step .blur}
**blur** comes into focus
:::
::::
:::: column
::: {.step .highlight}
**highlight** lights up on its step
:::
::: {.step .strike}
**strike** is crossed out on its step
:::
::: {.step .fade-out}
**fade-out** leaves on its step
:::
::: {.incremental .dim}
- **dim** keeps the current item bright
- and quiets the ones before it
:::
::::
:::::
"""

#%% md id=columns
@md"""
## Columns

:::: columns
::: {.column width="40%"}
### Left
- a narrower column
- set by `width="40%"`
:::
::: column
### Right
The right column takes the rest. Columns sit side by side on the slide and stack in the notebook
only if the page is narrow.
:::
::::
"""

#%% md id=reactive
@md"""
## A figure that builds itself

Each click adds the next odd harmonic; the chart is recomputed, not swapped.
"""

#%% code id=k_bind hidecode
@bind k SlideSteps(5)

#%% code id=fourier
let x = range(0, 4π; length = 600)
    y = sum(sin.((2j - 1) .* x) ./ (2j - 1) for j in 1:(k + 1))
    echart(:line, collect(x), 4 / π .* y; showSymbol = false, lineStyle = (width = 3,))
end

#%% md id=section bg=nebula layout=section transition=slide
@md"""
## Part two
### Media and timing
"""

#%% md id=video
@md"""
## Video on a slide

:::: columns
::: {.column width="58%"}
![autoplay loop](slides_media/mandelbrot.mp4)
:::
::: column
::: incremental
- Image syntax, a clip path
- `autoplay` starts it when the slide comes up
- `loop`, `muted`, `nocontrols` as needed
:::
:::
::::
"""

#%% md id=bgvideo bg=slides_media/mandelbrot.mp4 bgdim=0.45 layout=center transition=zoom
@md"""
## Full-bleed background

### `bg=clip.mp4 bgdim=0.45` on the cell
"""

#%% md id=morph_a
@md"""
## Morph

The heading on the next slide has the same text, so it glides into its new place.
"""

#%% md id=morph_b layout=center transition=fade
@md"""
## Morph
"""

#%% md id=timed auto=3
@md"""
## Timed

This slide advances by itself after three seconds.
"""

#%% md id=close bg=aurora layout=title
@md"""
# Thanks
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 52415fcf-743c-4d4a-98a8-b334482df07b
#   format = 2
# ╚═╡
