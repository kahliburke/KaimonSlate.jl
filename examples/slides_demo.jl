try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=cover title
@md"""
# Slate Slideshow Mode
### Reactive notebooks, presented
Kahli Burke · 2026-06-30
"""

#%% md id=summary abstract
@md"""
A quick tour of presentation mode — heading-detected slides, live interactive
content, a synced presenter view, and 16:9 PDF export. Press **▶ Present** (⌘⇧P).
"""

#%% md id=why
@md"""
## Why a slideshow mode?

- Slides are **detected from headings** (each `##` starts one)
- ...or controlled explicitly with a `slide` / `notes` cell tag
- Content stays **live** — charts animate, `@bind` widgets work
"""

#%% md id=n-why notes
@md"""
Open the presenter window (the 🪞 button, or `s`) to see these notes,
the next-slide preview, and a timer. Remember to demo the `@bind` slider.
"""

#%% md id=live
@md"""
## Live and interactive

Drag the slider — the chart recomputes on the slide.
"""

#%% code id=amp
@bind amp Slider(0.2:0.2:3.0; default=1.0, label="amplitude")

#%% code id=wave
x = range(0, 4π; length=200)
echart(:line, collect(x), amp .* sin.(x); title="amp = $(round(amp; digits=1))",
       smooth=true, showSymbol=false, areaStyle=(;))

#%% md id=fit
@md"""
## Auto-fit

Tall slides shrink to fit the screen (down to a floor, then scroll). This slide
has a lot of content to show the scaling in action.

- one
- two
- three
- four
- five
- six
"""

#%% md id=close slide
@md"""
## Thanks!

Export this deck as a 16:9 PDF from the **☰ → Export PDF (slides)** menu.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = b6eb4b9d-432b-4be0-b4c3-d3914e69d79d
#   format = 2
# ╚═╡
