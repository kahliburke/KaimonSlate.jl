# Slate extension authoring — the dispatch-based model

How a third-party package adds **input widgets**, **rich output**, and **front-end assets** to Slate,
depending only on `SlateExtensionsBase` (SEB). The design principle: **everything an extension declares
is multiple dispatch on a type (or module) — no `__init__`, no hand-typed labels, no boilerplate.**
Slate owns the workflow (it calls the dispatch points when it renders a cell); the package just defines
methods.

Status legend: **[built]** implemented + suite-green on `feat/widget-interface-pkg`; **[proposed]**
agreed design, not yet built.

> **As shipped (GiacSlate conversion, live-validated).** Both front-end surfaces are now **[built]** and
> exercised end-to-end by GiacSlate with **no `__init__` and no boot cell** — `using GiacSlate` is the
> whole setup:
> - **Per-widget** — `Mathfield` = `to_widget` (`auto_widget`, kind `GiacSlate.Mathfield`) +
>   `required_assets(::Type{Mathfield})` → `assets/mathfield.js` (a `@slate/widget` component). Loads lazily
>   on first bind; value coerces `String`→`mathfield_to_giac`.
> - **Package-global** — the editor extension + `giac_src`/`giac_tex` RPC handlers ride a named-convention
>   hook `GiacSlate.__slate_frontend(slate_on)` (dispatch on a *specific* module is impossible — every module
>   is `::Module` — so detection is method-presence, `isdefined(m, :__slate_frontend)`, the module-granularity
>   analog of the widget path's "a method exists"). SEB: `ensure_module_frontend!`/`ensure_module_frontends!`.
> - **Trigger** (INTERNAL, freely alterable behind the stable extension contract): a **guarded scan** at the
>   once-per-drain manifest pull — `ensure_module_frontends!(slate_on)` over `Base.loaded_modules_array()`,
>   with the *work* fired once per `(module, namespace-generation)` (`_MODULE_FRONTEND_DONE`, keyed on the
>   namespace's `slate_on`). Chosen over a using-resolution trigger because it is **load-path-agnostic** —
>   it survives fresh eval, **memo-restore / scaffold-replay** (`_replay_scaffold!` bypasses `run_capture`),
>   reboot, and namespace rebuild (fresh `slate_on` ⇒ handlers reinstalled). Measured cost ≈ **2.5 µs/drain**
>   over 84 loaded modules. Because packages define only the methods and never see the trigger, this can be
>   swapped later (e.g. multi-site using-detection) with zero extension-package changes.

---

## The model at a glance

An extension defines dispatch methods on its own widget/value types:

| Surface | Dispatch point | Triggered when | Status |
|---|---|---|---|
| Input control (`@bind`) | `to_widget(x)::Widget` | Slate evaluates `@bind name x` | **[built]** |
| Value coercion | `coerce_value(::Type{T}, v)` (+ optional `register_kind!(...; domain=)`) | browser value → Julia value | **[built]** |
| Rich output (display) | `slate_render(x)` → component descriptor, over the Slate MIME | Slate displays a returned value | **[proposed]** |
| Per-widget front-end | `required_assets(::Type{W})` → JS module | first bind/display of `W` | **[proposed]** |
| Package front-end (editor ext, RPC handlers) | `required_assets(::Module)` (or a named hook) | the package is `using`'d in the notebook | **[proposed]** |

No `__init__`. Slate invokes each hook lazily from a path it already owns (the `@bind`/`to_widget`
path, the display path, the `using`-resolution path). A type/module with no method contributes nothing —
**dispatch is the extension-detection mechanism.**

The front-end side (widget renderers) is authored as **Preact + signals component modules** shipped as
real `.js` files; Slate injects them into the page via the **extension manifest** (below).

---

## Frozen contracts (decide once, change never)

These are baked into every extension the moment it's written, so they must be chosen deliberately:

1. **The Slate display MIMEs (two — the suffix matches the payload format).** Precedent: VSCodeServer's
   `DISPLAYABLE_MIMES` (`vnd.vegalite.v5+json` for JSON specs; `vnd.julia-vscode.plotpane+html` for HTML
   fragments), dispatched by a priority-ordered `showable` scan.
   - `application/vnd.kaimonslate.component+json` — a JSON **component descriptor** `{v, component, props}`;
     the front-end mounts the registered component. (Blessed path.)
   - `application/vnd.kaimonslate.html+html` — a self-contained **HTML fragment** (escape hatch; the clean
     replacement for hand-rolled `Base.show(::MIME"text/html")`).
   - IANA vendor tree (`vnd.`), globally unique (`kaimonslate`, not `slate` — that name collides). The
     role is in the sub-label (`.component`/`.html`), like VS Code's `.plotpane`/`.custompane`.
   - **Version lives in the payload (`{v: 1, …}`), not the MIME string** — one evolving contract, not a new
     MIME per revision (unlike `vegalite.v5`, which versions a third-party renderer in the string).
   - SEB exposes them as type aliases so no one hand-types the strings:
     `const SlateComponentMIME = MIME"application/vnd.kaimonslate.component+json"`,
     `const SlateHtmlMIME = MIME"application/vnd.kaimonslate.html+html"`.
   - **Display dispatch** (VS Code pattern): Slate scans a priority-ordered MIME list via `showable`, first
     match wins — `component+json` → `html+html` → `text/html` → `text/plain`.

2. **The widget `kind` derivation:** `kind_for(T) == string(parentmodule(T), '.', nameof(T))`
   — e.g. `"StarRating.Stars"`. Namespaced by the defining module, so two packages can't collide.
   **[built]**

3. **The widget-SDK import specifier:** `@slate/widget` — the ONE module a component imports (never bare
   `preact`), so the page shares a single Preact/signals instance. Live: importmap →
   `/assets/js/slate-widget.js`; export: an inlined `data:`/blob module. **[built]**

4. **The extension manifest shape** (worker → hub → page): `{frontend: [{id, js, esm, kind}]}`, extensible
   with new fields (e.g. `assets`) as seams are added. **[built]**

5. **The component-descriptor payload** (what `slate_render` emits and `@bind` mounts):
   `{v: 1, component: "<kind>", props: {…}}` — the front-end looks up the registered component by
   `component` and mounts it with `props`. **[proposed — pin the shape here]**

---

## Part 1 — Input widgets (`@bind`) **[built]**

A package defines a typed constructor + `to_widget`; the kind is derived from the type:

```julia
struct Stars; max::Int; label::Union{Nothing,String}; default::Int; end
Stars(; max = 5, label = nothing, default = 0) = Stars(max, label, clamp(default, 0, max))

SlateExtensionsBase.to_widget(s::Stars) = Widget(kind_for(Stars), Dict("max" => s.max), s.default)
#                                          └ kind "StarRating.Stars", namespaced, no hand-typed string
```

**Coercion is type-driven** — the browser value is coerced to the type of `Widget.default` via
`coerce_value`, with error-fallback, so a typed widget needs *no* value-lifecycle code:

```julia
coerce_value(::Type{T}, v) where {T<:Integer} = v isa Number ? round(T, v) : parse(T, strip(string(v)))
# … Float, Bool, String, Symbol; unknown types pass through. A package adds a method for its own type.
```

`register_kind!` is now **optional**, only for refinements:
- `register_kind!("k"; domain = w -> 0:w_max)` — derive clamp + reconcile from a declared domain.
- `register_kind!("k"; coerce=…, reconcile=…, wrap=…)` — fully custom (e.g. a labeled option → `Choice`).

---

## Part 2 — Front-end component authoring **[built]**

The renderer is a **Preact + signals component** in a real `.js` module that just `export default`s —
no kind string, no boot cell:

```js
// assets/stars.js
import { html, useSignal } from "@slate/widget";
export default ({ value, set, params }) => {
  const max = params.max ?? 5;
  const hover = useSignal(0);
  const lit = i => i < (hover.value || value.value);
  return html`<span onMouseLeave=${() => (hover.value = 0)}>
    ${Array.from({ length: max }, (_, i) => html`
      <span onMouseEnter=${() => (hover.value = i + 1)} onClick=${() => set(i + 1)}>
        ${lit(i) ? "★" : "☆"}</span>`)}
  </span>`;
};
```

**The component `ctx`** (what the SDK hands the component):

| field | meaning |
|---|---|
| `value` | a **signal** — the bound value; auto-unwraps in htm/JSX; a server sync sets it (no echo) |
| `set(v)` | commit now (updates `value` + recomputes reader cells) |
| `schedule(v)` | commit throttled/coalesced — for drags / continuous controls |
| `params` | static `@bind` config |
| `call(ch, payload[, onProgress])` → Promise | JS→Julia RPC over the page WebSocket (binary ok) |
| `stream(ch, init)` → signal | Julia `slate_emit(ch, …)` → a live signal, auto-released on unmount |

Signals are the base primitive **because of the extended flows** (RPC/streaming/progress/binary): a
stream *is* a signal, deleting the `useEffect`+cleanup+setter ceremony. For a plain value widget signals
are a wash — but the SDK owns the surface (re-exports `html`/`useSignal`/… from `@slate/widget`, so a
widget never imports bare `preact` → one instance, one pinned version).

**Low-level escape hatch kept:** `window.slateRegisterWidget(kind, {wire, sync, destroy})` for zero-dep /
canvas / self-owned-DOM widgets (a Bonito subtree, WebGL). `registerComponent` is a thin adapter over it.

**Injection:** the manifest carries `{js, esm, kind}`. For a component (`kind` set), Slate wraps the
module — imports its default export from a blob/`data:` URL and calls `registerComponent(kind, C)` — so
the author's JS stays a bare `export default`. Live (blob URL) and static export (`data:` URL), imports
resolved by the page import map.

---

## Part 3 — Rich output (display) **[proposed]**

A value *returned* from a cell renders Slate-rich via the **Slate MIME**, without hijacking `text/html`
(so it still degrades to a plain representation in the REPL/IJulia/VS Code). SEB owns the `show`/
`showable` plumbing; the extension defines one dispatch method:

```julia
# SEB:
const SlateMIME = MIME"application/vnd.kaimonslate+json"
slate_render(x) = nothing                                    # stub → not Slate-renderable
Base.showable(::SlateMIME, x) = slate_render(x) !== nothing  # detection = a method exists
Base.show(io::IO, ::SlateMIME, x) = print(io, _encode(slate_render(x)))

# extension — no MIME string, no IO plumbing:
SlateExtensionsBase.slate_render(s::Stars) =
    component("StarRating.Stars"; value = s.default, max = s.max)   # → {v:1, component:…, props:…}
```

The payload is a **component descriptor** — the SAME `{component, props}` a bound widget mounts. So a
returned widget and a bound widget render through identical front-end machinery (`registerComponent` +
the manifest); the only difference is a bound one has a live `value`. Slate's display capture must prefer
`SlateMIME` (richest) over `text/html`/`text/plain`, with fallback.

---

## Part 4 — Package-global front-end **[proposed]**

Editor extensions (`slateRegisterEditorExtension` — e.g. math highlighting in cells) and JS→Julia RPC
handlers (`giac_src`/`giac_tex`) are **not tied to a widget bind**, so the per-widget hook never fires for
them. They trigger on a *broader* signal — "this package is in use in the notebook" — which Slate already
computes when it resolves the notebook's `using`/`import` modules each drain.

```julia
required_assets(::Module) = nothing                          # SEB stub
# GiacSlate provides its editor extension + RPC handler scripts here (dispatch on the module, or a
# named convention like `GiacSlate.__slate_frontend()` — module singletons are awkward to dispatch on):
```

Slate, resolving the notebook's usings, calls this once per newly-loaded module and registers what comes
back into the same registry the manifest pull reads. **Timing == what `__init__` gave** (fires right after
the `using` cell runs, end of drain), but Slate-driven and lazy — a package the notebook never `using`s
contributes nothing.

Inherent limitation (same as any package-provided front-end): a not-yet-run notebook (inactive/preview)
or a static export has no package loaded, so no editor highlighting until the `using` actually runs.

---

## Part 5 — No `__init__` **[proposed]**

`__init__` is discouraged (precompile/trimming friction; Julia ≥1.11 offers `OncePerProcess` as the
formal replacement) and loads *all* of a package's assets eagerly. The dispatch model removes it:

- **Per-widget assets** load lazily from the `to_widget`/display path: first time Slate sees widget type
  `W` (kind not yet registered), it calls `required_assets(typeof(x))` and registers the returned module.
  A package with 100 widgets injects JS only for the ones a notebook actually uses. The registry dedups by
  id, so `@pkg_asset` reads each file once.
- **Package assets** load lazily from the `using`-resolution path (Part 4).

Where Slate calls each:
- `to_widget` / `required_assets(::Type)` — in `widgets.jl`'s bind path (worker), and the display path.
- `required_assets(::Module)` — in the worker's using-resolution (`refine_usings!` neighbourhood).
- All populate SEB's process-global registry → the **once-per-drain manifest pull** carries them to the
  page. Timing lands within the same drain as the triggering cell.

---

## Transport — the extension manifest **[built]**

Process-level, so it's PULLED, not pushed per-cell:

- Worker: SEB `extension_manifest()` → `(; frontend = [(; id, js, esm, kind)])`; exposed as the
  `__slate_extension_manifest` gate tool. In-process kernel: read directly.
- Hub: `_refresh_extensions!(nb)` merges it into a sticky per-notebook registry `nb.frontend`, **once per
  drain** (same lifecycle as `refine_usings!`, in `_run_loop!`), version-bumping only on change.
- Page: `state_json.frontendScripts` → `view.js injectFrontendScripts` appends each unseen entry once
  (component → wrapped module; esm → module; classic → script). Static export: `_frontend_export_head`
  emits the same, with the Preact/htm/`@slate/widget` importmap inlined when a component is present.

Why pull, not push: a package's front-end is registered at package/widget-load time, often during worker
*priming* (no harvestable cell eval), so the process-global registry is the authoritative source.

---

## Status summary

**Built + COMMITTED** — `feat/widget-interface-pkg` commit **`ac11febf`**, suite 4365 (SEB 106, StarRating
16): type-derived kinds (`kind_for`, `Widget(T,…)`); type-driven coercion (`coerce_value`, optional
`register_kind!` + `domain=`); `auto_widget` struct reflection + NamedTuple `Widget` params; component
authoring (`register_component!(T,js)`, `@pkg_asset`, `slate-widget.js`, `@slate/widget`, blob/`data:`
injection); the manifest transport (worker query → once-per-drain hub merge → page inject + export);
**lazy per-widget assets** (`required_assets(::Type)` + `ensure_widget_assets!` in `_do_bind`, no `__init__`).
StarRating = 3 dispatch methods, no `__init__`, no boot cell, no lifecycle code.

**Live-validated:** the component + type-derived-kind path (blob-URL module import honors the importmap;
click → Julia `Int`; export embeds the module) — but that live pass ran with the *previous* `__init__`/
`register_component!` build. The **lazy `required_assets` swap + `auto_widget` are suite-green but NOT yet
live-validated** — they'll get their live pass when GiacSlate is brought up (needs a restart anyway).

**Remaining, in order:**
1. **GiacSlate conversion** (next — see below). Exercises + live-validates the lazy per-widget path AND
   drives the package-global `required_assets(::Module)` design (its editor ext + RPC handlers).
2. Rich output: `slate_render` + the two frozen MIMEs (`component+json`/`html+html`) + descriptor payload;
   wire display capture to prefer them (priority `showable` scan).
3. Port NeuroSlate; delete its private `slate_context`/`_ctx_field`.
4. `provide_assets!(dir)` (served dirs — Cesium/echarts-gl); remote.jl staleness DRY; register SEB in General.

---

## Handoff — GiacSlate conversion (the next task)

GiacSlate (`/Users/kburke/devel/GiacSlate.jl`, uncommitted in its own repo) is the real test of the model
— it has BOTH a per-widget front-end (the `Mathfield` control) AND package-global front-end that has no
bind to trigger it (the inline-math **editor extension** + the `giac_src`/`giac_tex` **JS→Julia RPC
handlers**). Goal: `using GiacSlate` alone makes `custom_controls` + `laplace_lesson` work — **delete every
boot cell** (`mathfield_boot`/`inline_math_boot`), no compat shims.

Do it in this order:

1. **Port the `Mathfield` widget to the component model** (proven path): a `Mathfield` struct +
   `to_widget`/`auto_widget` (kind `GiacSlate.Mathfield`), a `required_assets(::Type{Mathfield})` returning
   the mathfield component module (rewrite `MathfieldBoot`'s JS as `export default (ctx)=>…` importing
   `@slate/widget`; it likely needs a vendored math-field lib — that's the `provide_assets!` question, may
   need an interim inline). Live-validate the lazy load fires on first `@bind … Mathfield(…)`.
2. **BUILD the package-global hook `required_assets(::Module)`** (Part 4 — currently PROPOSED, not built).
   - SEB: stub `required_assets(::Module) = nothing`; a `ensure_module_assets!(m::Module)` that registers
     what it returns. Decide the dispatch: a **named convention** (`isdefined(m,:__slate_frontend) &&
     m.__slate_frontend()`) is cleaner than dispatching on a module singleton (see Open questions).
   - KaimonSlate: call `ensure_module_assets!` for each notebook `using` module in the worker's
     using-resolution path (`refine_usings!` neighbourhood, `server.jl _run_loop!` / `deps.jl`), so it
     fires once per package per session, end-of-drain. Editor-ext + handler scripts flow through the SAME
     manifest → page inject.
   - **The RPC handlers are the crux**: `giac_src`/`giac_tex` are Julia functions registered into the
     notebook's `__slate_handlers` (see `widgets.jl`/`_populate_notebook_ns!` for `slate_on`/`__slate_call`).
     The package-global hook must register these Julia handlers too (not just push JS). Trace how
     `slate_on(channel) do … end` populates `__slate_handlers` today, and give the module hook a way to add
     them (an SEB `slate_on`-style accessor the hook body calls, or the hook returns handler closures Slate
     installs). This is the old "step 1b `:on` accessor" — now folded into the module hook.
3. **Convert GiacSlate**: `__init__` → the dispatch methods (`to_widget`/`required_assets(::Type)`) + the
   module hook (`__slate_frontend`/`required_assets(::Module)`) for editor-ext JS + giac handlers. DELETE
   `mathfield_boot`, `inline_math_boot`, and the boot cells in the notebooks.
4. **Live-validate**: fresh `custom_controls` + `laplace_lesson` with only `using GiacSlate` — the mathfield
   binds + renders, editing a giac field triggers `giac_src`/`giac_tex` with NO "no handler" error, console
   clean. NOTE laplace_lesson currently errors on giac edit because the user removed `inline_math_boot(slate_on)`
   — that stays broken until this lands (per steer; do NOT re-add the boot line).

GiacSlate depends on SEB via a `[sources]` path to `lib/SlateExtensionsBase` (already set up per the earlier
partial port). After converting, commit GiacSlate in ITS OWN repo.

## Open questions

- Dispatching on a specific module: `required_assets(::typeof(GiacSlate))` vs a named convention
  (`GiacSlate.__slate_frontend()`). Lean named-convention (module singletons dispatch awkwardly).
- `required_assets` return shape: a single JS string, or a small `Asset` descriptor (component vs raw
  script vs css vs vendored dir) to grow into `provide_assets!` (served dirs, Cesium/echarts-gl).
- Component-descriptor payload: exact fields beyond `{v, component, props}` — assets? events? size hints?
- Whether `to_widget` (input) and `slate_render` (output) should share a single `component(...)` builder
  so the descriptor is constructed one way.
</content>
