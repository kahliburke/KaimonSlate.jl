# Slate Animation Pipeline — Design Proposal (v3)

Status: **proposal, for review.** v3 folds in review feedback: texture-array storage
with free temporal interpolation, per-frame timestamps, `:symmetric` clim + diverging
maps for signed fields, real-coordinate axes, and — the major change — **automatic
(transparent) durable caching** instead of an explicit `slate_cache` call, made safe
by folding Revise'd `src/` state into the cache key.

## Load-bearing decisions (the core that must be right)

1. **Blob transport, not inline base64.** The frame stack lives in the
   content-addressed blob store and is fetched lazily as an `ArrayBuffer`; only a
   small JSON manifest rides in the cell state. Inlining would re-introduce the
   `/api/state` / agent-replay / digest bloat we already fixed. ZMQ (worker→server)
   is *not* a bottleneck — the constraint is the browser HTTP/state path.
2. **GPU-first player (WebGL2).** Frames are one `R8` **texture array**; a fragment
   shader does colormap-LUT lookup + bilinear (spatial) interpolation + **temporal
   interpolation** (`mix()` between adjacent layers) + ordered dithering. The CPU only
   uploads bytes.
3. **Presentation clock + frame-drop.** Playback time comes from a wall clock (with
   optional **per-frame timestamps** for non-uniform sampling); the renderer samples
   the right layer and drops frames when behind rather than accumulating lag.
4. **Automatic durable caching.** Expensive cells (selected by measured runtime) are
   memoized to disk under a *total* digest — cell source ⊻ upstream cell digests ⊻
   the source-hash of every package the notebook uses ⊻ the resolved Manifest. Neither
   a browser reload nor a server/extension restart re-runs the physics. No manual
   annotation.
5. **Visibility-gated, honest v1/v2 split.** Playback pauses offscreen/hidden; the
   arbitrary-Makie→video path and OffscreenCanvas-in-worker are v2.

---

## Core principle

> **Animation = a precomputed frame stack + a client-side player.**
> Julia computes every frame once, hands off a compact stack, and is out of the loop
> during playback. Smoothness is independent of how slow the physics is — a 15 s
> propagation plays back at 60 fps because the browser is just sampling a texture it
> already holds.

Video-streaming corollaries we adopt: separate the decode clock from the render clock;
never block the UI thread and never let latency accumulate (drop frames); do color
*and interpolation* on the GPU; don't decode what you can't see.

---

## Julia API

```julia
# Heavy compute runs ONCE. The result is automatically cached to disk (see Caching),
# so a server/extension restart restores it without re-running the propagation.
frames = map(1:nframes) do i
    slate_progress(i/nframes; msg = "frame $i")
    density_snapshot(i)              # Matrix (2D field) — or Vector (1D line)
end

anim = animate(frames;
    kind      = :heatmap,           # v1: :heatmap   (v2: :line | :image | :scatter | :quiver)
    fps       = 30,                 # uniform timing; overridden by `times` if given
    times     = nothing,            # optional Vector of per-frame timestamps (non-uniform sampling)
    colormap  = :magma,             # LUT; client-swappable instantly. Signed data → diverging default.
    clim      = :global,            # :global | :symmetric | :perframe | (lo, hi)
    transform = nothing,            # per-frame value map, applied BEFORE quantization; must be
                                    #   domain-valid for the data (auto-skipped for signed modes)
    dither    = true,               # hide 8-bit banding on smooth gradients
    bits      = 8,                  # 8 (R8 + dither, default) | 16 (R16, HDR fields) — schema-reserved
    x = r, y = r,                   # axis COORDINATES — ticks show real r, not grid indices
    title = "ps-wave density",
    colorbar = true,
    loop = true, autoplay = false)
```

Overloads:

- `animate(f::Function, nframes; kw...)` — `f(i)` generates frame `i`.
- `animate(frames::Vector{<:Matrix}; kw...)` / *(v2)* `Vector{<:Vector}`, `Vector{<:Makie.Figure}`.

`animate` returns an `Animation` whose `show(::MIME"application/x-slate-animation")`
emits the **manifest** (small JSON) and registers the **frame blob** in the blob store.

**Signed-field correctness (not optional for helium).** The most illuminating
animations here are signed — Δρ(r₁,r₂,t), Re ψ — which want a blue/white/red diverging
map centered at 0. So: `clim = :symmetric` resolves a symmetric range `(-m, m)` with
`m = max(abs.(extrema))`; signed modes default `colormap` to a diverging scheme and
**skip `transform`** (no `sqrt` of negative data — that NaN trap is designed out).

---

## Encoding & transport

### Heatmap stack (`:heatmap`)

1. Apply `transform` per frame (skipped for signed `:symmetric`).
2. Resolve `clim`: `:global` (one range), `:symmetric` (`(-m, m)`), `:perframe`
   (per-frame `(lo,hi)` in the manifest), or explicit.
3. Quantize to **UInt8** (`bits=8`, default) or **UInt16** (`bits=16`, HDR) against the
   range.
4. Pack the whole stack as one contiguous `nframes × H × W` buffer — uploaded to the
   GPU as a single **`TEXTURE_2D_ARRAY`** (one layer per frame). This sidesteps
   per-texture count limits at the 500-frame end *and* makes temporal interpolation a
   one-line shader change.
5. **gzip** and register as a blob (browser gunzips for free via `Content-Encoding`;
   smooth fields compress hugely). *(v2: interframe delta + RLE keyframes first.)*
6. The 256-entry RGBA **LUT travels in the manifest**; recolormap = swap the LUT
   texture — no refetch, no recompute.

A 60-frame 200×200 stack is 2.4 MB raw, typically a few hundred KB gzipped — fetched
once, lazily.

### Multi-rendition hook (ABR-lite, schema-reserved, built v2)

The manifest reserves a `renditions` array (e.g. half-res for thumbnails, full-res when
enlarged). v1 ships one rendition.

### Guard rails

Honor the existing caps (`_MAX_KEEP_BYTES` family). Default ceiling **~128 MB raw**
(≈ the 500³ point), `log()`-surfaced, with a per-cell `maxbytes=` override. The gzip
blob is far smaller on the wire — the cap protects **worker RAM + GPU texture memory**,
which is the right thing to bound.

---

## The browser player

Self-contained component registered for `application/x-slate-animation`.

### Rendering — GPU first

- **WebGL2:** the stack is one `R8`/`R16` **texture array**. The fragment shader
  samples it, indexes the **LUT texture** for color, does **bilinear spatial
  interpolation** (free via the sampler), **temporal interpolation** (sample layers
  `⌊t⌋` and `⌈t⌉`, `mix()` by the fractional clock — the biggest fidelity win for
  slow-mo/scrub, ~zero cost), and **ordered (Bayer) dithering** to mask banding. Fixed
  **aspect ratio** in the vertex stage (fixes the squished heatmap).
- **CPU fallback:** `putImageData` → offscreen canvas → `drawImage` upscale with
  `imageSmoothingEnabled` (no temporal lerp).
- **Axes show real `x`/`y` coordinates** (read r off the ticks — that's the point), and
  the LUT/colormap matches the notebook's CairoMakie dark theme. With that, the
  player's own chrome is correct for v1; Makie-rendered axes are reserved for the v2
  video route.

### Timing — presentation clock, not a counter

- Playback time = wall clock (`performance.now()`) × speed. Frame selection uses
  per-frame **`times`** when provided (non-uniform sampling), else `index/fps`.
- **Frame-drop under load:** skip to the correct layer; never queue, never accumulate
  latency. Wall-clock speed is correct at 60 or 24 fps.
- Cap to display refresh; honor `prefers-reduced-motion` (no autoplay/loop).

### Off-main-thread + visibility-gated

- *(v2)* `OffscreenCanvas` in a Web Worker so decode/blit never stutters scroll/typeset.
  (v1 stays on the main thread but cheap — the GPU does the work.)
- **IntersectionObserver + Page Visibility:** pause playback (and, for long stacks,
  prefetch) when offscreen/hidden. The frame blob is fetched on scroll-into-view / first
  play via the existing lazy-hydration scheduler — never on notebook load.

### Transport bar

play/pause · scrub slider · speed (fps multiplier) · loop toggle · frame+time readout ·
**keyboard transport** (space = play/pause, ←/→ = step, shift+←/→ = jump). Scrubbing
samples the texture directly — instant, no Julia.

---

## Cell MIME payload (the manifest)

```jsonc
{
  "kind":  "heatmap",
  "shape": [nframes, H, W],
  "bits":  8,                          // 8 | 16
  "fps":   30,
  "times": null,                       // or [t0, t1, ...] for non-uniform sampling
  "renditions": [
    { "framesUrl": "/blob/<hash>", "scale": 1.0 }   // gzip'd typed stack, NOT inline
  ],
  "lut":   "/blob/<hash>" | [[r,g,b,a], ...],
  "clim":  { "mode": "symmetric", "range": [-m, m] },  // global | symmetric | perframe | explicit
  "diverging": true,                   // hint for default LUT + centered colorbar
  "dither": true,
  "axes":  { "x": [...], "y": [...], "title": "...", "colorbar": true },
  "controls": { "loop": true, "autoplay": false }
}
```

Small and safe to inline in cell JSON; the heavy buffers are blob handles fetched lazily.

---

## Reactivity integration

```julia
anim = animate(frames; …)            # mode 1: autonomous client-side playback
@bind t playhead(anim)               # mode 2 (opt-in): throttled current frame/time
```

Playback never depends on a Julia recompute. `playhead` is **player → Julia only**,
throttled — the player is the clock; Julia never drives playback.

---

## Persistence & durable caching — automatic, and safe

Animations are far more expensive than other viz, so the pipeline must guarantee that
**neither a browser reload nor a server/extension restart re-runs the physics** — with
**no manual cache declaration.** (Motivating incident: a worker restart re-ran a 15 s
propagation *and* surfaced a stale load-error on the way. The restart-recompute problem
is real, not hypothetical.)

### Browser reload — already free

The manifest is in cell state; the frame buffer + LUT are in the content-addressed blob
store. A reload just refetches the `ArrayBuffer`. **Zero Julia.**

### Server / extension restart — transparent memoization

On cold start `eval_stale!` would re-run the `frames` compute cell. Instead, before
evaluating a stale cell, it computes the cell's **digest** and, on a hit, restores the
cached value + output from disk and marks the cell fresh — **skipping evaluation.**

The reason transparent memoization is usually unsafe is the **digest-completeness
problem**: a key that misses an input silently serves a stale result. The classic
landmine here is exactly the one our project rules warn about — edit `src/`, and the
cell's source + upstream notebook values are byte-identical, so a naive digest hits the
stale cache and serves wrong frames after a real physics change. **We can close this,
because Slate already tracks `src/` content at def granularity.** We make the digest
*total*:

```
key = hash(
    cell.source                                  # the code in the cell
  ⊻ ordered digests of upstream cells it reads   # the reactive inputs (existing machinery)
  ⊻ source-hash of every package the notebook USES   # ← the src landmine, closed
  ⊻ hash(resolved Manifest.toml)                 # package versions
)
```

- **Source-hash of used packages** reuses the change-detection machinery just landed
  for hot-reload: `_file_defs` already parses each `src/` file into a def-name → body
  hash map. The per-package source digest is the hash of those maps, scoped to the
  packages the notebook `using`/`import`s (parsed from its import cells — not all of
  Base). Any edit to any def in a used package changes the digest → the cell recomputes.
  Conservative (an unrelated edit in the same package also invalidates) but **total**,
  which is the only acceptable property for a silent cache. This is strictly *more*
  reliable than a manual `version=`/`salt=` bump — which a human forgets.
- **Manifest hash** covers dependency upgrades.
- Within a live session this is moot — hot-reload already restales affected cells
  precisely; the cache exists to survive **restart**, and the same digest decides both.

### What gets cached (automatic selection — no annotation)

- **By cost:** after a cell runs, persist its value + output only if its **measured
  duration** exceeds a threshold (we already record per-cell `duration`). Cheap cells
  never pay serialize/digest overhead — the cost distribution is handled automatically,
  the way explicit marking would, without asking the user.
- **By round-trippability:** persist only values we can safely serialize. The UInt8/16
  stack and `Matrix` frames are trivial; closures / fragile custom types are **skipped
  with a one-time warning**, never silently half-saved.
- **Never cache errors**, and never on a thrown `do`/eval — a poisoned entry that
  survives restarts is worse than recomputing.

### Impurity escape hatch

Transparent memoization assumes a cell is a pure function of its digested inputs.
For the rare impure cell (unseeded `rand`, `time()`, external I/O, mutable globals), a
per-cell opt-out — a cell tag `nocache` (and an obvious-impurity heuristic that *warns*,
e.g. source mentions `rand(`/`now(`/`read(`) — disables caching for it. (Note: in a
reactive notebook, memoizing `rand` is usually *desirable* — a cell only re-runs when a
dep changes, so a stable sample across reloads matches the existing model.)

### Mechanics

- **Atomic writes:** temp file + rename; a partial entry is never observable.
- **Storage:** content-addressed blobs on disk (the existing store), value payloads
  alongside. Keyed by the total digest above.
- **GC / eviction:** size-bounded **LRU + orphan collection** (a blob no live cell
  references is reclaimable). Surface what's evicted; never drop a referenced blob.

This makes the durable cache a general Slate capability — every expensive cell becomes
cold-start-free — with animations as the headline beneficiary.

---

## PDF / print

An animation cell emits a **poster frame** (frame 0, or the current playhead frame) as a
sidecar `image/png`, rasterized like HTML check-cards (`cell_image_fresh`). Without it,
animations vanish from export.

---

## Build plan

**v1 (the real, correct core):**
- `animate(frames; …)` for **`:heatmap`** (defer `:line`): transform → clim
  (`:global`/`:symmetric`/`:perframe`/explicit) → UInt8 quantize → LUT → gzip blob +
  manifest; signed/diverging handling; optional `times`.
- WebGL2 player: texture-array, LUT shader, bilinear + **temporal lerp**, dither, aspect
  ratio, real-coordinate axes; CPU fallback.
- Presentation clock + frame-drop + transport bar + keyboard transport.
- Lazy fetch + IntersectionObserver/visibility gating + reduced-motion.
- `playhead(anim)` throttled bind.
- Poster frame for PDF.
- Size caps (~128 MB, `maxbytes=` override) with clear messaging.
- **Automatic durable memoization**: total digest (cell ⊻ upstream ⊻ used-package src
  hash ⊻ Manifest), cost-thresholded selection, round-trippability check, `nocache`
  opt-out, atomic writes, LRU + orphan GC.

**v2 (designed-in, deferred):**
- `:line` (1-D radial wavepacket), `:image` (Makie→WebM/APNG via WebCodecs), `:scatter`,
  `:quiver`.
- OffscreenCanvas-in-worker rendering.
- Interframe compression (delta + RLE keyframes).
- Multi-rendition ABR; `bits=16` HDR display path; `requestVideoFrameCallback`.
- Chunked/ranged prefetch ahead of the playhead.

---

## Resolved decisions (from review)

1. **Player chrome** — yes for v1, provided axes show real `x`/`y` coordinates and the
   colormap matches the notebook theme. Makie-faithful rendering → v2 video route.
2. **Default `clim`** — `:global` for unsigned (comparable frames); **add `:symmetric`**
   + diverging map for signed data. That pair covers ~all scientific fields.
3. **Dither on by default** — yes. Free, strictly improves gradients, sub-pixel noise.
4. **Size cap** — ~128 MB raw, `log()`-surfaced, per-cell `maxbytes=` override (bounds
   worker RAM + GPU memory).
5. **`:line`** — deferred. `:heatmap` alone covers the helium course (time-domain
   quantities are better as a static multi-panel). `:line` is generally useful but
   blocks nothing.
6. **Caching model** — **automatic/transparent, pulled into v1** (per direction), made
   safe by the total digest above. The explicit `slate_cache(key)` is dropped; the
   src-hash fold replaces the manual `version=`/`salt=` knob and is more reliable.

## Open questions remaining

A. **Used-package scoping.** Hash the src of packages the notebook directly
   `using`/`import`s, or the full transitive dependency tree? Direct-only is cheaper and
   usually sufficient (you edit *your* package); transitive is more total but costs more
   to hash. Lean: direct + Manifest hash (which already pins transitive versions).
B. **Cost threshold.** What measured `duration` makes a cell worth persisting — fixed
   (e.g. ≥ 500 ms) or adaptive to total notebook eval time?
C. **`nocache` ergonomics.** Cell-tag only, or also a value-level `slate_nocache(x)`
   marker for a cell that's mostly cacheable but returns one impure piece?
