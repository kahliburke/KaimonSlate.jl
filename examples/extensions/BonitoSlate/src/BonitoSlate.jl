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
using SlateExtensionsBase

include("connection.jl")

"""
    enable!()

Route Bonito/WGLMakie through Slate's transport for this notebook: capture the cell's `slate_emit` /
`slate_on` from the execution context and force Bonito to use [`SlateConnection`](@ref) + `NoServer`
(inlined assets). Call it once from inside a Slate cell before displaying a WGLMakie figure. (A later
revision auto-wires this via SEB's `__slate_frontend` hook so no explicit call is needed.)
"""
function enable!()
    ctx = SlateExtensionsBase.slate_context()
    ctx === nothing && error("BonitoSlate.enable!() must run inside a Slate cell (no execution context)")
    _SLATE_EMIT[] = ctx.emit
    _SLATE_ON[]   = ctx.on
    _SLATE_OFF[]  = ctx.off      # captured for session teardown (drop the per-session inbox handler)
    Bonito.force_connection!(SlateConnection)
    Bonito.force_asset_server!(Bonito.NoServer)
    # Start this page's Bonito session tree fresh: drop any prior page-root and clear `CURRENT_SESSION`, so
    # the next figure establishes a NEW root for THIS browser page. Re-running `enable!()` (a reload re-runs
    # its cell, or the user re-runs it) therefore recovers cleanly rather than subbing figures onto a dead
    # root left from the previous page. All figures after this share the one root (see `use_parent_session`).
    _reset_page!()
    return nothing
end

function __init__()
    return nothing
end

end # module
