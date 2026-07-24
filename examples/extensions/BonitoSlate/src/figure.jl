# ── Figure presentation: a self-contained snapshot on a centered dark card ────────────────────────
# A returned WGLMakie figure renders through SEB's Slate HTML MIME as the SELF-CONTAINED offline HTML
# fragment `enable!()` configures (scene inlined, no live socket), wrapped in a centered, dark, subtly
# bordered card so it sits cleanly in Slate's dark UI. The card's styles are INLINE so the whole output
# stays self-contained — it survives a browser reload, a static export, and a published site unchanged.
#
# Presentation is guarded to the WGLMakie backend: a CairoMakie figure (raster) must fall through to
# `image/png`, so the Slate MIME is not `showable` for it and Slate's capture picks the raster MIME.

_is_wgl_backend() = (b = Makie.current_backend(); b isa Module && nameof(b) === :WGLMakie)

# A `<script src="/n/<id>/served/<hash>" type="module">` that loads the Bonito runtime (Bonito.js
# self-assigns `window.Bonito`). Served once, deduped by URL — safe to include in every figure card so the
# runtime is present regardless of which session is the page root. Empty before `enable!()` sets `_NB_ID`.
function _bonito_runtime_script()
    isempty(_NB_ID[]) && return ""
    url = try
        Bonito.url(SlateAssetServer(), Bonito.BonitoLib)
    catch
        return ""
    end
    return string("<script src=\"", url, "\" type=\"module\"></script>")
end

# The renderer: the figure fragment (scene + live wiring), wrapped in the card, with the Bonito RUNTIME
# script prepended. Bonito only emits its runtime `<script>` for the page-ROOT session, so a figure that
# renders as a SUB (any figure after the first, or a re-render while a root persists) carries no runtime
# loader — and its stored output then fails to boot on reload. We load the runtime from its stable served
# URL in EVERY card instead: the browser dedups by URL (one load per page) and Slate's `runScripts` awaits
# the `src` module before the figure's init runs, so `window.Bonito` is always defined first.
function slate_card_html(fig::Makie.FigureLike)
    try
        frag = sprint((io, x) -> show(io, MIME"text/html"(), x), fig)
        return _figure_card(_bonito_runtime_script() * frag)
    catch e
        # Surface a render failure inline rather than let capture swallow it into a `text/plain` repr.
        return string("<pre style=\"color:#f88;white-space:pre-wrap\">BonitoSlate figure render error:\n",
                      sprint(showerror, e), "</pre>")
    end
end

# Pin the `show`/`showable` methods at the SEB × Makie intersection. Two constraints shape this:
#   1. AMBIGUITY — SEB defines `show`/`showable` for its Slate MIMEs over a generic value; Makie defines
#      them for a generic MIME over its figure types. A `(SlateHtmlMIME, Figure)` call matches both and is
#      more specific in neither, so a bare `show(io, SlateHtmlMIME(), fig)` is a MethodError — which the
#      display capture swallows, collapsing the figure to its `text/plain` repr.
#   2. OVERWRITE — SEB's own Makie extension (`SlateExtensionsBaseMakieExt`) already pins `showable` for
#      the figure UNION `Union{Figure,FigureAxisPlot,Scene}` to break that ambiguity generically (it defers
#      to `slate_render`). Re-declaring the SAME union signature here OVERWRITES a method another module
#      owns — an ERROR during precompilation (it only warns under Revise), so BonitoSlate would fail to
#      precompile and load interpreted.
# Dispatching on the CONCRETE figure types satisfies both: each is strictly more specific than Makie's
# generic-MIME method AND than the extension's union method, so it overrides by specificity WITHOUT
# overwriting, and leaves no ambiguity. We keep `showable` a cheap backend check (NOT
# `slate_render(fig) isa SlateHtml`) so a WGLMakie figure — whose render OPENS a Bonito session — renders
# exactly ONCE (in `show`), not again on every `showable` probe.
for T in (Makie.Figure, Makie.FigureAxisPlot, Makie.Scene)
    @eval begin
        Base.showable(::SlateExtensionsBase.SlateHtmlMIME, ::$T)      = _is_wgl_backend()
        Base.showable(::SlateExtensionsBase.SlateComponentMIME, ::$T) = false  # a figure is HTML, never a component
        Base.show(io::IO, ::SlateExtensionsBase.SlateHtmlMIME, fig::$T) = print(io, slate_card_html(fig))
        # SESSION-BOUND: a WGLMakie figure's scene + interaction (e.g. Axis3 rotation) live in a worker
        # Bonito session, not in the captured HTML, so Slate re-renders it fresh for each browser page that
        # connects (a reload, a new tab). A CairoMakie figure is a self-contained raster, so it's not live.
        SlateExtensionsBase.slate_live_render(::$T) = _is_wgl_backend()
    end
end

# The centered dark card. Structure only — the styling lives in `assets/figure.css` (registered on the
# page from `__init__`, and carried into a static export). The card's `.bonito-fig-card:focus-within`
# rule lights its border when the (focusable, `tabindex=0`) WGLMakie canvas has focus.
function _figure_card(inner::AbstractString)
    return string("<div class=\"bonito-fig-wrap\"><div class=\"bonito-fig-card\" tabindex=\"-1\">",
                  inner, "</div></div>")
end
