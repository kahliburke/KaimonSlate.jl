try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 🎯 `renderCharts` guard — live check

`renderCharts` (core.js) skips a cell whose chart specs are reference-identical to what it last
rendered, keyed on `(specs, chartRuntime.gen)` — see `_chartsUnchanged`. The guard exists because a
cell reaches the page over two transports and two render paths, so charts were re-applied several
times per run with identical data, each entry paying a `JSON.stringify` of a spec that for a real
figure runs to ~100 KB.

This notebook exercises the three ways that guard can be wrong:

1. **over-skipping** — a chart whose data DID change must still re-render (`dependent`)
2. **under-skipping** — a chart the interaction never touched must be skipped (`independent`)
3. **inline charts** — an `{{ echart }}` placeholder is created by `renderCharts` itself, not by a
   component, and a markdown re-render disposes it (`notebook.js` nulls `_inst`). Skipping such a
   cell would leave a blank chart, so the guard has an escape hatch for it (`inline`)

It needs a browser tab, so it is a MANUAL check, not a CI one. Install the probe with
`slate.eval_js`:

```js
if (!window.__origRC) window.__origRC = window.renderCharts;
window.__probe = {};
window.renderCharts = function (c) {
  const p = window.__probe[c.id] || (window.__probe[c.id] = { entries: 0, skipped: 0, applied: 0 });
  p.entries++;
  (_chartsUnchanged(c) ? p.skipped++ : p.applied++);   // read BEFORE calling through
  return window.__origRC(c);
};
```

Move the slider (`slate.set_bind(name="n", value=12)` works headless), wait ~1s, then read
`window.__probe`. Restore the page afterwards with
`window.renderCharts = window.__origRC; delete window.__origRC;`.

**Expected**, per slider move — measured 2026-08-21:

| cell | entries | outcome |
|---|---|---|
| `dependent` | 1 | applied — title tracks `n` |
| `inline` | 1 | applied — inline title tracks `n`, `_inst` alive |
| `independent` | 0 | never entered; title untouched |

One entry per changed cell. A regression shows up as `entries` climbing back to 4–8, as
`dependent`/`inline` reporting `skipped` (frozen charts), or as `independent` being entered at all.

The other two guards, checked directly rather than through an interaction:

```js
const c = nbState.cells.find(x => x.id === 'dependent');
window.renderCharts(c); window.renderCharts(c);        // 2nd must SKIP
window.chartRuntime.gen++; window.renderCharts(c);     // same specs, new gen -> must APPLY

const ic = nbState.cells.find(x => x.id === 'inline'), el = document.querySelector('#cell-inline .ichart');
_chartsUnchanged(ic);                                   // true while _inst is alive
const s = el._inst; el._inst = null; _chartsUnchanged(ic); el._inst = s;   // false once disposed
```
"""

#%% code id=controls
@bind n Slider(4:4:80)

#%% code id=dependent
# Its spec changes with `n`, so every slider move must RE-RENDER this one. If the guard ever skips
# here, charts freeze while their data moves underneath — the over-skip failure.
let xs = collect(1:Int(n))
    echart(:line, xs, round.(sin.(xs ./ 4); digits = 3);
           title = "dependent · n=$(Int(n))", smooth = true)
end

#%% code id=independent
# Reads nothing reactive, so it never re-runs on a slider move and its spec array stays the SAME
# object — this cell must be SKIPPED. This is the case the guard is for; before it, this chart paid a
# full stringify + setOption on every tick of an unrelated slider.
echart(:bar, ["a", "b", "c", "d"], [4, 9, 2, 7]; title = "independent · never changes")

#%% md id=inline
@md"""
Inline chart — the markdown around it is rebuilt whenever `n` moves, which disposes the placeholder's
instance. The guard must NOT skip this cell, or the chart comes back empty.

{{ echart(:line, collect(1:Int(n)), fill(1, Int(n)); title = "inline · n=$(Int(n))") }}
"""

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 620d5c82-df4a-4b5d-82f0-5973dcbf679e
# ╚═╡
