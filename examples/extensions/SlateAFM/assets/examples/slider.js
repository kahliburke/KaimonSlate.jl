// A second self-contained AFM module: a labelled range slider driving a `value` trait, plus a `label`
// trait it only reads. Shows multiple traits, live commit while dragging, and a read-only trait that
// updates when Julia pushes it. `initialize` returns a cleanup to demonstrate the non-signal path too.
export default {
  initialize({ model, signal }) {
    // (initialize runs once per instance — a place for shared state/exports; here just a teardown log)
    return () => { /* cleanup on abort */ };
  },
  render({ model, el, signal }) {
    const wrap = document.createElement("label");
    wrap.style.cssText = "display:inline-flex;align-items:center;gap:.6em;font:inherit;color:#e2e8f0";
    const name = document.createElement("span");
    const input = document.createElement("input");
    input.type = "range";
    input.min = String(model.get("min") ?? 0);
    input.max = String(model.get("max") ?? 100);
    const out = document.createElement("strong");

    const draw = () => {
      name.textContent = model.get("label") ?? "value";
      input.value = String(model.get("value") ?? 0);
      out.textContent = String(model.get("value") ?? 0);
    };
    input.addEventListener("input", () => {
      model.set("value", Number(input.value));
      model.save_changes();               // live commit while dragging
    }, { signal });
    model.on("change:value", draw);
    model.on("change:label", draw);
    draw();

    wrap.append(name, input, out);
    el.appendChild(wrap);
  },
};
