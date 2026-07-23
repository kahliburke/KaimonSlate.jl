try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# New Notebook
"""

#%% md id=f191df
@md"""
# Bonito ↔ KaimonSlate bridge (issue #7)

Exploration notebook for first-class **Bonito.jl** support — and through it interactive
**WGLMakie** WebGL figures. Parent project: `BonitoSlate` (`examples/extensions/BonitoSlate`).

**The three bridges we're prototyping here, then extracting into `BonitoSlate`:**

1. **Communication** — a `SlateConnection <: Bonito.FrontendConnection` that routes Bonito's
   session frames over Slate's *existing* per-notebook WebSocket (Julia→JS `slate_emit` / binary
   lane; JS→Julia `slate_on` + `slateCall`) — no second WebSocket, no extra port.
2. **Cell lifecycle** — close the Bonito `Session` when the reactive DAG re-evaluates/destroys the
   cell, so WebGL/session state isn't leaked.
3. **JS injection** — ship Bonito's JS runtime + the connection shim via the SEB front-end registry,
   resolved through Slate's offline-pinned import map.

Baseline first: confirm a **CairoMakie** static figure renders, then a **WGLMakie** figure via the
default Bonito boot, then swap in the Slate-routed connection.
"""

#%% code id=baseline_cairo
using CairoMakie
CairoMakie.activate!()
use_slate_theme!()

let
    fig = Figure(size = (560, 320))
    ax = Axis(fig[1, 1]; title = "CairoMakie baseline (static)", xlabel = "x", ylabel = "sin x")
    lines!(ax, 0:0.05:4π, sin; color = :dodgerblue)
    fig
end

#%% md id=step1_findings
@md"""
## Step (1) findings — stock WGLMakie/Bonito boot

**Prerequisite bug found + fixed.** SEB's `showable(::SlateComponentMIME/::SlateHtmlMIME, ::Any)` is
*ambiguous* with Makie's `showable(::MIME, ::Figure)` → the call **throws**, and `_capture_rich!`
(capture.jl) probed it unguarded, so the throw aborted rich capture and **every** Makie figure (Cairo
*and* WGL) collapsed to its `Figure()` text repr. Fixed properly with a **weakdep package extension**
`SlateExtensionsBaseMakieExt` that resolves the clash at the intersection via `@invoke` (no hard dep;
loads only when Makie is present). ✔ CairoMakie renders again; ✔ WGLMakie now reaches `text/html`.
*(Affects all current Slate users → the same ext must land in the hub's SEB via the merge.)*

**Stock boot behaviour** (once unblocked): WGLMakie emits a `text/html` fragment that
- auto-starts **Bonito's own HTTP server on a separate worker port** (`localhost:9384`),
- loads `Bonito.bundled.js` / `WGLMakie.bundled.js` / `Websocket.bundled.js` via **absolute-URL**
  `<script src>` (✔ `window.Bonito` boots, ✔ `<canvas>` + WebGL context created),
- calls `Bonito.init_session(uuid, fetch_binary('localhost:9384/…​.bin'), "root", false)` + opens its
  **own WebSocket** back to `9384`.

**Two concrete blockers → the bridges:**
1. **Own port / absolute URLs** → breaks for remote/region workers (browser can't reach the worker's
   `localhost:9384`) and violates the "no extra port" goal. → **bridge #1: `SlateConnection`.**
2. **Double-boot** → `init_session` runs twice for one output (Slate swaps output twice per run +
   re-runs `<script>`s), and Bonito's ordered-message system rejects it: *"Duplicate task for order 1"*
   → the spinner never clears. → **bridge #2: single, idempotent boot + teardown on re-eval.**
"""

#%% code id=enable_slateconn
using BonitoSlate, WGLMakie
WGLMakie.activate!()          # re-assert WGLMakie as the Makie backend (baseline_cairo activated Cairo)
BonitoSlate.enable!()

#%% code id=wgl_3d
let
    xs = range(-3, 3; length = 80)
    ys = range(-3, 3; length = 80)
    zs = [exp(-(x^2 + y^2)/3) * sin(2x) * cos(2y) for x in xs, y in ys]
    fig = Figure(size = (1120, 1060))
    ax = Axis3(fig[1, 1]; title = "WGLMakie 3D surface over SlateConnection — drag to rotate",
               xlabel = "x", ylabel = "y", zlabel = "z")
    surface!(ax, xs, ys, zs; colormap = :viridis)
    fig
end

#%% code id=abd8e8 hidecode
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
#   docid = 2c55654a-3031-41a2-8f60-e4890375a56e
# ╚═╡
