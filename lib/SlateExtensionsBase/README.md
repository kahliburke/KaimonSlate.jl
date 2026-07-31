# SlateExtensionsBase

A lean SDK for extending [Kaimon Slate](https://github.com/kahliburke/KaimonSlate.jl) from an
external package — custom `@bind` widgets, front-end output, browser↔Julia glue, and the per-cell
execution context — *without* depending on the Slate server itself.

Only dependency: `Base64` (a stdlib). Adding this to your package is essentially free.

## Why it exists

This is the counterpart to `AbstractPlutoDingetjes`. KaimonSlate depends on
`SlateExtensionsBase` and provides the meat — the running server, the concrete widgets, the
injected notebook namespace. Your extension package depends only on this, and so builds against
the *contract* rather than against a heavy server implementation.

That works because a `@bind` spec is already reduced to `(kind, params, default)` by the time it
reaches the wire. The `Widget` struct itself never crosses a process boundary, so this interface
is all a widget actually needs.

## Installation

```julia
pkg> add SlateExtensionsBase
```

## Extension points

**Controls** — define your own type and overload `to_widget` for a typed `@bind` control, plus
`register_kind!` for its value lifecycle. `Widget`, `Choice`, and `Selection` cover the common
shapes.

```julia
using SlateExtensionsBase

struct Stars
    max::Int
    default::Int
end

# The kind is derived from the TYPE, so it's namespaced by your package —
# two packages can each ship a `Stars` widget without colliding.
SlateExtensionsBase.to_widget(s::Stars) = Widget(Stars, s.default; max = s.max)
```

When a widget's fields simply *are* its UI params, `auto_widget(s)` reflects them for you.

**Output** — `WebPage` and `register_widget_js` ship HTML/CSS/JS to the page, both live and in
static exports.

**Execution context** — `slate_context` and its accessors (`slate_region`, `slate_emit`,
`slate_effect`, …) read Slate's per-cell context.

**Rich display** — `slate_render`, `component`, and `html_fragment` emit Slate's display MIMEs.

**Binary streaming** — `SlateBinary` and `encode_binary_frame` for numeric data that shouldn't
go through JSON.

## Registering without a boot cell

`register_widget!`, `register_component!`, and `provide_frontend!` let a package wire itself up
from its own `__init__`, so users of your extension don't have to paste a setup cell into every
notebook. `@pkg_asset` and `provide_assets!` handle shipping the accompanying static files.

## Front-end contract

The browser side needs no Julia dependency at all. Pair a control with:

```js
window.slateRegisterWidget("stars", { wire, sync, destroy });
```

Other globals the page exposes: `window.slateRegisterEditorExtension`, `window.slateCall`,
`window.slateOnStream`, and `Slate.runFragment` / `Slate.asset`.

## Makie

A package extension resolves the `showable` ambiguity between Slate's MIME methods and Makie's
greedy `showable(::MIME, ::Figure)`. It loads only when Makie is already present, so Makie stays
a weak dependency and this package stays install-light.

## License

MIT — see [LICENSE](LICENSE).
