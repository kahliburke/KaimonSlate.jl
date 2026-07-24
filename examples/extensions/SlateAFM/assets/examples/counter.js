// The canonical Anywidget counter, verbatim in spirit — a self-contained AFM module (no imports). Proves
// the AFM contract works under SlateAFM: model.get/set/save_changes, on("change:count"), and AbortSignal
// cleanup (the click listener is bound with { signal }, so it's removed when the widget tears down).
export default {
  render({ model, el, signal }) {
    const btn = document.createElement("button");
    btn.style.cssText =
      "font:inherit;padding:.45em .9em;border-radius:8px;border:1px solid #4a5568;" +
      "background:#2d3748;color:#e2e8f0;cursor:pointer";
    const draw = () => { btn.textContent = `count is ${model.get("count") ?? 0}`; };
    btn.addEventListener("click", () => {
      model.set("count", (model.get("count") || 0) + 1);
      model.save_changes();               // commit → the bound Julia value updates, reader cells re-run
    }, { signal });
    model.on("change:count", draw);        // Julia pushed a new count (re-run / set_bind) → redraw
    draw();
    el.appendChild(btn);
  },
};
