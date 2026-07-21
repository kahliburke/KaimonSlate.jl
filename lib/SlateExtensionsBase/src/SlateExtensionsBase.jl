"""
    SlateExtensionsBase

A lean (Base + stdlib only) SDK for extending **Kaimon Slate** from an external package —
custom `@bind` widgets, front-end output, browser↔Julia glue, and the per-cell execution
context — *without* depending on the (heavy) KaimonSlate server.

This is the counterpart to `AbstractPlutoDingetjes`: KaimonSlate depends on it and provides the
"meat" (the running server, concrete widgets, the injected notebook namespace), while an
extension package depends only on this to build against the *contract*. Because a `@bind` spec is
already reduced to `(kind, params, default)` on the wire, this interface is all a widget needs —
the `Widget` struct itself never crosses a process boundary.

## Extension points

- **Controls** — [`Widget`](@ref), [`Choice`](@ref), [`Selection`](@ref); define your own type and
  overload [`to_widget`](@ref) for a typed `@bind` control, and [`register_kind!`](@ref) for its
  value lifecycle.
- **Output** — [`WebPage`](@ref) and [`register_widget_js`](@ref) ship HTML/CSS/JS to the page
  (live and in exports).
- **Execution context** — [`slate_context`](@ref) and its accessors ([`slate_region`](@ref),
  [`slate_emit`](@ref), [`slate_effect`](@ref), …) read Slate's per-cell context.

## Front-end contract (JS globals; no Julia dependency)

Pair a control with `window.slateRegisterWidget("<kind>", {wire, sync, destroy})`. Other globals
the page exposes: `window.slateRegisterEditorExtension`, `window.slateCall` / `window.slateOnStream`,
and `Slate.runFragment` / `Slate.asset`.
"""
module SlateExtensionsBase

import Base64   # stdlib — WebPage(obscure=true) base64 packaging

include("controls.jl")
include("output.jl")
include("context.jl")
include("frontend.jl")
include("render.jl")
include("binary.jl")

# Controls
export Widget, Choice, Selection, indices, to_widget, auto_widget, kind_for
export register_kind!, widget_kinds, coerce_bind, reconcile_bind, wrap_value, coerce_value
# Output
export WebPage, register_widget_js
# Auto-registered front-end (no boot cell)
export register_widget!, register_component!, provide_frontend!, @pkg_asset,
       required_assets, ensure_widget_assets!, ensure_module_frontend!, ensure_module_frontends!,
       frontend_scripts, extension_manifest
# Execution context
export slate_context, slate_region, slate_regions, slate_side, slate_notebook,
       slate_emit, slate_effect, slate_everywhere, slate_on
# Rich output (Slate display MIMEs)
export slate_render, component, html_fragment, SlateComponentMIME, SlateHtmlMIME
# Binary numeric streaming
export SlateBinary, encode_binary_frame

end # module
