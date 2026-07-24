// A Julia-DRIVEN wrapper around the real PDBe Mol* engine. It hosts an actual pdbe-molstar viewer and
// loads whatever structure Julia streams over the binary `msg:custom` channel — so Julia's code builds a
// molecule and the real molecular engine renders it, live, with no sticky-bind trait round-trip.
// Messages (via afm_emit): {op:"load", pdb:"<PDB text>"} → (re)load that structure; {op:"spin", on:bool}.
import "https://cdn.jsdelivr.net/npm/pdbe-molstar@3.3.2/build/pdbe-molstar-plugin.js";

export default {
  render({ model, el, signal }) {
    const H = model.get("height") || 440;
    el.innerHTML = "";
    const box = document.createElement("div");
    box.style.cssText = "position:relative;width:100%;height:" + H + "px;border:1px solid #1e293b;" +
      "border-radius:8px;overflow:hidden";
    el.appendChild(box);

    // If the container gets its real width only AFTER Mol* initialized (0-width at init), tell the engine
    // to re-measure so the baked 0×0 canvas grows to fit.
    let lastW = 0;
    const ro = new ResizeObserver((entries) => {
      const w = entries[0]?.contentRect?.width || 0;
      if (w > 0 && w !== lastW) { lastW = w;
        try { viewer.plugin?.canvas3d?.handleResize?.(); } catch (e) {} }
    });
    ro.observe(box);

    // A small status line over the viewer, so the load path is visible without digging in the console.
    const status = document.createElement("div");
    status.style.cssText = "position:absolute;left:8px;top:8px;z-index:10;font:12px/1.4 ui-monospace,monospace;" +
      "color:#93c5fd;background:rgba(6,9,16,.72);padding:3px 7px;border-radius:5px;pointer-events:none";
    box.appendChild(status);
    const say = (msg, err) => { status.textContent = msg; status.style.color = err ? "#fca5a5" : "#93c5fd";
      (err ? console.error : console.log)("molstar_live:", msg); };
    say("waiting for a structure…");

    const viewer = new window.PDBeMolstarPlugin();

    // pdbe-molstar's customData fetches by URL (there is no inline `data` field — this is exactly what the
    // ipymolstar widget does), so wrap the streamed PDB text in a blob URL. Keep the current URL so we can
    // revoke it when a new structure arrives.
    let curUrl = null;
    const urlFor = (pdb) => {
      if (curUrl) { URL.revokeObjectURL(curUrl); curUrl = null; }
      curUrl = URL.createObjectURL(new Blob([pdb], { type: "text/plain" }));
      return curUrl;
    };
    const opts = (pdb) => ({
      customData: { url: urlFor(pdb), format: "pdb", binary: false },
      bgColor: { r: 6, g: 9, b: 16 },
      hideControls: true,
      hideCanvasControls: ["selection", "animation", "controlToggle", "controlInfo"],
      landscape: true, sequencePanel: false, pdbeLink: false,
      // A custom PDB has no cartoon-able polymer chain molstar recognises, so the default preset can render
      // an empty scene. Ask for an explicit all-atom ball-and-stick style so the backbone/rungs are drawn.
      visualStyle: "ball-and-stick",
    });

    // loadComplete fires once the structure is in the scene — the reliable "it worked" signal (mirrors the
    // ipymolstar widget's events.loadComplete.subscribe). Log an atom count if the API exposes one.
    let subscribed = false;
    const watchLoad = () => {
      if (subscribed) return; subscribed = true;
      try {
        viewer.events?.loadComplete?.subscribe?.((ok) => {
          if (ok === false) { say("load failed (see console)", true); return; }
          let n = null;
          try { n = viewer.plugin?.managers?.structure?.hierarchy?.current?.structures?.length ?? null; } catch (e) {}
          say(n ? ("loaded ✓ (" + n + " structure" + (n > 1 ? "s" : "") + ")") : "loaded ✓");
        });
      } catch (e) { console.warn("molstar_live: no loadComplete event", e); }
    };

    // Render lazily: the engine requires a data source at render time, so don't call render() until a
    // structure exists. The first load renders; later loads reuse visual.update — the same call the native
    // widget uses for change:custom_data.
    let ready = null;
    async function load(pdb) {
      if (!pdb) return;
      say("loading structure…");
      try {
        if (!ready) { ready = viewer.render(box, opts(pdb)); await ready; watchLoad(); }
        else { await ready; await viewer.visual.update(opts(pdb), true); }
      } catch (e) { say("error: " + (e && e.message || e), true); console.error("molstar_live load", e); }
    }

    // An initial structure may ride along on the bind.
    const initial = model.get("pdb");
    if (initial) load(initial);

    model.on("msg:custom", (content) => {
      if (!content) return;
      if (content.op === "load" && content.pdb) load(content.pdb);
      else if (content.op === "spin" && ready) { ready.then(() => { try { viewer.visual.toggleSpin(!!content.on); } catch (e) {} }); }
    });

    signal.addEventListener("abort", () => {
      try { ro.disconnect(); } catch (e) {}
      try { viewer.visual && viewer.visual.dispose && viewer.visual.dispose(); } catch (e) {}
      if (curUrl) { URL.revokeObjectURL(curUrl); curUrl = null; }
    });
  },
};
