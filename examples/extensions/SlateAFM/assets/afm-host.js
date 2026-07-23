// SlateAFM host shim — implements the Anywidget Front-End Module (AFM) contract on top of Slate's
// low-level widget API (`slateRegisterWidget(kind, { wire, sync, destroy })`). It's a self-registering
// CLASSIC script (injected once per page via `register_widget!`): it registers the `SlateAFM.AFM` kind,
// and for each bound instance loads an AFM ES module (`params.src`), hands it an AnyModel over the bound
// value, and drives `initialize()` / `render({ el })` with an `AbortSignal`.
(function () {
  "use strict";

  // An AFM `AnyModel` over Slate's `wire` api. Slate binds ONE value; we treat it as the widget's TRAIT
  // DICT (a scalar is wrapped as `{ value }`). Local `set`s are staged until `save_changes()` commits the
  // whole dict back to Julia (reactive to reader cells). A value pushed from Julia (`sync`) diffs the dict
  // and fires `change:<key>`. `send`/`on("msg:custom")` carry out-of-band messages over Slate's channels.
  function makeModel(api, msgSend) {
    var isObj = api.value && typeof api.value === "object" && !Array.isArray(api.value);
    var traits = isObj ? Object.assign({}, api.value) : { value: api.value };
    var changeCbs = Object.create(null);   // key -> [cb]
    var anyCbs = [];                        // "change" (any key)
    var msgCbs = [];                        // "msg:custom"
    var commit = api.flush || api.push;     // commit-now (both are the same wire fn)

    function fire(key) {
      (changeCbs[key] || []).slice().forEach(function (cb) { cb(); });
      anyCbs.slice().forEach(function (cb) { cb(); });
    }
    function drop(arr, cb) { var i = arr.indexOf(cb); if (i >= 0) arr.splice(i, 1); }

    return {
      get: function (k) { return traits[k]; },
      // Backbone/anywidget semantics: setting a value fires `change:<key>` SYNCHRONOUSLY (this is what
      // redraws a widget on its own input, before any backend round-trip). `save_changes()` then commits.
      set: function (k, v) {
        if (JSON.stringify(traits[k]) === JSON.stringify(v)) { traits[k] = v; return; }
        traits[k] = v;
        fire(k);
      },
      save_changes: function () { commit(Object.assign({}, traits)); },
      on: function (ev, cb) {
        if (ev === "msg:custom") msgCbs.push(cb);
        else if (ev === "change") anyCbs.push(cb);
        else if (typeof ev === "string" && ev.lastIndexOf("change:", 0) === 0) {
          var k = ev.slice(7); (changeCbs[k] || (changeCbs[k] = [])).push(cb);
        }
      },
      off: function (ev, cb) {
        if (!ev) { changeCbs = Object.create(null); anyCbs = []; msgCbs = []; return; }
        if (ev === "msg:custom") { cb ? drop(msgCbs, cb) : (msgCbs = []); }
        else if (ev === "change") { cb ? drop(anyCbs, cb) : (anyCbs = []); }
        else if (ev.lastIndexOf("change:", 0) === 0) {
          var k = ev.slice(7); if (changeCbs[k]) { cb ? drop(changeCbs[k], cb) : (changeCbs[k] = []); }
        }
      },
      send: function (content, callbacks, buffers) { msgSend(content, buffers); },

      // ── host-internal hooks (not part of the widget-facing AnyModel) ──
      _external: function (v) {   // a value pushed from Julia (a re-run / set_bind) → diff + fire changes
        var next = (v && typeof v === "object" && !Array.isArray(v)) ? v : { value: v };
        Object.keys(next).forEach(function (k) {
          if (JSON.stringify(traits[k]) !== JSON.stringify(next[k])) { traits[k] = next[k]; fire(k); }
        });
      },
      _recv: function (content, buffers) { msgCbs.slice().forEach(function (cb) { cb(content, buffers || []); }); },
    };
  }

  // Inject one or more stylesheet URLs into the page head, once each (anywidget modules often assume their
  // CSS is loaded by the host — e.g. pdbe-molstar). Deduped page-wide by href.
  function ensureCss(urls) {
    if (!urls) return;
    var seen = window.__slateAFMcss || (window.__slateAFMcss = {});
    [].concat(urls).forEach(function (u) {
      u = String(u);
      if (seen[u]) return;
      seen[u] = true;
      var link = document.createElement("link");
      link.rel = "stylesheet";
      link.href = u;
      document.head.appendChild(link);
    });
  }

  window.slateRegisterWidget("SlateAFM.AFM", {
    wire: function (el, api) {
      var controller = new AbortController();
      var signal = controller.signal;
      var params = api.params || {};
      ensureCss(params.css);
      var msgCh = "SlateAFM.msg:" + (params.id || api.bindId || "");
      var model = makeModel(api, function (content /*, buffers */) {
        // JS → Julia custom message. (Binary buffers are a follow-up — SlateBinary transport exists.)
        try { window.slateCall("SlateAFM.msg", { ch: msgCh, content: content }); } catch (e) {}
      });
      // A mounted-instance record so OTHER widgets can compose with this one (AFM host.getWidget/getModel).
      // Keyed by the widget's `id` (afm(src; id="…")) in a page-global registry.
      var instId = String(params.id || api.bindId || "");
      var readyResolve;
      var record = { model: model, widget: null, exports: undefined,
                     ready: new Promise(function (res) { readyResolve = res; }) };  // resolves after initialize
      var state = { controller: controller, model: model, cleanups: [], msgCh: msgCh, id: instId, record: record };
      el._afm = state;
      if (instId) { (window.__slateAFM || (window.__slateAFM = {}))[instId] = record; }

      // Julia → JS custom messages: slate_emit(msgCh, {content}) → model "msg:custom" listeners.
      try { window.slateOnStream(msgCh, function (m) { model._recv(m && m.content, m && m.buffers); }); } catch (e) {}

      var src = params.src;
      if (!src) { el.innerHTML = '<pre class="afm-err">SlateAFM: widget has no module `src`</pre>'; return; }

      // AFM host surface: resolve another mounted AFM instance by ref. A ref is the widget's `id` (with or
      // without the "anywidget:" prefix, for compatibility with the spec's ref format).
      function refId(ref) { ref = String(ref); return ref.lastIndexOf("anywidget:", 0) === 0 ? ref.slice(10) : ref; }
      function lookup(ref) { return (window.__slateAFM || {})[refId(ref)]; }
      var host = {
        getWidget: function (ref) {
          var rec = lookup(ref);
          if (!rec) return Promise.reject(new Error("SlateAFM: no widget for ref '" + ref + "'"));
          return rec.ready.then(function () {   // wait until the target's initialize has completed
            return {
              exports: rec.exports,
              render: function (opts) {
                opts = opts || {};
                return Promise.resolve(rec.widget && rec.widget.render &&
                  rec.widget.render({ model: rec.model, el: opts.el, signal: opts.signal, host: host }));
              },
            };
          });
        },
        getModel: function (ref) {
          var rec = lookup(ref);
          return rec ? Promise.resolve(rec.model)
                     : Promise.reject(new Error("SlateAFM: no model for ref '" + ref + "'"));
        },
      };

      // Load the AFM module and run its lifecycle. Every export shape is accepted; hooks MAY be async and
      // are awaited; a returned FUNCTION is a cleanup callback; an OBJECT returned from initialize is the
      // widget's EXPORTS (surfaced via host.getWidget().exports).
      Promise.resolve()
        .then(function () { return import(/* webpackIgnore: true */ src); })
        .then(function (mod) {
          var def = mod && mod.default;
          if (def == null && mod && (mod.render || mod.initialize)) {
            def = { initialize: mod.initialize, render: mod.render };
          }
          return (typeof def === "function") ? def() : def;
        })
        .then(function (widget) {
          if (!widget) throw new Error("AFM module exports no default (or render/initialize)");
          record.widget = widget;
          if (signal.aborted) return;
          return Promise.resolve(widget.initialize && widget.initialize({ model: model, signal: signal }))
            .then(function (r) {
              if (typeof r === "function") state.cleanups.push(r);
              else if (r && typeof r === "object") record.exports = r;   // initialize() exports
              readyResolve();                                            // composition may now read exports
            })
            .then(function () {
              if (signal.aborted || !widget.render) return;
              return Promise.resolve(widget.render({ model: model, el: el, signal: signal, host: host }))
                .then(function (r) { if (typeof r === "function") state.cleanups.push(r); });
            });
        })
        .catch(function (e) {
          console.error("SlateAFM load error", e);
          el.innerHTML = '<pre class="afm-err" style="color:#f88;white-space:pre-wrap;margin:0">' +
            "SlateAFM load error: " + (e && e.message ? e.message : e) + "</pre>";
          readyResolve();                             // don't hang a composer waiting on a failed widget
          try { controller.abort(); } catch (x) {}   // AFM: a failed hook aborts the signal (runs cleanup)
        });
    },

    // A value pushed from elsewhere (a re-run, another control) → diff into the model + fire change events.
    sync: function (el, v) { if (el._afm) el._afm.model._external(v); },

    destroy: function (el) {
      var s = el._afm; if (!s) return;
      s.cleanups.forEach(function (fn) { try { fn(); } catch (e) {} });
      try { s.controller.abort(); } catch (e) {}
      if (s.msgCh && window.__slateStream) delete window.__slateStream[s.msgCh];
      if (s.id && window.__slateAFM) delete window.__slateAFM[s.id];
      el._afm = null;
      el.innerHTML = "";
    },
  });
})();
