try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# Pick controls — `PickPoint`, `PickRegion`, `PickPath`

A figure you can click. Each section drives a control by clicking the plot itself instead of
dragging a slider, and prints the bound value so you can see exactly what arrived.

The control is declared **without** the figure and aimed at an axis afterwards with `pick_on!`.
That order is forced rather than stylistic: a figure that draws the pick *reads* the bind, so a
control constructed from the figure would depend on a figure that depends on it.

What each section below is here to exercise:

| | checks |
|---|---|
| **1 · point** | the basic click → `(x, y)`, and that `snap` quantises it |
| **2 · letterboxed** | `DataAspect()`, where the axis is narrower than its layout cell |
| **3 · log axis** | a log scale maps where the ticks are, not linearly |
| **4 · two axes** | two independent picks in ONE figure — the rectangle really is per-axis |
| **5 · region** | drag a box; corners normalise however you drag |
| **6 · path** | click `n` points; the path fills and then starts over |
| **7 · refusal** | a `PolarAxis` has no rectangular mapping and must be refused, not guessed |
"""

#%% code id=setup
using CairoMakie, Printf, Random
use_slate_theme!()
nothing

#%% md id=s1_md
@md"""
## 1 · A point, snapped to a grid

`snap = 0.05`, so every click lands on a multiple of 0.05 measured from the axis floor — drag
around and the readout never shows a long float. Coercion clamps to the axis too, so there is no
value the figure can produce that is outside it.
"""

#%% code id=s1
@bind pt hidden(PickPoint(; default = (0.40, -0.20), snap = 0.05))

gr = range(-2, 2, 200)
fig1 = Figure(size = (620, 400))
ax1 = Axis(fig1[1, 1]; title = "click anywhere", xlabel = "x", ylabel = "y")
heatmap!(ax1, gr, gr, [sin(3x) * cos(3y) for x in gr, y in gr]; colormap = :viridis)
scatter!(ax1, [pt.x], [pt.y]; color = :gold, markersize = 16,
         strokecolor = :black, strokewidth = 1.5)
limits!(ax1, -2, 2, -2, 2)
pick_on!(:pt, fig1, ax1)
fig1

#%% md id=s1_out
@md"""
`pt` = **({{ pt.x }}, {{ pt.y }})** — a `(x, y)` NamedTuple, so `pt.x` and `pt.y` read by name.

## 2 · A letterboxed axis (`DataAspect`)

The axis below is square but its layout cell is wide, so the plotted area does **not** fill the
cell. This is the case a hand-rolled overlay gets wrong: the click target has to follow the
*plotted area*, not the cell. Click near the left and right edges of the dark square — the readout
should reach exactly ±3, and clicking in the empty margin should do nothing.
"""

#%% md id=acc_md
@md"""
## 1b · Click accuracy

**Click the centre of any ✛ below.** The heading then tells you how far your click landed from
that cross, in screen pixels.

That is the whole test. Under about 3 px means the pick is accurate and the rest is your aim, since
nobody clicks the exact centre of a cross. A number in the tens means the click is being mapped to
the wrong place, which is the failure worth catching: a mis-mapped axis still returns a sensible
looking coordinate, so nothing appears broken.

Snapping is switched off here, unlike the rest of the notebook, so you see the raw number. With
`snap` on, a near-enough click would land exactly on the cross and read as perfect whether or not
the mapping was right.

Then repeat it while changing the view, because each of these breaks it differently:

| do this | what a big number would mean |
|---|---|
| **zoom** with ⌘/Ctrl `+` to 150%, then back | the overlay no longer lines up with the image |
| **resize** the window narrow, then wide | the axis rectangle went stale |
| **collapse** the cell and reopen it | the overlay never re-attached |
| **drag slowly** between two crosses | the value lags, or the drag dies part-way |

The strip underneath measures the overlay against the image on its own, and updates as you zoom. If
a click feels off, that number says whether the overlay moved or the mapping did.
"""

#%% code id=acc
# No `snap` here on purpose: quantising would land a near-enough click exactly on the target and
# report perfect whether or not the mapping is right, which is the thing this section measures.
@bind hit hidden(PickPoint(; default = (0.0, 0.0)))

TARGETS = [(x, y) for x in -2:2:2 for y in -2:2:2]
near = argmin([hypot(hit.x - t[1], hit.y - t[2]) for t in TARGETS])
tgt  = TARGETS[near]

FIGW, SPAN = 620, 6.0
figA = Figure(size = (FIGW, 500))
axA = Axis(figA[1, 1]; aspect = DataAspect(), xlabel = "x", ylabel = "y",
           xticks = -3:1:3, yticks = -3:1:3)
vlines!(axA, -3:1:3; color = (:white, 0.07)); hlines!(axA, -3:1:3; color = (:white, 0.07))
for t in TARGETS                                   # a cross you can aim at, and its coordinates
    lines!(axA, [t[1]-0.28, t[1]+0.28], [t[2], t[2]]; color = (:white, 0.55), linewidth = 1.2)
    lines!(axA, [t[1], t[1]], [t[2]-0.28, t[2]+0.28]; color = (:white, 0.55), linewidth = 1.2)
    text!(axA, t[1], t[2]; text = "($(Int(t[1])), $(Int(t[2])))", align = (:center, :center),
          offset = (0, 20), color = (:white, 0.4), fontsize = 11)
end
scatter!(axA, [hit.x], [hit.y]; color = :gold, markersize = 10,
         strokecolor = :black, strokewidth = 1)
limits!(axA, -3, 3, -3, 3)

# NOTHING may touch the layout after this. `pick_on!` measures where the axis IS, so a title set
# afterwards (or any other layout change) moves the axis out from under the calibration and every
# click lands offset by however far it shifted. The readout lives in the cell below for exactly
# that reason — a title that changes with each click would move the axis on each click.
pick_on!(:hit, figA, axA)
pxper = axis_calibration(figA, axA)["rect"]["width"] * FIGW / SPAN
err_px = hypot(hit.x - tgt[1], hit.y - tgt[2]) * pxper
figA

#%% md id=acc_out
@md"""
### {{ round(err_px; digits=1) }} px from ({{ Int(tgt[1]) }}, {{ Int(tgt[2]) }})

You clicked **({{ round(hit.x; digits=3) }}, {{ round(hit.y; digits=3) }})**; the nearest cross is
at ({{ Int(tgt[1]) }}, {{ Int(tgt[2]) }}).

Under about 3 px is your aim. Tens of pixels means the click is being mapped to the wrong place.

!!! note "Why the number is here and not on the figure"
    `pick_on!` measures where the axis **is**. Anything that changes the layout afterwards — a
    title, a label, a legend — moves the axis out from under that measurement, and every click then
    lands offset by however far it shifted. A title carrying this readout would change on every
    click, so it would move the axis on every click. Call `pick_on!` last.
"""

#%% web id=acc_selfcheck
@web(html"""
<div id="chk"></div>
""",
css"""
#chk { font: 12px/1.7 ui-monospace, SFMono-Regular, Menlo, monospace; padding: 8px 11px;
       border-radius: 8px; background: rgba(255,255,255,.04); border-left: 3px solid var(--dim); }
#chk.ok   { border-left-color: #3ddc97; }
#chk.bad  { border-left-color: #f5a623; }
#chk b { font-weight: 700; }
#chk .row { white-space: pre; }
""",
js"""
// Measures each pick overlay against the image it is aimed at, independently of the code that
// places it: the overlay SHOULD sit at the calibrated fraction of the image's own screen box.
// Any drift shows up here as a pixel error, which is what a click landing offset would look like.
// Re-measured on zoom, resize and scroll, so the number is live while you change the view.
const el = root.querySelector('#chk');

// The page's cell state, which carries each cell's `picks` (bind, rect, xlim/ylim, scales).
const slateState = () => window.__slateState || window.nbState || null;

function measure() {
  const rows = [];
  let worst = 0;
  const cells = (slateState()?.cells) || [];
  for (const cell of document.querySelectorAll('.cell')) {
    const img = cell.querySelector('.output img');
    const ovs = cell.querySelectorAll('.pickovl');
    if (!img || !ovs.length) continue;
    const ib = img.getBoundingClientRect();
    const picks = cells.find(c => 'cell-' + c.id === cell.id)?.picks || [];
    ovs.forEach((ov, i) => {
      const p = picks[i]; if (!p || !p.rect) return;
      const ob = ov.getBoundingClientRect();
      const want = { left: ib.left + p.rect.left * ib.width, top: ib.top + p.rect.top * ib.height,
                     width: p.rect.width * ib.width, height: p.rect.height * ib.height };
      const e = Math.max(Math.abs(ob.left - want.left), Math.abs(ob.top - want.top),
                         Math.abs(ob.width - want.width), Math.abs(ob.height - want.height));
      worst = Math.max(worst, e);
      rows.push(`${(cell.id.replace('cell-','') + ' ').padEnd(16,'·')} ${p.bind.padEnd(8)} off by ${e.toFixed(2)} px`);
    });
  }
  const dpr = (window.devicePixelRatio || 1).toFixed(2);
  if (!rows.length) { el.className = ''; el.textContent = 'no pick overlays on the page yet'; return; }
  // Half a CSS pixel is the most sub-pixel layout rounding can account for.
  el.className = worst <= 0.5 ? 'ok' : 'bad';
  el.innerHTML = `<div class="row"><b>overlay vs image — worst ${worst.toFixed(2)} px</b>` +
                 `   (zoom ${dpr}×, ${worst <= 0.5 ? 'aligned' : 'DRIFTED — clicks will land offset'})</div>` +
                 rows.map(r => `<div class="row">${r}</div>`).join('');
}

// Coalesce to one measure per frame. Scroll and a re-render both fire in bursts, and measuring
// reads layout for every overlay on the page.
let queued = false;
const schedule = () => {
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => { queued = false; measure(); });
};

schedule();
addEventListener('resize', schedule);
addEventListener('scroll', schedule, true);
// Watch the page for re-renders that swap overlays out — but IGNORE the mutations this cell makes
// itself. Writing the report is a DOM change inside `el`, so re-measuring on it would rewrite it
// and measure again: a loop with nothing to break it, which hangs the tab the moment it renders.
const mo = new MutationObserver(recs => {
  if (recs.every(r => el === r.target || el.contains(r.target))) return;
  schedule();
});
mo.observe(document.body, { childList: true, subtree: true });
""")

#%% md id=s1c_md
@md"""
## 1c · Snapping to named points — `snapto`

`snap` quantises to a lattice, so a click lands on the nearest *grid* position — which is only a
target when you were already close to one. `snapto` names the points that may be chosen and takes
the nearest, so **every** click resolves to a real candidate however far away you press. Its
domain is the candidate set itself, which is what `@replay` needs and what a lattice can only
approximate: the five points below need 5 entries, the equivalent `snap = 0.25` grid needs 625.
"""

#%% code id=s1c
STATIONS = [(-2.0, -2.0), (0.0, 0.0), (2.0, 2.0), (2.0, -2.0), (-2.0, 2.0)]

@bind stn hidden(PickPoint(; default = (0.0, 0.0), snapto = STATIONS))

figS = Figure(size = (520, 450))
# The title is FIXED. A title that reported the pick would change the layout on every pick, which
# moves the axis out from under the calibration `pick_on!` measured — the readout is below instead.
axS = Axis(figS[1, 1]; aspect = DataAspect(), xlabel = "x", ylabel = "y",
           title = "click anywhere — it lands on the nearest station")
scatter!(axS, first.(STATIONS), last.(STATIONS); color = :transparent,
         strokecolor = (:white, 0.55), strokewidth = 1.5, markersize = 30)
scatter!(axS, [stn.x], [stn.y]; color = :seagreen, markersize = 15,
         strokecolor = :black, strokewidth = 1)
limits!(axS, -3, 3, -3, 3)
pick_on!(:stn, figS, axS)
figS

#%% md id=s1c_out
@md"""
`stn` = **({{ stn.x }}, {{ stn.y }})** — always one of the five, however far from it you clicked.
The readout lives here rather than in the figure's title for the reason above: a title that changed
with the pick would move the axis out from under the calibration.
"""

#%% code id=s2
@bind sq hidden(PickPoint(; default = (0.0, 0.0)))

fig2 = Figure(size = (900, 320))
ax2 = Axis(fig2[1, 1]; aspect = DataAspect(), title = "square axis in a wide cell",
           xlabel = "x", ylabel = "y")
heatmap!(ax2, range(-3, 3, 120), range(-3, 3, 120),
         [exp(-(x^2 + y^2) / 4) for x in range(-3, 3, 120), y in range(-3, 3, 120)];
         colormap = :magma)
scatter!(ax2, [sq.x], [sq.y]; color = :gold, markersize = 16,
         strokecolor = :black, strokewidth = 1.5)
limits!(ax2, -3, 3, -3, 3)
pick_on!(:sq, fig2, ax2)
fig2

#%% md id=s3_md
@md"""
`sq` = **({{ round(sq.x; digits=3) }}, {{ round(sq.y; digits=3) }})** — reaches ±3 at the edges of
the plotted square, not of the layout cell.

## 3 · A log axis

`x` runs from 1 to 10 000 on a log scale. The mapping is done in scale space, so clicking
**halfway across** gives ~100 (the geometric middle), not ~5000. That is the check: a linear
mapping would be plausible and wrong.
"""

#%% code id=s3
@bind lg hidden(PickPoint(; default = (100.0, 0.5)))

fig3 = Figure(size = (620, 360))
ax3 = Axis(fig3[1, 1]; xscale = log10, title = "log x — halfway across is 100",
           xlabel = "x (log)", ylabel = "y")
lines!(ax3, 10 .^ range(0, 4, 200), range(0, 1, 200); color = :deepskyblue, linewidth = 2)
vlines!(ax3, [lg.x]; color = :gold, linewidth = 2)
scatter!(ax3, [lg.x], [lg.y]; color = :gold, markersize = 15,
         strokecolor = :black, strokewidth = 1.5)
limits!(ax3, 1, 10_000, 0, 1)
pick_on!(:lg, fig3, ax3)
fig3

#%% md id=s4_md
@md"""
`lg.x` = **{{ round(lg.x; digits=1) }}** — click the middle of the axis and this reads ≈100.

## 4 · Two axes, one figure, two independent picks

Both panels live in the same rendered image. Each `pick_on!` describes its own rectangle, so
clicking the left panel must move only `a` and the right only `b`. If the two ever cross-talk, the
per-axis rectangle is wrong.
"""

#%% md id=s3b_md
@md"""
## 3b · A reversed axis

`xreversed`/`yreversed` draw the same limits mirrored, and `finallimits` still reads low-to-high
while the pixels run the other way. Taking it at face value puts every click on the wrong side of
the axis while still returning a number in range, which is why this has a section of its own.

Here **x runs right-to-left and y runs top-to-bottom.** Click the corner marked `(-2, 2)` — the
readout has to agree with the label, not with where that point would be on an ordinary axis.
"""

#%% code id=s3b
@bind rv hidden(PickPoint(; default = (0.0, 0.0), snap = 0.25))

CORNERS = [(-2.0, 2.0), (2.0, 2.0), (-2.0, -2.0), (2.0, -2.0)]
nr = argmin([hypot(rv.x - c[1], rv.y - c[2]) for c in CORNERS])
er = hypot(rv.x - CORNERS[nr][1], rv.y - CORNERS[nr][2])

figR = Figure(size = (520, 450))
axR = Axis(figR[1, 1]; aspect = DataAspect(), xlabel = "x  (runs right to left)",
           ylabel = "y  (runs top to bottom)",
           title = er < 1e-9 ? "on $(CORNERS[nr]) — exact" :
                   @sprintf("nearest %s · off by %.3f", CORNERS[nr], er),
           titlecolor = er < 1e-9 ? :seagreen : :gold)
for c in CORNERS
    scatter!(axR, [c[1]], [c[2]]; color = :transparent, strokecolor = (:white, 0.6),
             strokewidth = 1.5, markersize = 26)
    text!(axR, c[1], c[2]; text = string(c), align = (:center, :center),
          offset = (0, 20), color = (:white, 0.6), fontsize = 11)
end
scatter!(axR, [rv.x], [rv.y]; color = er < 1e-9 ? :seagreen : :gold, markersize = 13,
         strokecolor = :black, strokewidth = 1)
limits!(axR, -3, 3, -3, 3)
axR.xreversed[] = true          # set after `limits!`; the constructor kwarg does not take
axR.yreversed[] = true
pick_on!(:rv, figR, axR)
figR

#%% code id=s4
@bind a hidden(PickPoint(; default = (-1.0, 1.0), snap = 0.1))
@bind b hidden(PickPoint(; default = (5.0, 5.0), snap = 0.5))

fig4 = Figure(size = (900, 340))
axL = Axis(fig4[1, 1]; title = "left — drives `a`  (−2…2)")
scatter!(axL, [a.x], [a.y]; color = :tomato, markersize = 18)
limits!(axL, -2, 2, -2, 2)

axR = Axis(fig4[1, 2]; title = "right — drives `b`  (0…10)")
scatter!(axR, [b.x], [b.y]; color = :deepskyblue, markersize = 18)
limits!(axR, 0, 10, 0, 10)

pick_on!(:a, fig4, axL)
pick_on!(:b, fig4, axR)
fig4

#%% md id=s5_md
@md"""
`a` = ({{ a.x }}, {{ a.y }})  ·  `b` = ({{ b.x }}, {{ b.y }}) — each panel moves only its own.

## 5 · A region

Drag a box. Whichever corner you start from, the value comes back normalised, so
`xlo ≤ xhi` and `ylo ≤ ylh` always hold — drag right-to-left and bottom-to-top and check the
readout is the same box.
"""

#%% code id=s5
@bind box hidden(PickRegion(; default = (-1.0, 1.0, -1.0, 1.0), snap = 0.1))

# Seeded: this cell re-runs on every drag, and unseeded points would jump each time.
rng = MersenneTwister(20260923)
pts = [(2randn(rng), 2randn(rng)) for _ in 1:400]
inside = [p for p in pts if box.xlo <= p[1] <= box.xhi && box.ylo <= p[2] <= box.yhi]

fig5 = Figure(size = (620, 400))
ax5 = Axis(fig5[1, 1]; title = "drag a box — $(length(inside)) of $(length(pts)) points inside")
scatter!(ax5, first.(pts), last.(pts); color = (:white, 0.35), markersize = 6)
isempty(inside) || scatter!(ax5, first.(inside), last.(inside); color = :gold, markersize = 7)
limits!(ax5, -6, 6, -6, 6)
pick_on!(:box, fig5, ax5)
fig5

#%% md id=s6_md
@md"""
`box` = xlo **{{ box.xlo }}**, xhi **{{ box.xhi }}**, ylo **{{ box.ylo }}**, yhi **{{ box.yhi }}**
— normalised however you dragged.

## 6 · A path

Click four points. The path fills up, and the **fifth click starts a new one** rather than leaving
you with a finished path and no way to draw another. The length is fixed on purpose: a value whose
arity changes under the reader is one neither the coercion contract nor a static export's domain
can express.
"""

#%% code id=s6
@bind way hidden(PickPath(; n = 4, snap = 0.25))

len = length(way) < 2 ? 0.0 :
      sum(hypot(way[i+1].x - way[i].x, way[i+1].y - way[i].y) for i in 1:length(way)-1)

fig6 = Figure(size = (620, 400))
ax6 = Axis(fig6[1, 1];
           title = @sprintf("%d / 4 points · path length %.2f", length(way), len))
if !isempty(way)
    lines!(ax6, [w.x for w in way], [w.y for w in way]; color = :gold, linewidth = 2)
    scatter!(ax6, [w.x for w in way], [w.y for w in way]; color = :gold, markersize = 11)
end
limits!(ax6, -5, 5, -5, 5)
pick_on!(:way, fig6, ax6)
fig6

#%% md id=s7_md
@md"""
## 7 · What must be refused

A `PolarAxis` has no rectangular pixel→data mapping, so `pick_on!` has to **fail loudly**. This is
the case worth being strict about: a wrong rectangle doesn't look broken, it returns
plausible-but-wrong coordinates forever. Same for an axis that has no area yet.

The cell below expects both to throw, and prints what the reader would see.
"""

#%% code id=s7
figp = Figure(size = (640, 300))
axpolar = PolarAxis(figp[1, 1])
lines!(axpolar, range(0, 2π, 100), fill(1.0, 100); color = :tomato)
ax3d = Axis3(figp[1, 2])
scatter!(ax3d, randn(20), randn(20), randn(20))
Makie.update_state_before_display!(figp)

# `Axis3` is the interesting one: it HAS `finallimits`, just three-dimensional. Silently taking
# the first two would map a rotated projection as if it were flat — plausible coordinates, quietly
# wrong. A click on a 3-D scene is a ray, not a point.
results = String[]
for (what, ax) in (("PolarAxis", axpolar), ("Axis3", ax3d))
    push!(results, try
        axis_calibration(figp, ax)
        "✗ $what — NOT refused (this is a bug)"
    catch e
        "✓ $what → " * first(sprint(showerror, e), 110)
    end)
end
figp

#%% code id=77e4a7
println(join(results, "\n"))
length(results)

#%% code id=fb39db hidecode
using Base64, Dates
let ffmpeg = "/opt/homebrew/bin/ffmpeg", ffprobe = "/opt/homebrew/bin/ffprobe"
    dur(p) = try; parse(Float64, strip(read(`$ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $p`, String))); catch; -1.0; end
    bufs = Dict{String,IOBuffer}()
    slate_on("clip_begin", a -> (bufs[String(a.id)] = IOBuffer(); (ok = true)))
    slate_on("clip_chunk", a -> (write(get!(bufs, String(a.id), IOBuffer()), String(a.data)); (ok = true)))
    slate_on("clip_end", a -> begin
        id = String(a.id); mime = String(get(a, :mime, "video/webm"))
        buf = get(bufs, id, nothing); buf === nothing && return (ok = false, error = "no buffer")
        b64 = String(take!(buf)); delete!(bufs, id)
        ext = occursin("mp4", mime) ? "mp4" : "webm"; bytes = base64decode(b64)
        ts = Dates.format(now(), "yyyymmdd-HHMMSS"); dir = expanduser("~/Downloads")
        raw = joinpath(dir, "slate-rec-$ts-raw.$ext"); out = joinpath(dir, "slate-rec-$ts.mp4")
        write(raw, bytes); dr = dur(raw)
        ok = try; run(`$ffmpeg -y -loglevel error -fflags +genpts -i $raw -c:v libx264 -pix_fmt yuv420p -crf 23 -fps_mode cfr -r 30 -movflags +faststart $out`); true; catch e; @warn e; false; end
        dout = ok ? dur(out) : -1.0; ok && rm(raw; force = true)
        (ok = ok, path = (ok ? out : raw), mb = round(length(bytes)/1e6, digits = 1), raw_dur = round(dr, digits = 2), out_dur = round(dout, digits = 2))
    end)
end
"screen-record handlers registered (bookmarklet)"

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 350705b1-d198-4191-b306-d90c8b4207bd
# ╚═╡
