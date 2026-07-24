try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=f191df
@md"""
# BonitoSlate — live WGLMakie over Slate (issue #7)

`BonitoSlate` brings first-class **Bonito.jl** support — and with it interactive **WGLMakie**
WebGL figures — to KaimonSlate, routed over Slate's *existing* per-notebook WebSocket. No second
socket and no extra port, so it works for a local worker and a remote/region worker alike.

**How it works** (extension in `examples/extensions/BonitoSlate`):

1. **Transport** — `SlateConnection <: Bonito.FrontendConnection` carries Bonito's session frames
   over Slate's page transport (Julia→JS binary lane; JS→Julia `slate_on` / `slateCall`).
2. **Runtime served once** — `SlateAssetServer` serves the Bonito JS runtime a single time per page
   at a stable URL, instead of re-inlining it into every figure.
3. **Reload-safe** — a returned figure is re-rendered fresh for each browser page that connects (a
   reload, a new tab), the way a Bonito server serves a fresh session per page load.

Below: a **CairoMakie** baseline confirms static rendering, then a **live WGLMakie 3D surface**
renders over Slate — drag to rotate; it survives a browser reload.
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

#%% code id=enable_slateconn
using BonitoSlate, WGLMakie
WGLMakie.activate!()          # re-assert WGLMakie as the Makie backend (baseline_cairo activated Cairo)
BonitoSlate.enable!()

#%% code id=077cda
@bind n Slider(1:10)
@bind pts Slider(50:200)

#%% code id=wgl_3d controls=[n,pts] nocache
let
    xs = range(-3, 3; length = 100)
    ys = range(-3, 3; length = 100)
    zs = [exp(-(x^2 + y^2) / 3) * sin(2x) * cos(n*y) for x in xs, y in ys]
    fig = Figure(size = (820, 860))
    # Axis label/tick colours come from `use_slate_theme!()` (see baseline_cairo). Note: WGLMakie does not
    # currently render the Axis3 box (panels/grids/spines) that CairoMakie/GLMakie draw, so the live figure
    # shows the surface + labels without an enclosing frame; a static/PDF export renders the full box.
    ax = Axis3(fig[1, 1]; title = "WGLMakie 3D surface — live over Slate (drag to rotate)",
               xlabel = "x", ylabel = "y", zlabel = "z")
    surface!(ax, xs, ys, zs; colormap = :viridis)
    fig
end

# ╔═╡ Slate.config · per-notebook settings (Settings panel)
#   docid = 2c55654a-3031-41a2-8f60-e4890375a56e
# ╚═╡
