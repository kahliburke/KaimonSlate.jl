// AFM composition demo (the target). `initialize()` returns an EXPORTS object — an imperative surface
// another widget can drive via `host.getWidget(ref).exports`. `render()` draws a range input on the value.
export default {
  initialize({ model }) {
    return {
      getValue: () => model.get("value"),
      onChange: (cb) => model.on("change:value", cb),
    };
  },
  render({ model, el, signal }) {
    const input = document.createElement("input");
    input.type = "range";
    input.min = String(model.get("min") ?? 0);
    input.max = String(model.get("max") ?? 100);
    input.value = String(model.get("value") ?? 0);
    input.addEventListener("input", () => {
      model.set("value", Number(input.value));
      model.save_changes();
    }, { signal });
    model.on("change:value", () => { input.value = String(model.get("value")); });
    el.appendChild(input);
  },
};
