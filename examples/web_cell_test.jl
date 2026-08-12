try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 🌐 Web cells — HTML, CSS and JS with Julia values in scope

A `#%% web` cell writes front-end code directly: `@web(html"…", css"…", js"…")`, any pane optional.
`{{ name }}` interpolates a Julia binding into any pane — JSON-encoded, so strings escape safely and
arrays arrive as real JS arrays. Reading a binding is what creates the graph edge, so a web cell
re-renders when its inputs change, exactly like a code cell.

Each fragment runs in its own scope with `root` bound to the cell's output element, so top-level
`const` declarations can't collide between cells or across re-renders.

The cells below build up from plain interpolation to a widget that calls back into Julia:
"""

#%% code id=data
title = "Fish & <chips>"; xs = [3, 1, 4, 1, 5,17]; accent = "#5aa9e6"

#%% md id=h_interp
@md"""
## Interpolation across all three panes

`{{ title }}` lands in the HTML, `{{ accent }}` in the CSS, `{{ xs }}` in the JS. Note the title
contains `& <chips>` — it's JSON-encoded on the way through, not pasted, so nothing breaks.
"""

#%% web id=webcell
@web(html"""
<h2 id="hd">{{ title }}</h2>
<ul id="list"></ul>
""",
css"""
#hd { color: {{ accent }}; font: 600 20px system-ui; }
#list li { font-family: ui-monospace, monospace; }
""",
js"""
const xs = {{ xs }};                 // top-level const — must not collide on re-render
const ul = document.getElementById('list');
ul.innerHTML = '';
for (const x of xs) { const li = document.createElement('li'); li.textContent = `n = ${x}`; ul.appendChild(li); }
""")

#%% md id=h_preact
@md"""
## Preact, from Slate's own bundle

Slate ships Preact and `@preact/signals` behind an importmap, so `await import("htm/preact")` resolves
to the same local copy the notebook UI uses — no CDN, no second framework instance.
"""

#%% web id=htm_demo
@web(js"""
// Reuse Slate's OWN bundled Preact (importmap → /assets/vendor/*) — no CDN, one shared copy.
const { html, render } = await import("htm/preact");
const { signal, effect } = await import("@preact/signals");

const title = {{ title }}, accent = {{ accent }}, xs = {{ xs }};

// A signal — fine-grained reactivity, the modern Preact idiom.
const pick = signal(0);
function App() {
  return html`
    <div style="font-family:system-ui">
      <h2 style=${`color:${accent};margin:.2em 0`}>${title}</h2>
      <ul>${xs.map((x, i) => html`
        <li onClick=${() => (pick.value = i)}
            style=${`cursor:pointer;${pick.value === i ? 'font-weight:700' : ''}`}>
          item ${i + 1}: <b>${x}</b>
        </li>`)}</ul>
      <p style="opacity:.75">selected #${pick.value + 1} → value <b>${xs[pick.value]}</b>  ·  sum ${xs.reduce((a,b)=>a+b,0)}</p>
    </div>`;
}
render(html`<${App} />`, root);
""")

#%% md id=h_reactive
@md"""
## Reading a `@bind` — re-render on change

This fragment reads `{{ amp }}`, so the slider is one of its dependencies: moving it re-runs the
fragment. Good for cheap redraws where re-rendering the whole thing is fine.
"""

#%% code id=amp_ctrl
@bind amp Slider(1:0.5:10)

#%% web id=reactive_demo
@web(js"""
// Reactive bridge: this fragment reads {{ amp }} (a @bind slider) — so Slate re-runs it whenever
// the slider moves, re-rendering the Preact component with the new value. Local vendored Preact.
const { html, render } = await import("htm/preact");

const amp = {{ amp }}, xs = {{ xs }};
const scaled = xs.map(x => +(x * amp).toFixed(1));
const max = Math.max(...scaled, 1);

render(html`
  <div style="font-family:system-ui">
    <div style="opacity:.7;font-size:13px">amp = <b>${amp}</b> · drag the slider above</div>
    <div style="display:flex;gap:6px;align-items:flex-end;height:90px;margin-top:6px">
      ${scaled.map(v => html`
        <div style=${`width:34px;background:#5aa9e6;border-radius:3px 3px 0 0;height:${(v/max*84)|0}px`}
             title=${v}></div>`)}
    </div>
    <div style="display:flex;gap:6px;margin-top:4px;font:11px ui-monospace,monospace;opacity:.8">
      ${scaled.map(v => html`<div style="width:34px;text-align:center">${v}</div>`)}
    </div>
  </div>
`, root);
""")

#%% md id=h_stream
@md"""
## Streaming values in — push, without re-running

The opposite direction: `slate_emit(channel, value)` pushes from Julia to a `slateOnStream` subscriber.
The fragment is never re-run — each tick flows into a signal and Preact diffs only the SVG, so this
stays smooth at rates that would make a re-render approach stutter.
"""

#%% code id=stream_btn
@bind stream Button("Stream 60 ticks")

#%% code id=stream_emit
@onclick stream for i in 1:60
    v = round(sin(i/6) * exp(-i/80); digits = 4)
    slate_emit("ticker", (i = i, v = v))   # push a VALUE (NamedTuple) — server JSON-encodes it; no re-run
    pause(0.05)
end

#%% web id=stream_view
@web(js"""
// Subscribe to the Julia emit stream and update a live sparkline via signals — the fragment is
// NEVER re-run; slate_emit pushes each tick straight into the signal, Preact diffs just the SVG.
const { html, render } = await import("htm/preact");
const { signal } = await import("@preact/signals");

const last = signal({ i: 0, v: 0 });
const trail = signal([]);
window.slateOnStream("ticker", d => {
  last.value = d;
  trail.value = [...trail.value.slice(-49), d.v];
});

function View() {
  const t = trail.value, W = 320, H = 70, n = t.length;
  const pts = t.map((v, k) => `${(k / Math.max(n - 1, 1)) * W},${H / 2 - v * (H / 2 - 6)}`).join(" ");
  return html`
    <div style="font-family:system-ui">
      <div style="font:12px ui-monospace,monospace;opacity:.8">tick ${last.value.i} · v = ${last.value.v}  (click “Stream 60 ticks”)</div>
      <svg width=${W} height=${H} style="background:#0d1117;border-radius:6px;margin-top:4px">
        <line x1="0" y1=${H/2} x2=${W} y2=${H/2} stroke="#333"/>
        <polyline points=${pts} fill="none" stroke="#5aa9e6" stroke-width="1.75"/>
      </svg>
    </div>`;
}
render(html`<${View} />`, root);
""")

#%% md id=h_err
@md"""
## When a fragment throws

Deliberately broken, to show what a front-end error looks like: the exception is caught and reported
against this cell rather than vanishing into the browser console.
"""

#%% web id=err_demo
@web(html"""
<div>this widget throws on purpose</div>
""", js"""
const xs = {{ xs }};
const bad = xs.reduce((a, b) => a + b.nope.deep, 0);   // TypeError: reading .nope of a number
root.querySelector('div').textContent = bad;
""")

#%% md id=h_task
@md"""
## Calling Julia from the browser

`slate_on(channel, handler)` registers a handler; JS calls it with `slateCall`. A two-argument handler
receives a `progress` closure whose frames are correlated back to that specific call by the framework —
no token to thread through, no channel to manage.

`slateTask` (in `webassets/slatetask.js`) wraps the call in an idle→loading→done→error state machine
and supersedes stale in-flight calls, which is why the widget below reads like ordinary UI code.
"""

#%% code id=task_setup
regions = (title = "Regional totals", items = [
    (name = "north", total = 128, series = [3, 9, 14, 8, 5]),
    (name = "south", total = 82,  series = [2, 4, 6, 5, 9]),
    (name = "east",  total = 205, series = [10, 22, 18, 14, 30]),
    (name = "west",  total = 61,  series = [1, 3, 2, 4, 6]),
])

# A 2-arg handler: `progress` streams frames back to the caller, correlated FRAMEWORK-side to this
# call (no token, no channel) — the JS `slateCall(ch, args, onProgress)` receives each one.
slate_on("region_stat", (args, progress) -> begin
    it = only(filter(x -> x.name == args.name, regions.items))
    s = it.series
    for i in 1:length(s)
        progress((working = i, of = length(s)))
        sleep(0.25)
    end
    (name = it.name, mean = round(sum(s) / length(s); digits = 2), max = maximum(s), n = length(s))
end)
nothing

#%% web id=task_widget
@web(html"""
<div id="root"></div>
""", css"""
.exp { font-family: system-ui; max-width: 460px; }
.exp h3 { margin: 0 0 10px; font-weight: 650; }
.exp .row { display: flex; gap: 10px; align-items: center; padding: 6px 8px; border-radius: 6px; cursor: pointer; }
.exp .row:hover { background: rgba(90,169,230,.12); }
.exp .row.sel { background: rgba(90,169,230,.22); }
.exp .name { width: 84px; }
.exp .bar { height: 11px; border-radius: 3px; background: linear-gradient(90deg,#5aa9e6,#7ec8ff); }
.exp .tot { opacity: .6; font: 12px ui-monospace,monospace; }
.exp .stat { margin-top: 12px; padding: 8px 10px; border-radius: 6px; background: rgba(90,169,230,.08);
             font: 12.5px ui-monospace,monospace; color: #8fd6ff; min-height: 1.4em; }
""", js"""
// The whole widget: the token, progress correlation, supersede, and idle→loading→done→error state are
// all encapsulated in slateTask — this reads like plain UI code.
const { html, render } = await import("htm/preact");
const { signal, computed } = await import("@preact/signals");
const { slateTask } = await import(location.pathname + "/asset/webassets/slatetask.js");

const data = {{ regions }};
const items = data.items;
const max = Math.max(...items.map(it => it.total));

const sel  = signal(-1);
const task = slateTask("region_stat");
async function pick(i) { sel.value = i; await task.run({ name: items[i].name }); }

const statLine = computed(() => {
  const s = task.state.value;
  return s.status === "loading" ? `⏳ processing ${s.progress?.working ?? 0}/${s.progress?.of ?? "?"} …`
       : s.status === "done"    ? `✓ ${s.result.name}: mean ${s.result.mean} · max ${s.result.max} · n=${s.result.n}`
       : s.status === "error"   ? `✗ ${s.error}` : "click a row → computed in Julia (with live progress)";
});

function App() {
  return html`
    <div class="exp">
      <h3>${data.title}</h3>
      ${items.map((it, i) => html`
        <div class=${"row" + (sel.value === i ? " sel" : "")} onClick=${() => pick(i)}>
          <div class="name">${it.name}</div>
          <div class="bar" style=${`width:${(it.total / max * 220) | 0}px`}></div>
          <div class="tot">${it.total}</div>
        </div>`)}
      <div class="stat">${statLine.value}</div>
    </div>`;
}
render(html`<${App} />`, root);
""")

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 99d162f6-ccd6-4cc1-9dfb-98c1f219140c
# ╚═╡
