// StarRating's front-end — a Slate widget component. Shipped as a real ES module (no build step) and
// registered from the package's __init__ via `register_component!(Stars, @pkg_asset("assets/stars.js"))`.
// The module just default-exports the component; Slate registers it under the type-derived kind
// ("StarRating.Stars"), so there's no kind string here to keep in sync or collide with another package.
// The notebook only does `using StarRating`; this file is injected into the page automatically.
import { html, useSignal } from "@slate/widget";

export default ({ value, set, params }) => {
  const max = params.max ?? 5;
  const hover = useSignal(0);
  const lit = i => i < (hover.value || value.value);   // hovered count previews; else the committed value
  return html`
    <span style="display:inline-flex;gap:2px;cursor:pointer;font-size:1.4rem"
          onMouseLeave=${() => (hover.value = 0)}>
      ${Array.from({ length: max }, (_, i) => html`
        <span onMouseEnter=${() => (hover.value = i + 1)} onClick=${() => set(i + 1)}>
          ${lit(i) ? "★" : "☆"}
        </span>`)}
    </span>`;
};
