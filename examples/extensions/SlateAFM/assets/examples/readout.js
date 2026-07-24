// AFM composition demo (the composer). Resolves ANOTHER mounted widget by ref via `host.getWidget`, uses
// its `exports` (getValue/onChange), and renders a second live view of it inline. The `control` trait
// holds the target widget's id.
export default {
  async render({ model, el, signal, host }) {
    const wrap = document.createElement("div");
    wrap.style.cssText = "display:flex;align-items:center;gap:.8em;font:inherit;color:#e2e8f0";
    const slot = document.createElement("span");
    const out = document.createElement("strong");
    wrap.append(slot, out);
    el.appendChild(wrap);

    const w = await host.getWidget(model.get("control"));  // waits for the target's initialize
    const draw = () => { out.textContent = "value = " + w.exports.getValue(); };
    w.exports.onChange(draw);
    await w.render({ el: slot, signal });                  // a second live view of the same control
    draw();
  },
};
