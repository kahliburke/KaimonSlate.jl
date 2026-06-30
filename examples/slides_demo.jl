#%% md id=cover
# Slate Slideshow Mode
### Reactive notebooks, presented

Kahli Burke · 2026-06-30

A quick tour of presentation mode — press **▶ Present** (or ⌘⇧P).

#%% md id=why
## Why a slideshow mode?

- Slides are **detected from headings** (each `##` starts one)
- ...or controlled explicitly with a `slide` / `notes` cell tag
- Content stays **live** — charts animate, `@bind` widgets work

#%% md id=n-why notes
Open the presenter window (the 🪞 button, or `s`) to see these notes,
the next-slide preview, and a timer. Remember to demo the `@bind` slider.

#%% md id=live
## Live and interactive

Drag the slider — the chart recomputes on the slide.

#%% code id=amp
@bind amp Slider(0.2:0.2:3.0; default=1.0, label="amplitude")

#%% code id=wave
using KaimonSlate: echart, series
x = range(0, 4π; length=200)
echart(:line; x=collect(x), title="amp = $(round(amp; digits=1))") |>
    e -> series(e, :line, amp .* sin.(x); name="sin", smooth=true, area=true)

#%% md id=fit
## Auto-fit

Tall slides shrink to fit the screen (down to a floor, then scroll). This slide
has a lot of content to show the scaling in action.

- one
- two
- three
- four
- five
- six

#%% md id=close slide
## Thanks!

Export this deck as a 16:9 PDF from the **☰ → Export PDF (slides)** menu.
