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
Bonito.render_asset(session::Bonito.Session, ::SlateAssetServer, asset::Bonito.Asset) =
    Bonito.render_asset(session, Bonito.NoServer(), asset)
Bonito.import_in_js(io::IO, session::Bonito.Session, ::SlateAssetServer, asset::Bonito.Asset) =
    Bonito.import_in_js(io, session, Bonito.NoServer(), asset)
Bonito.inline_code(session::Bonito.Session, ::SlateAssetServer, source::String) =
    Bonito.inline_code(session, Bonito.NoServer(), source)
Bonito.setup_asset_server(::SlateAssetServer) = nothing
Bonito.url(::SlateAssetServer, asset::Bonito.BinaryAsset) = Bonito.url(Bonito.NoServer(), asset)

# The one behaviour change: an es6 module is SERVED once (stable URL) instead of inlined per render.
function Bonito.url(::SlateAssetServer, asset::Bonito.Asset)
    isempty(asset.online_path) || return asset.online_path
    if asset.es6module && !isempty(_NB_ID[])
        bytes = _asset_bytes(asset)
        if bytes !== nothing
            path = SlateExtensionsBase.provide_served_asset!(bytes; mime = "application/javascript")
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
