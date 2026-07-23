# ── Makie ↔ Slate-MIME disambiguation ─────────────────────────────────────────
# SEB overloads `Base.showable(::SlateComponentMIME, ::Any)` / `(::SlateHtmlMIME, ::Any)` so a value
# with a `slate_render` method is preferred over `text/html`/`text/plain` by the display-capture scan.
# Makie, in turn, overloads `showable(::MIME, ::Union{Figure,FigureAxisPlot,Scene})` to gate on its
# active backend. For a Makie figure and a Slate MIME BOTH match and neither is more specific — so the
# call is AMBIGUOUS and *throws* a `MethodError`. Because the capture scan probes the Slate MIMEs first,
# that throw aborts rich capture for EVERY Makie figure (it collapses to its `text/plain` repr).
#
# Resolve it at the intersection: a method dispatching on the Slate MIME AND the Makie type is strictly
# more specific than both. It carries no logic of its own — `@invoke` defers to SEB's own `::Any` method
# — so the semantics are unchanged (a plain figure has no `slate_render` ⇒ `false`; a figure for which an
# extension DOES define `slate_render`, e.g. WGLMakie routed through a connection, still reports the MIME).
module SlateExtensionsBaseMakieExt

using SlateExtensionsBase: SlateComponentMIME, SlateHtmlMIME
using Makie: Figure, FigureAxisPlot, Scene

const _MakieDisplayable = Union{Figure, FigureAxisPlot, Scene}

Base.showable(m::SlateComponentMIME, x::_MakieDisplayable) =
    @invoke Base.showable(m::SlateComponentMIME, x::Any)
Base.showable(m::SlateHtmlMIME, x::_MakieDisplayable) =
    @invoke Base.showable(m::SlateHtmlMIME, x::Any)

end # module
