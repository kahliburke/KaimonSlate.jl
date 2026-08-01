# ── SlateAssetServer: serve Bonito's JS runtime ONCE per page, over Slate's transport ─────────────
# `NoServer` inlines EVERY asset as a `data:` URL — including the ~3.5 MB Bonito bundle — into every
# figure's fragment. Re-inlining + re-executing that bundle on an already-loaded page (a re-render, a
# reload) races Bonito's init ("Bonito is not defined") and re-ships megabytes each render. This server
# keeps NoServer's inline behaviour for everything EXCEPT es6-module URLs: those it registers with Slate
# (content-addressed, `provide_served_asset!`) and references by a STABLE `/n/<id>/served/<hash>` URL, so
# the browser loads each module exactly once (immutable-cached) and a re-render just re-uses the cached
# module — no re-execution race, and each render ships only the scene, not the runtime.

# The notebook's URL id (ctx.notebook), captured by `enable!` so a served URL can be `/n/<id>/served/…`.
const _NB_ID = Ref{String}("")

struct SlateAssetServer <: Bonito.AbstractAssetServer end
Base.similar(s::SlateAssetServer) = s

# Everything but es6-module URLs behaves EXACTLY like NoServer (inline as `data:` URLs): forward the
# render/import/inline machinery so only the module-URL resolution changes.
function Bonito.render_asset(session::Bonito.Session, ::SlateAssetServer, asset::Bonito.Asset)
    return Bonito.render_asset(session, Bonito.NoServer(), asset)
end
function Bonito.import_in_js(
    io::IO, session::Bonito.Session, ::SlateAssetServer, asset::Bonito.Asset
)
    return Bonito.import_in_js(io, session, Bonito.NoServer(), asset)
end
Bonito.setup_asset_server(::SlateAssetServer) = nothing

# Each rendered fragment ships a small `<script type="module">` that calls `Bonito.init_session(…)` —
# against the GLOBAL `Bonito`, which the runtime module sets as a side effect (`window.Bonito = …`).
# Nothing in that script IMPORTS the runtime, so the browser has no dependency edge to order them by:
# with the runtime served at a URL (rather than inlined ahead of the script), a page carrying several
# fragments races, and the losers die with "Bonito is not defined" — the fragment paints and is then
# wiped when its init throws. It shows up on RELOAD in particular, when every fragment initialises at
# once against a cold module cache.
#
# Importing the runtime first creates exactly the missing edge, and a URL is only ever evaluated once
# no matter how many fragments import it. It has to be a DYNAMIC import resolved against the document,
# though: this script is itself served as a `data:` URL, and a root-relative `/n/<id>/served/<hash>`
# specifier has no hierarchical base to resolve against there ("Invalid relative url or base scheme
# isn't hierarchical"). `new URL(path, document.baseURI)` resolves against the PAGE instead, and the
# top-level `await` keeps the ordering guarantee — the module body suspends until the runtime is live.
function Bonito.inline_code(session::Bonito.Session, server::SlateAssetServer, source::String)
    runtime = Bonito.url(server, Bonito.BonitoLib)
    prelude = string("await import(new URL(", repr(runtime), ", document.baseURI).href);\n")
    return Bonito.inline_code(session, Bonito.NoServer(), prelude * source)
end

# A `BinaryAsset` is how Bonito ships BULK DATA to the page (`Bonito.fetch_binary(url)` → ArrayBuffer)
# — a volume grid, a mesh, a big numeric column. `NoServer` would inline it as a base64 `data:` URL,
# which inflates the bytes ~33% and, worse, embeds them in the CELL OUTPUT: a few MB of payload makes
# Slate refuse to render the cell ("output too large") and bloats the saved notebook. So binary
# assets get the same treatment as es6 modules — served once at a stable content-addressed URL, with
# the bytes staying in the worker until a browser actually asks for them.
function Bonito.url(::SlateAssetServer, asset::Bonito.BinaryAsset)
    if !isempty(_NB_ID[])
        path = SlateExtensionsBase.provide_served_asset!(asset.data; mime=asset.mime)
        return string("/n/", _NB_ID[], path)
    end
    return Bonito.url(Bonito.NoServer(), asset)   # fallback: inline (no notebook id — e.g. a bare export)
end

# The one behaviour change: an es6 module is SERVED once (stable URL) instead of inlined per render.
function Bonito.url(::SlateAssetServer, asset::Bonito.Asset)
    isempty(asset.online_path) || return asset.online_path
    if asset.es6module && !isempty(_NB_ID[])
        bytes = _asset_bytes(asset)
        if bytes !== nothing
            path = SlateExtensionsBase.provide_served_asset!(bytes; mime="application/javascript")
            return string("/n/", _NB_ID[], path)   # → /n/<id>/served/<hash>, served by the hub
        end
    end
    return Bonito.url(Bonito.NoServer(), asset)     # fallback: inline (CSS, non-module JS, or unknown id)
end

# A module's bytes: the bundled form (deno-bundled deps) if present, else the raw source file. Mirrors
# how `HTTPAssetServer` picks what to serve (asset-serving/http.jl).
function _asset_bytes(asset::Bonito.Asset)
    try
        Bonito.bundle!(asset)
        isempty(asset.bundle_data) || return Vector{UInt8}(Bonito.bundle_data_snapshot(asset))
        p = Bonito.local_path(asset)
        return isfile(p) ? read(p) : nothing
    catch
        return nothing
    end
end
