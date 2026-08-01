# ── Figure presentation: a self-contained snapshot on a centered dark card ────────────────────────
# A returned WGLMakie figure renders through SEB's Slate HTML MIME as the SELF-CONTAINED offline HTML
# fragment `enable!()` configures (scene inlined, no live socket), wrapped in a centered, dark, subtly
# bordered card so it sits cleanly in Slate's dark UI. The card's styles are INLINE so the whole output
# stays self-contained — it survives a browser reload, a static export, and a published site unchanged.
#
# Presentation is guarded to the WGLMakie backend: a CairoMakie figure (raster) must fall through to
# `image/png`, so the Slate MIME is not `showable` for it and Slate's capture picks the raster MIME.

_is_wgl_backend() = (b=Makie.current_backend(); b isa Module && nameof(b) === :WGLMakie)

# The renderer: the figure fragment (scene + live wiring), wrapped in the card. Everything shared with any
# other Bonito output — the runtime loader, the root announcement, the render lock, session bookkeeping —
# lives in `bonito_output_html` (app.jl), since a figure is one kind of Bonito output rather than a separate
# mechanism. This function's own job is only the card.
function slate_card_html(fig::Makie.FigureLike)
    try
        # `bonito_output_html` (app.jl) owns the shared contract for every Bonito output: the runtime loader,
        # the page-root announcement ordered ahead of the fragment, the render lock, and registering the
        # sub-session this render creates so it is released when the cell re-evaluates. A figure is just one
        # kind of Bonito output, so it differs from an app only in being wrapped in the card below.
        return _figure_card(
            bonito_output_html() do
                return sprint((io, x) -> show(io, MIME"text/html"(), x), fig)
            end,
        )
    catch e
        # Surface a render failure inline rather than let capture swallow it into a `text/plain` repr.
        return string(
            "<pre style=\"color:#f88;white-space:pre-wrap\">BonitoSlate figure render error:\n",
            sprint(showerror, e),
            "</pre>",
        )
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
        Base.showable(::SlateExtensionsBase.SlateHtmlMIME, ::$T) = _is_wgl_backend()
        Base.showable(::SlateExtensionsBase.SlateComponentMIME, ::$T) = false  # a figure is HTML, never a component
        Base.show(io::IO, ::SlateExtensionsBase.SlateHtmlMIME, fig::$T) =
            print(io, slate_card_html(fig))
        # SESSION-BOUND: a WGLMakie figure's scene + interaction (e.g. Axis3 rotation) live in a worker
        # Bonito session, not in the captured HTML, so Slate re-renders it fresh for each browser page that
        # connects (a reload, a new tab). A CairoMakie figure is a self-contained raster, so it's not live.
        SlateExtensionsBase.slate_live_render(::$T) = _is_wgl_backend()
    end
end

# The centered dark card. Structure only — the styling lives in `assets/figure.css` (registered on the
# page from `__init__`, and carried into a static export). The card's `.bonito-fig-card:focus-within`
# rule lights its border when the (focusable, `tabindex=0`) WGLMakie canvas has focus.
#
# `data-slate-zoomable` opts the card into Slate's chart scroll-zoom gate (core `settings.js`), whose
# whole contract is that attribute: the wheel reaches the figure only once the reader has clicked into
# it, scaled by their "Chart scroll-zoom" setting, instead of hijacking the page as they scroll past.
# The value names WGLMakie's zoom surface — the canvas is what Makie listens on, not this card.
function _figure_card(inner::AbstractString)
    return string(
        "<div class=\"bonito-fig-wrap\">",
        "<div class=\"bonito-fig-card\" tabindex=\"-1\" data-slate-zoomable=\"canvas\">",
        inner,
        "</div></div>",
    )
end
