try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 🧩 AFM widgets in Slate

**SlateAFM** hosts **Anywidget Front-End Modules (AFM)** — framework-agnostic ES modules that
`export default { initialize?, render? }` and drive a host `model`. It implements the AFM contract on
Slate's own seams: `provide_frontend!` injects the host shim, `provide_assets!` serves the modules, and
the bound value becomes the widget's **traits dict**.
"""

#%% code id=use
using SlateAFM

#%% md id=h_counter
@md"""
## Counter — the canonical AFM module

`afm_example("counter.js")` is a self-contained AFM module (no imports): `model.get/set("count")` +
`save_changes()` on click, and `on("change:count")` to redraw. Bound below to the trait dict `st`.
"""

#%% code id=counter
@bind st afm(afm_example("counter.js"); count = 0)

#%% md id=counter_read
@md"""
The bound value is a live dict: **`st` = {{st}}**. Click the button — `save_changes()` commits the trait
and this line re-renders reactively, exactly like any `@bind`.
"""

#%% md id=h_slider
@md"""
## Slider — multiple traits

`slider.js` drives a `value` trait live while dragging and reads a `label` trait. Multiple observable
traits over the same bound dict.
"""

#%% code id=slider
@bind sl afm(afm_example("slider.js"); value = 25, min = 0, max = 100, label = "gain")

#%% md id=slider_read
@md"""
**`sl` = {{sl}}** — drag the slider and the `value` trait commits live.
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = a1f0c2d4-5e6b-47a8-9c1d-3b2e4f6a7c88
# ╚═╡
