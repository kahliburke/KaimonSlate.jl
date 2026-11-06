/* `<slate-cell bundle="<name>" cell="<cell id>">` — one rendered Slate cell on a docs page.
   (`src="<bundle dir URL>"` in place of `bundle=` names a bundle anywhere.)

   Concatenated into runtime/slate-embed.js after the static export's runtime (see
   `_embed_runtime_js`), inside the same closure, so `_slateMountCharts`, `_slateWireReplay`,
   `_SLATE_EMBED_CSS` and the rest are in scope here.

   Each cell draws into its own shadow root: the docs theme's CSS cannot reach in, the export CSS
   cannot leak out, and a framework hydrating the page (VitePress) never touches what is inside. A cell
   re-renders on every connect, so a client-side navigation that rebuilds the page just works.

   Cells of one notebook share state across their roots: `@replay` controls in one cell drive figures
   in another. That wiring is redone, per notebook, whenever the set of mounted cells changes. */

var BUNDLES = {};                       // bundle base URL → state

/* Where `<slate-cell bundle="name">` looks for bundles: the directory above the one this script was
   loaded from. A docs build installs the runtime at `<site>/slate/runtime/slate-embed.js` and each
   bundle at `<site>/slate/<name>/`, so a cell resolves its bundle the same way on every page, at any
   depth, under any base path. `window.SlateEmbed.root` overrides it. */
var SCRIPT_URL = (document.currentScript && document.currentScript.src) || "";
function bundleRoot() {
  var o = window.SlateEmbed && window.SlateEmbed.root;
  if (o) return absBase(o);
  return SCRIPT_URL ? new URL("../", SCRIPT_URL).href : absBase("slate/");
}
var LOADED = {};                        // library / stylesheet URL → promise

function absBase(src) {
  var u = new URL(src, document.baseURI).href;
  return u.charAt(u.length - 1) === "/" ? u : u + "/";
}

function getJSON(url) {
  return fetch(url).then(function (r) {
    if (!r.ok) throw new Error(url + " → HTTP " + r.status);
    return r.json();
  });
}

/* Load a UMD library (ECharts, KaTeX) as a global. On a page running an AMD loader — Documenter's
   HTML pages run RequireJS — a UMD bundle that sees `define.amd` registers itself as an anonymous AMD
   module instead of setting its global, and RequireJS rejects it as a mismatched define. There the
   library is fetched and evaluated with `define`/`module`/`exports` shadowed, which leaves the page's
   loader untouched (hiding `window.define` instead races with the page's own module loads). Anywhere
   else it is an ordinary script tag. */
function loadScript(url) {
  if (LOADED[url]) return LOADED[url];
  if (window.define && window.define.amd) {
    return (LOADED[url] = fetch(url).then(function (r) {
      if (!r.ok) throw new Error("could not load " + url + " (HTTP " + r.status + ")");
      return r.text();
    }).then(function (text) {
      (new Function("define", "module", "exports", text + "\n//# sourceURL=" + url))(undefined, undefined, undefined);
    }));
  }
  return (LOADED[url] = new Promise(function (res, rej) {
    var s = document.createElement("script");
    s.src = url; s.async = false;
    s.onload = function () { res(); };
    s.onerror = function () { rej(new Error("could not load " + url)); };
    document.head.appendChild(s);
  }));
}

function loadDocumentCss(url) {
  if (LOADED[url]) return;
  LOADED[url] = true;
  var l = document.createElement("link");
  l.rel = "stylesheet"; l.href = url;
  document.head.appendChild(l);
}

/* ── theme ─────────────────────────────────────────────────────────────────────────────────── */

/* Which theme the host site is showing. VitePress marks dark with `html.dark`; Documenter with a
   `theme--documenter-dark` or dark catppuccin class; MaterialDocs (and many others) with
   `data-theme` on <html>. A page that says nothing follows the OS, which is also what MaterialDocs
   means by an absent `data-theme`. A cell (or `window.SlateEmbed.theme`) can pin "light" or "dark". */
function siteTheme(el) {
  var pin = (el && el.getAttribute("theme")) || (window.SlateEmbed && window.SlateEmbed.theme) || "auto";
  if (pin === "light" || pin === "dark") return pin;
  var html = document.documentElement, cl = html.classList;
  var dt = (html.getAttribute("data-theme") || "").toLowerCase();
  if (dt === "dark" || dt === "light") return dt;
  if (cl.contains("dark") || cl.contains("theme--documenter-dark")) return "dark";
  for (var i = 0; i < cl.length; i++)
    if (/^theme--catppuccin-(frappe|macchiato|mocha)$/.test(cl[i])) return "dark";
  var vitepress = !!document.getElementById("VPContent") || !!document.querySelector(".VPDoc");
  var documenter = !!document.getElementById("documenter");
  if (vitepress || documenter) return "light";
  return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

var SHEET = null;
function componentSheet() {
  if (!SHEET && typeof CSSStyleSheet === "function" && "replaceSync" in CSSStyleSheet.prototype) {
    SHEET = new CSSStyleSheet();
    SHEET.replaceSync(_SLATE_EMBED_CSS);
  }
  return SHEET;
}

function themeCss(man) {
  var t = man.theme || {};
  return ":host{" + ((t.light || {}).vars || "") + "}" +
         ":host([data-theme=dark]){" + ((t.dark || {}).vars || "") + "}";
}

/* ── bundles ───────────────────────────────────────────────────────────────────────────────── */

/* `x` with every relative URL the export wrote (page-local siblings) pointed at the bundle. */
function rebaseValue(x, base) {
  if (typeof x === "string") {
    if (/^(\.\/)?(ext-assets|assets\/maps|data|imports)\//.test(x)) return base + x.replace(/^\.\//, "");
    return x;
  }
  if (Array.isArray(x)) return x.map(function (v) { return rebaseValue(v, base); });
  if (x && typeof x === "object") {
    var o = {};
    for (var k in x) if (Object.prototype.hasOwnProperty.call(x, k)) o[k] = rebaseValue(x[k], base);
    return o;
  }
  return x;
}

function rebaseDom(root, base) {
  var attrs = ["src", "href", "poster"];
  Array.prototype.forEach.call(root.querySelectorAll("[src],[href],[poster]"), function (el) {
    attrs.forEach(function (a) {
      var v = el.getAttribute(a);
      if (v && !/^([a-z][a-z0-9+.-]*:|\/|#)/i.test(v)) el.setAttribute(a, new URL(v, base).href);
    });
  });
}

function loadFrontends(b) {
  var p = Promise.resolve();
  (b.man.frontend || []).forEach(function (fe) {
    var key = "fe:" + fe.id;
    if (LOADED[key]) return;
    LOADED[key] = true;
    if (fe.kind) {
      /* A component module imports the widget SDK and Preact by bare specifier, which needs an import
         map this page does not have. */
      console.warn("slate-cell: component widget '" + fe.kind + "' is not supported in docs yet");
      return;
    }
    p = p.then(function () {
      return fetch(b.base + fe.file).then(function (r) { return r.text(); }).then(function (js) {
        var s = document.createElement("script");
        if (fe.esm) s.type = "module";
        s.setAttribute("data-slate-fe", fe.id);
        s.textContent = js.split(_SLATE_BASE_TOKEN).join(b.base);
        document.head.appendChild(s);
      });
    }).catch(function (e) { console.error("slate-cell: front-end " + fe.id, e); });
  });
  return p;
}

function bundle(src) {
  var base = absBase(src);
  var b = BUNDLES[base];
  if (b) return b.ready;
  b = BUNDLES[base] = { base: base, man: null, cells: [], gen: 0, sheet: null, timer: 0 };
  b.ready = getJSON(base + "slate-bundle.json").then(function (man) {
    b.man = man;
    b.byId = {};
    (man.cells || []).forEach(function (c) { b.byId[c.id] = c; });
    var assets = man.assets || {};
    Object.keys(assets).forEach(function (p) {
      var e = Object.assign({}, assets[p]);
      if (e.url) e.url = new URL(e.url, base).href;
      window.__slateAssets[p] = e;
    });
    if (typeof CSSStyleSheet === "function" && "replaceSync" in CSSStyleSheet.prototype) {
      b.sheet = new CSSStyleSheet();
      b.sheet.replaceSync(themeCss(man));
    }
    var chain = Promise.resolve();
    (man.libs || []).forEach(function (l) {
      if (l.css) loadDocumentCss(l.css);
      if (l.js) chain = chain.then(function () { return loadScript(l.js); });
    });
    return chain.then(function () { return loadFrontends(b); }).then(function () { return b; });
  });
  return b.ready;
}

/* Every mounted root, for the export runtime's page-wide lookups (component mounting). */
Slate.roots = function () {
  var out = [document];
  Object.keys(BUNDLES).forEach(function (k) {
    BUNDLES[k].cells.forEach(function (el) { if (el.shadowRoot) out.push(el.shadowRoot); });
  });
  return out;
};

/* Wire this notebook's `@replay` marks across every cell of it now on the page. Called (debounced)
   whenever a cell of the notebook mounts or unmounts; the previous wiring is retired by `gen`. */
function scheduleWire(b) {
  if (b.timer) return;
  b.timer = setTimeout(function () {
    b.timer = 0;
    var gen = ++b.gen;
    var scope = {
      roots: b.cells.map(function (el) { return el.shadowRoot; }),
      replays: b.man.replays || {},
      live: function () { return gen === b.gen; }
    };
    var tables = [], prose = [];
    b.cells.forEach(function (el) {
      var st = el._slate;
      if (!st) return;
      (st.charts || []).forEach(function (rec) { _slateWireReplay(rec, rec.opt, scope); });
      tables = tables.concat(st.cell.tablemarks || []);
      prose = prose.concat(st.cell.prosemarks || []);
    });
    _slateWireTables(tables, scope);
    _slateWireProse(prose, scope);
  }, 0);
}

/* ── the element ───────────────────────────────────────────────────────────────────────────── */

function message(el, text) {
  var sr = el.shadowRoot;
  sr.innerHTML = "";
  var d = document.createElement("div");
  d.className = "slate-embed-msg";
  d.textContent = text;
  sr.appendChild(d);
}

/* Scripts inserted with innerHTML never run. Re-create each so it does; a web cell's fragment finds
   its own script through `Slate._currentScript`, since `document.currentScript` is null in a shadow
   root. JSON payloads (component descriptors) are data, not code, and are left alone. */
function runScripts(container) {
  Array.prototype.slice.call(container.querySelectorAll("script")).forEach(function (old) {
    var t = (old.getAttribute("type") || "").toLowerCase();
    if (t && t !== "text/javascript" && t !== "module" && t !== "application/javascript") return;
    var s = document.createElement("script");
    for (var i = 0; i < old.attributes.length; i++) s.setAttribute(old.attributes[i].name, old.attributes[i].value);
    s.textContent = old.textContent;
    Slate._currentScript = s;
    try { old.parentNode.replaceChild(s, old); } finally { Slate._currentScript = null; }
  });
}

function typesetMath(container) {
  if (!window.renderMathInElement) return;
  try {
    window.renderMathInElement(container, {
      delimiters: [{ left: "$$", right: "$$", display: true }, { left: "\\[", right: "\\]", display: true },
                   { left: "$", right: "$", display: false }, { left: "\\(", right: "\\)", display: false }],
      ignoredClasses: ["exp-src", "exp-table"], throwOnError: false
    });
  } catch (e) { console.error("slate-cell: math", e); }
}

function mount(el, b, cell) {
  var sr = el.shadowRoot;
  sr.innerHTML = "";
  var sheets = [componentSheet(), b.sheet].filter(Boolean);
  if (sheets.length === 2 && "adoptedStyleSheets" in sr) {
    sr.adoptedStyleSheets = sheets;
  } else {
    var st = document.createElement("style");
    st.textContent = _SLATE_EMBED_CSS + themeCss(b.man);
    sr.appendChild(st);
  }
  (b.man.libs || []).forEach(function (l) {
    if (!l.css) return;
    var link = document.createElement("link");
    link.rel = "stylesheet"; link.href = l.css;
    sr.appendChild(link);
  });
  el.setAttribute("data-theme", siteTheme(el));
  var wrap = document.createElement("div");
  wrap.className = "slate-embed";
  wrap.innerHTML = cell.html;
  sr.appendChild(wrap);
  rebaseDom(wrap, b.base);
  runScripts(wrap);
  window._slateEnhanceTables(wrap);
  window._slateMediaIn(wrap);
  window.__slateMountComponents(sr);
  typesetMath(wrap);
  var charts = (cell.charts || []).map(function (c) { return [c[0], rebaseValue(c[1], b.base)]; });
  el._slate = {
    bundle: b, cell: cell,
    charts: _slateMountCharts(charts, { roots: [sr], themeEl: el, nowire: true })
  };
  if (b.cells.indexOf(el) < 0) b.cells.push(el);
  scheduleWire(b);
}

function unmount(el) {
  var st = el._slate;
  el._slate = null;
  if (!st) return;
  _slateDisposeCharts(st.charts);
  var b = st.bundle, i = b.cells.indexOf(el);
  if (i >= 0) b.cells.splice(i, 1);
  scheduleWire(b);
}

function render(el) {
  var gen = (el._gen = (el._gen || 0) + 1);
  var id = el.getAttribute("cell"), name = el.getAttribute("bundle");
  var src = el.getAttribute("src") || (name ? bundleRoot() + encodeURIComponent(name) + "/" : "");
  if (!src || !id) { message(el, "slate-cell needs cell= and bundle= (or src=)"); return; }
  bundle(src).then(function (b) {
    if (gen !== el._gen || !el.isConnected) return;
    var entry = b.byId[id];
    if (!entry) throw new Error("no cell '" + id + "' in " + b.base);
    if (!entry.file) { message(el, "Cell '" + id + "' has no output."); return; }
    return getJSON(b.base + entry.file).then(function (cell) {
      if (gen !== el._gen || !el.isConnected) return;
      unmount(el);
      mount(el, b, cell);
    });
  }).catch(function (e) {
    console.error("slate-cell", e);
    if (gen === el._gen) message(el, "Could not load Slate cell '" + id + "': " + e.message);
  });
}

function retheme() {
  Object.keys(BUNDLES).forEach(function (k) {
    BUNDLES[k].cells.forEach(function (el) {
      var t = siteTheme(el);
      if (el.getAttribute("data-theme") === t) return;
      el.setAttribute("data-theme", t);
      if (el._slate) _slateRethemeCharts(el._slate.charts, el);
    });
  });
}

if (window.customElements && !customElements.get("slate-cell")) {
  customElements.define("slate-cell", class extends HTMLElement {
    static get observedAttributes() { return ["src", "bundle", "cell", "theme"]; }
    connectedCallback() {
      if (!this.shadowRoot) this.attachShadow({ mode: "open" });
      render(this);
    }
    disconnectedCallback() {
      this._gen = (this._gen || 0) + 1;       // a load still in flight lands nowhere
      unmount(this);
    }
    attributeChangedCallback(name, oldv, newv) {
      if (oldv === newv || !this.isConnected || !this.shadowRoot) return;
      if (name === "theme") retheme(); else render(this);
    }
  });
  new MutationObserver(retheme).observe(document.documentElement,
                                         { attributes: true, attributeFilter: ["class", "data-theme"] });
  if (window.matchMedia) {
    var mq = window.matchMedia("(prefers-color-scheme: dark)");
    if (mq.addEventListener) mq.addEventListener("change", retheme);
  }
}
