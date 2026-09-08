try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Web cells

A `#%% web` cell holds HTML, CSS and JS in their own panes, with `{{ }}` pulling live
notebook values straight in.
"""

#%% code id=data
@bind bars Slider(3:12; default = 7, label = "bars")
accent = "#56d364"
heights = [round(40 + 55 * abs(sin(i / 1.7)); digits = 1) for i in 1:bars]

#%% web id=webcell
@web(html"""
<div id="chart" role="img" aria-label="bar heights"></div>
<p id="cap">{{ bars }} bars, tallest {{ round(maximum(heights); digits = 1) }}</p>
""",
css"""
#chart { display: flex; align-items: flex-end; gap: 6px; height: 110px; }
#chart div { width: 22px; background: {{ accent }}; border-radius: 3px 3px 0 0; }
#cap { color: #9aa; font: 500 13px system-ui; margin: 8px 0 0; }
""",
js"""
const hs = {{ heights }};
const box = root.querySelector('#chart');
box.innerHTML = '';
for (const h of hs) {
  const d = document.createElement('div');
  d.style.height = h + 'px';
  box.appendChild(d);
}
echo(`drew ${hs.length} bars`);
""")

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 06f9308b-afa9-4f12-99a7-8166b3e6b86a
# ╚═╡
