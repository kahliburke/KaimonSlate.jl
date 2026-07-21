// The Slate widget SDK — the ONE module a component widget imports (it must NOT import bare `preact`),
// so the whole page shares exactly one Preact/signals instance and we pin versions in one place. Live:
// served here and resolved via the importmap specifier "@slate/widget". Export: inlined as a data: module.
//
// Author a widget as a Preact component:
//   import { registerComponent, html, useSignal } from "@slate/widget";
//   registerComponent("stars", ({ value, set, params }) => html`…`);
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
export function registerComponent(kind, Component) {
  window.slateRegisterWidget(String(kind), {
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
  });
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
