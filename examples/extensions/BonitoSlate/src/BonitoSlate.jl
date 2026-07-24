"""
    BonitoSlate

First-class Bonito.jl support for KaimonSlate — and through it, interactive WGLMakie WebGL figures and
the Bonito widget ecosystem — layered on the SlateExtensionsBase SDK.

## The bridges (see issue #7)

1. **Communication** — [`SlateConnection`](@ref) routes a Bonito `Session`'s frames over Slate's
   existing per-notebook WebSocket (Julia→JS via the binary lane, JS→Julia via `slate_on`/`slateCall`),
   so Bonito opens no WebSocket and no extra port. Paired with Bonito's `NoServer` (assets inlined as
   `data:` URLs) the emitted fragment references no `localhost` URL — so it works for a remote worker too.
2. **Cell lifecycle** — closing a Bonito `Session` when the reactive DAG re-evaluates/destroys a cell
   (in progress).
3. **JS injection** — Bonito's JS runtime rides the inlined bundle today; a shared/hub-served bundle is a
   follow-up so it isn't re-inlined per figure.

## Usage (MVP)

```julia
using WGLMakie, BonitoSlate
BonitoSlate.enable!()          # route Bonito through Slate + inline assets (call once, in a cell)
scatter(1:10, rand(10))        # renders over Slate's transport — no extra port
```
"""
module BonitoSlate

import Bonito
import Base64
import Makie
using SlateExtensionsBase

include("connection.jl")
include("assetserver.jl")
include("figure.jl")

"""
    enable!()

Set Bonito/WGLMakie up to render figures LIVE **and** SELF-CONTAINED for this notebook — the snapshot is
the paint, the live channel is the interaction:

- `NoServer` inlines the JS bundle **and each figure's initial scene** (its `init` blob) as `data:` URLs.
  The captured output is therefore self-sufficient: a browser reload, a static export, and a published
  site all render the figure straight from the fragment — no worker required, no extra port.
- [`SlateConnection`] routes any POST-load Julia→browser / browser→Julia traffic over Slate's existing
  per-notebook transport. That's what a figure driven by Julia after first paint needs — e.g. an `Axis3`,
  whose drag-to-rotate updates its azimuth/elevation **in Julia** (there is no client-side 3D camera), so
  rotation only works while a worker is connected. Because the initial scene is INLINED, the fresh page
  has every object registered before the live channel sends its first ref-keyed update — so the live
  overlay re-attaches cleanly on reload instead of hitting an object-cache desync.

Also installs a Slate-matching dark Makie theme so a returned figure blends into the notebook's dark
card (see `figure.jl`). Run it once from inside a Slate cell before displaying a figure.
"""
function enable!()
    ctx = SlateExtensionsBase.slate_context()
    ctx === nothing && error("BonitoSlate.enable!() must run inside a Slate cell (no execution context)")
    _SLATE_EMIT[] = ctx.emit
    _SLATE_ON[]   = ctx.on
    _SLATE_OFF[]  = ctx.off      # captured for session teardown (drop the per-session inbox handler)
    _NB_ID[]      = String(ctx.notebook)   # for served-asset URLs (/n/<id>/served/<hash>) — see SlateAssetServer
    Bonito.force_connection!(SlateConnection)
    # SlateAssetServer: inline like NoServer, but serve es6 modules (the Bonito runtime) ONCE per page over
    # Slate at a stable URL instead of re-inlining the ~3.5 MB bundle into every figure (see assetserver.jl).
    Bonito.force_asset_server!(SlateAssetServer)
    # Start this page's Bonito session tree fresh (drop any prior page-root, clear CURRENT_SESSION) so the
    # next figure establishes a NEW root — see `_reset_page!` / `use_parent_session` in connection.jl.
    _reset_page!()
    # A browser (re)connect must re-render live figures against a FRESH page root — register the reset so
    # Slate runs it before re-rendering `_LIVE_OUTPUTS` on connect (see SEB `on_live_reset`).
    SlateExtensionsBase.on_live_reset(_reset_page!)
    # Dark, transparent-background Makie theme so a figure sits cleanly on Slate's dark figure card (the
    # card supplies the panel colour; the figure blends into it). `theme_dark` gives light text + spines;
    # we only override the backgrounds to transparent.
    Makie.set_theme!(Makie.theme_dark())
    Makie.update_theme!(backgroundcolor = :transparent,
                        Axis  = (backgroundcolor = :transparent,),
                        Axis3 = (backgroundcolor = :transparent,))
    _register_frontend!()
    return nothing
end

# Ship the figure card CSS (assets/figure.css) + interaction JS (assets/figure.js) to the page. Registered
# process-globally (deduped by id), so Slate injects them into any notebook using BonitoSlate — live and in
# a static export — keeping the assets out of the Julia source. Called from `enable!` (not `__init__`) so a
# source edit hot-reloads via Revise on the next enable, no worker restart.
function _register_frontend!()
    css = @pkg_asset("assets/figure.css")
    provide_frontend!(string(
        "(function(){var id='bonito-slate-figure-css';if(document.getElementById(id))return;",
        "var s=document.createElement('style');s.id=id;s.textContent=", repr(css), ";",
        "document.head.appendChild(s);})();"); id = "BonitoSlate.figure-css")
    # Scroll-zoom gating (click-to-activate + sensitivity) now lives in Slate core (settings.js) as a shared
    # behaviour + a "Chart scroll-zoom" setting, so it also covers ECharts — nothing to ship here. Drop the
    # old per-figure gate script if a prior version registered it (else two gates would fight on the wheel).
    delete!(SlateExtensionsBase._FRONTEND, "BonitoSlate.figure-js")
    return nothing
end

function __init__()
    return nothing
end

end # module
