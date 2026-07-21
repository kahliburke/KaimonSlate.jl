"""
    StarRating

A sample Slate extension: a typed `@bind` star-rating control, built entirely against the lean
`SlateExtensionsBase` SDK (no KaimonSlate dependency). Use it in a Slate notebook:

```julia
using StarRating
stars_boot()                       # once, in a cell above — registers the front-end renderer
@bind rating Stars(; max = 5, label = "How good?")
rating                             # an Int 0…max, reactive like any @bind
```

Demonstrates the three SDK extension seams:
- [`Stars`](@ref) + `to_widget` — a typed constructor with its own docstring/dispatch.
- `register_kind!` — the value lifecycle (clamp the browser value; keep it across a re-run).
- [`stars_boot`](@ref) + `register_widget_js` — the front-end `slateRegisterWidget` renderer.
"""
module StarRating

using SlateExtensionsBase

export Stars, stars_boot

"""
    Stars(; max = 5, label = nothing, default = 0)

A star-rating `@bind` control that binds an `Int` in `0:max`. `label` names it in the UI.
"""
struct Stars
    max::Int
    label::Union{Nothing,String}
    default::Int
end
Stars(; max::Int = 5, label = nothing, default::Int = 0) =
    Stars(max, label === nothing ? nothing : String(label), clamp(default, 0, max))

# The `to_widget` seam: turn a `Stars` into the wire `Widget` of kind "stars". `@bind name Stars(…)`
# calls this, so the notebook author writes a typed constructor instead of `custom_widget("stars")`.
function SlateExtensionsBase.to_widget(s::Stars)
    p = Dict{String,Any}("max" => s.max)
    s.label === nothing || (p["label"] = s.label)
    return Widget("stars", p, s.default)
end

# The "stars" value lifecycle, registered through the SAME seam a built-in widget uses. `coerce`
# clamps the browser's number into 0:max; `reconcile` keeps the rating across a bind-cell re-run
# while it still fits (else the new default). Registered at package load, into whichever process runs
# the kernel (the worker for a real notebook, the engine in-process) — idempotent if loaded twice.
_starmax(w) = Int(get(w.params, "max", 5))
function __init__()
    register_kind!("stars";
        coerce = (w, v) -> clamp(v isa Number ? round(Int, v) : 0, 0, _starmax(w)),
        reconcile = (ow, ov, nw) -> (ov isa Integer && 0 <= ov <= _starmax(nw)) ? ov : nw.default)
    return nothing
end

# The front-end renderer. `register_widget_js` wraps this in a WebPage whose `<script>` calls
# `window.slateRegisterWidget("stars", …)` — return `stars_boot()` from a cell above any `@bind`.
const _STARS_JS = raw"""
window.slateRegisterWidget("stars", {
  wire(el, api) {
    const max = (api.params && api.params.max) || 5;
    el.style.cssText = "display:inline-flex;gap:2px;font-size:1.4rem;cursor:pointer;user-select:none";
    const paint = (upto) => [...el.children].forEach((s, i) =>
      s.textContent = i < (upto ?? el._v ?? 0) ? "★" : "☆");   // el._v is the single source of truth
    for (let i = 1; i <= max; i++) {
      const s = document.createElement("span");
      s.onmouseenter = () => paint(i);                          // preview on hover
      s.onclick = () => { el._v = i; api.flush(i); paint(); };  // commit → recompute readers
      el.appendChild(s);
    }
    el.onmouseleave = () => paint();
    el._v = api.value ?? 0;
    paint();
  },
  sync(el, value) {                                             // a value pushed from elsewhere (re-run, another control)
    el._v = value;
    [...el.children].forEach((s, i) => s.textContent = i < (value ?? 0) ? "★" : "☆");
  },
  destroy(el) { el.innerHTML = ""; },
});
"""

"""
    stars_boot()

One-time front-end registration for the `stars` widget kind — return it from a cell above any
`@bind … Stars(…)` (it renders as a `<script>` calling `window.slateRegisterWidget`).
"""
stars_boot() = register_widget_js("stars", _STARS_JS)

end # module
