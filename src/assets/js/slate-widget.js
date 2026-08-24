// The Slate widget SDK — the ONE module a component widget imports (it must NOT import bare `preact`),
// so the whole page shares exactly one Preact/signals instance and we pin versions in one place. Live:
// served here and resolved via the importmap specifier "@slate/widget". Export: inlined as a data: module.
//
// Author a widget as a Preact component:
//   import { registerComponent, html, useSignal } from "@slate/widget";
//   registerComponent("stars", ({ value, set, params }) => html`…`);
//
// A component module may also `export function exportFigure(el, ctx)` — see `registerComponent`
// below. Slate passes the module's whole namespace here, so that opt-in needs no kind string and
// no extra call.
//
// This is a thin, signals-shaped layer over core's low-level `slateRegisterWidget(kind,{wire,sync,destroy})`
// — which stays available for zero-dep / self-owned-DOM widgets (canvas, a Bonito subtree, …).

import { render, h } from "preact";
import { signal, computed, effect, useSignal, useComputed } from "@preact/signals";
import { html } from "htm/preact";

// Re-exported so widgets get their whole toolkit from us (one instance; never a bare `preact` import).
export { html, h, signal, computed, effect, useSignal, useComputed };

// Register widget `kind` as a Preact component. `Component(ctx) => vnode`, where `ctx` is:
//   value       signal — the bound @bind value (read; auto-unwraps in htm/JSX). A server sync sets it.
//   set(v)      commit a value NOW (updates `value` + recomputes reader cells).
//   schedule(v) commit throttled/coalesced — for a drag or a continuous control.
//   params      static @bind config (e.g. { max: 5 }).
//   call(ch, payload[, onProgress]) → Promise   JS→Julia RPC over the page WebSocket (binary ok).
//   stream(ch, init) → signal                   Julia `slate_emit(ch, …)` → a live signal; auto-released on unmount.
//
// `mod` is the component module's namespace, passed by whatever injected it (view.js live,
// `_frontend_export_head` in a frozen page). Its only current use is the optional `exportFigure`
// hook — see below — but taking the namespace rather than one named argument means a later
// module-level opt-in costs nothing at the two injection sites.
export function registerComponent(kind, Component, mod) {
  const impl = {
    wire(el, api) {
      const value = signal(api.value);              // the SDK owns the value signal; sync() writes it
      el._slateValue = value;
      el._slateChannels = [];                        // stream channels to release on destroy
      const ctx = {
        value,
        params: api.params || {},
        set:      v => { value.value = v; api.flush(v); },      // commit now
        schedule: v => { value.value = v; api.schedule(v); },   // commit throttled
        call:  (ch, payload, onProgress) => window.slateCall(String(ch), payload, onProgress),
        stream: (ch, init) => _stream(el, ch, init),
      };
      render(h(Component, ctx), el);
    },
    // A value pushed from elsewhere (a re-run, another control) → set the signal. NOT a commit, so it
    // can't echo back to the server.
    sync(el, v) { if (el._slateValue) el._slateValue.value = v; },
    destroy(el) {
      render(null, el);                              // unmount the component (runs cleanup effects)
      (el._slateChannels || []).forEach(ch => { if (window.__slateStream) delete window.__slateStream[ch]; });
      el._slateChannels = [];
    },
  };
  // PRINT rendering, opt-in. A PDF export captures each mounted component as a figure; by default it
  // serialises whatever the mount already holds (see `_slateComponentFig`, inspect.js). Export a
  //
  //   export async function exportFigure(el, ctx) → { svg } | { png } | null
  //
  // to render for print instead: `el` is the live mount, `ctx` is `{ params, kind, theme, vars, dark }`
  // — `theme` the Slate palette name the export asked for, `vars` its CSS custom properties, `dark`
  // whether that palette's page colour is dark. Return SVG (Typst embeds it as vector) or a base64 PNG.
  // Worth defining whenever the on-screen render uses something print can't carry: `<foreignObject>`,
  // a canvas, `font-family: inherit`, or colours taken from the LIVE theme rather than `ctx`.
  if (mod && typeof mod.exportFigure === "function") impl.exportFigure = mod.exportFigure;
  window.slateRegisterWidget(String(kind), impl);
}

// A Julia→JS stream as a signal: `slate_emit(channel, v)` sets `s.value = v`. One handler per channel
// (core's model); released in the component's `destroy`.
function _stream(el, channel, init) {
  const s = signal(init);
  const ch = String(channel);
  window.slateOnStream(ch, v => { s.value = v; });
  el._slateChannels.push(ch);
  return s;
}
