try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md raw"""
# Front-end check

Every part of the page the vendored libraries draw: Preact and signals (widgets, web cells), ECharts
(charts), dagre (the dependency graph), KaTeX (maths) and CodeMirror (the editor). Run it after a
library upgrade and drive it from the page.

Inline maths $e^{i\pi} + 1 = 0$, and a display equation:

$$\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}$$
"""

#%% code id=data
xs = collect(0:0.25:10)
labels = ["Mon", "Tue", "Wed", "Thu", "Fri"]
counts = [12, 30, 21, 8, 17]

#%% code id=controls
@bind n Slider(5:5:100; label = "points")
@bind wave Select(["sin", "cos", "square"]; label = "wave")
@bind show_cos Toggle(true; label = "cos too")
@bind span RangeSlider(0:10; default = (2, 8), label = "span")
@bind tint ColorPicker("#6cb6ff"; label = "tint")
@bind note TextField("hello"; label = "note")
@bind picks MultiCheckBox(["a", "b", "c"], ["a"]; label = "picks")
@bind clicks Button("press")

#%% code id=bound
(n = n, wave = wave, show_cos = show_cos, span = span, tint = tint, note = note, picks = picks, clicks = clicks)

#%% code id=chart_reactive
f = wave == "sin" ? sin : wave == "cos" ? cos : (x -> sign(sin(x)))
xr = range(span[1], span[2]; length = n)
s = [series(:line, collect(xr), f.(xr); name = wave, lineStyle = (color = tint,), itemStyle = (color = tint,))]
show_cos && push!(s, series(:line, collect(xr), cos.(xr); name = "cos"))
echart(s...)

#%% code id=chart_titled
echart(series(:line, xs, sin.(xs); name = "sin"), series(:bar, xs, abs.(cos.(xs)) .* 1000; name = "a long series name");
       legend = true, title = "Titled, with a legend", xAxis = (name = "time (s)",), yAxis = (name = "amplitude",))

#%% code id=chart_bar
echart(:bar, labels, counts; title = "Bars")

#%% code id=chart_scatter
echart(:scatter, 1e6 .* randn(300), randn(300); symbolSize = 4, yAxis = (name = "a long y axis name",))

#%% code id=chart_heatmap
echart(:heatmap, ["a", "b", "c", "d", "e"], ["one", "two", "three"], [i * j for i in 1:3, j in 1:5])

#%% code id=chart_pie
echart(:pie, labels, counts; title = "Pie")

#%% code id=chart_sankey
echart(:sankey, [("coal", "grid", 40), ("solar", "grid", 25), ("grid", "homes", 65)])

#%% code id=chart_graph
echart(:graph, ["a", "b", "c", "d"], [("a", "b"), "b" => "c", "c" => "d", "d" => "a"]; title = "Network")

#%% code id=chart_radar
echart(:radar, ["Speed" => 10, "Power" => 10, "Range" => 10], [7, 4, 9])

#%% web id=web_preact
@web(js"""
// Slate's own Preact, hooks and signals, through the import map.
const { html, render } = await import("htm/preact");
const { useState, useEffect } = await import("preact/hooks");
const { signal, computed } = await import("@preact/signals");

const hits = signal(0), doubled = computed(() => hits.value * 2);
function Counter() {
  const [local, setLocal] = useState(0), [mounted, setMounted] = useState(false);
  useEffect(() => { setMounted(true); }, []);
  return html`<div class="fc-web" style="font-family:system-ui">
    <button class="fc-sig" onClick=${() => hits.value++}>signal ${hits}</button>
    <button class="fc-state" onClick=${() => setLocal(local + 1)}>state ${local}</button>
    <span class="fc-doubled"> doubled ${doubled.value}</span>
    <span class="fc-mounted"> ${mounted ? "mounted" : "not mounted"}</span>
  </div>`;
}
render(html`<${Counter} />`, root);
""")

#%% web id=web_bound
@web(js"""
// Re-runs whenever the slider above moves.
const { html, render } = await import("htm/preact");
const n = {{ n }}, note = {{ note }};
render(html`<div class="fc-bound" style="font-family:system-ui">n = <b>${n}</b> · note = <b>${note}</b></div>`, root);
""")

#%% code id=table
slate_table([(day = d, count = c, share = round(c / sum(counts); digits = 3)) for (d, c) in zip(labels, counts)])

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = f237c2d8-e767-44eb-8994-f5e5904d480c
#   format = 2
# ╚═╡
