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
    // ipymolstar widget does), so wrap the streamed PDB text in a blob URL. The blob must outlive the
    // load's ASYNC trajectory parse — revoking it the instant the next frame arrives yields "Invalid data
    // cell" mid-parse — so `revokeStale()` frees old blobs only AFTER a newer load has fully settled,
    // always keeping the just-loaded one alive.
    let liveUrls = [];
    const makeUrl = (pdb) => { const u = URL.createObjectURL(new Blob([pdb], { type: "text/plain" }));
      liveUrls.push(u); return u; };
    const revokeStale = (keep) => { const stale = liveUrls.filter((u) => u !== keep);
      liveUrls = keep ? [keep] : []; stale.forEach((u) => { try { URL.revokeObjectURL(u); } catch (e) {} }); };
    const opts = (url) => ({
      customData: { url: url, format: "pdb", binary: false },
      bgColor: { r: 6, g: 9, b: 16 },
      hideControls: true,
      hideCanvasControls: ["selection", "animation", "controlToggle", "controlInfo"],
      landscape: true, sequencePanel: false, pdbeLink: false,
      // A custom PDB has no cartoon-able polymer chain molstar recognises, so the default preset can render
      // an empty scene. Ask for an explicit all-atom ball-and-stick style so the backbone/rungs are drawn.
      visualStyle: "ball-and-stick",
    });

    const pause = (ms) => new Promise((res) => setTimeout(res, ms));
    // loadComplete fires when a structure lands in the scene — but empirically ONLY on the initial
    // `render()`, not on a later `visual.update()`. So use it for the first frame's status + settle, and
    // fall back to a fixed short gap after each update: both render() and update() resolve BEFORE molstar's
    // async trajectory parse finishes, so firing the next frame immediately corrupts the in-flight parse
    // (→ "Invalid data cell"). A ~350ms gap lets a small structure fully parse; the stream still grows
    // visibly (latest-wins coalesces anything that piles up during the gap).
    const SETTLE_MS = 350;
    let subscribed = false, firstResolve = null;
    const watchLoad = () => {
      if (subscribed) return; subscribed = true;
      try {
        viewer.events?.loadComplete?.subscribe?.((ok) => {
          if (ok === false) say("load failed (see console)", true);
          const r = firstResolve; firstResolve = null; if (r) r(ok !== false);
        });
      } catch (e) { console.warn("molstar_live: no loadComplete event", e); }
    };
    const sayLoaded = () => {
      let n = null;
      try { n = viewer.plugin?.managers?.structure?.hierarchy?.current?.structures?.length ?? null; } catch (e) {}
      say(n ? ("loaded ✓ (" + n + " structure" + (n > 1 ? "s" : "") + ")") : "loaded ✓");
    };

    // Render lazily: the engine requires a data source at render time, so don't call render() until a
    // structure exists. The first load renders (subscribing to loadComplete first); later loads reuse
    // visual.update — the same call the native widget uses for change:custom_data.
    // Serialize with latest-wins + a settle gap: while one load is settling, a burst of stream frames just
    // updates `pending`; each iteration processes the newest and pauses before the next, so molstar fully
    // digests each frame (no parse collision) while the structure still visibly grows.
    let ready = null, inflight = false, pending = null;
    async function load(pdb) {
      if (!pdb) return;
      pending = pdb;
      if (inflight) return;
      inflight = true;
      try {
        while (pending != null) {
          const p = pending; pending = null;
          say("loading structure…");
          const url = makeUrl(p);
          if (!ready) {
            const first = new Promise((res) => { firstResolve = res; setTimeout(() => { if (firstResolve === res) { firstResolve = null; res(false); } }, 4000); });
            ready = viewer.render(box, opts(url)); watchLoad(); await ready;
            await first;              // loadComplete fires on render — wait for the real settle
          } else {
            await viewer.visual.update(opts(url), true);
            await pause(SETTLE_MS);   // update() has no completion event — a short gap lets the parse finish
          }
          revokeStale(url);   // now safe to free earlier blobs, keeping this one for the live scene
        }
        sayLoaded();   // stream drained — settle the status from the live scene
      } catch (e) { say("error: " + (e && e.message || e), true); console.error("molstar_live load", e); }
      finally { inflight = false; }
    }

    // An initial structure may ride along on the bind.
    const initial = model.get("pdb");
    if (initial) load(initial);

    model.on("msg:custom", (content) => {
      if (!content) return;
      if (content.op === "load" && content.pdb) load(content.pdb);
      else if (content.op === "spin" && ready) { ready.then(() => { try { viewer.visual.toggleSpin(!!content.on); } catch (e) {} }); }
    });

    // React to a live `height` change (a re-bind syncs the trait without remounting) — resize the box and
    // let the engine re-measure, so the viewer honors an updated height without a full reload.
    model.on("change:height", () => {
      box.style.height = (model.get("height") || 440) + "px";
      try { viewer.plugin?.canvas3d?.handleResize?.(); } catch (e) {}
    });

    signal.addEventListener("abort", () => {
      try { ro.disconnect(); } catch (e) {}
      try { viewer.visual && viewer.visual.dispose && viewer.visual.dispose(); } catch (e) {}
      revokeStale(null);   // free every outstanding blob
    });
  },
};
