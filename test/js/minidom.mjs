// A deliberately tiny DOM, just big enough to run `Slate.replay` against the markup Julia's
// `_export_control_html` emits. Not a general HTML implementation and not trying to be: it supports
// exactly the tag soup that one function produces, and THROWS on anything else rather than quietly
// returning null and turning a real divergence into a passing test.
//
// Why not jsdom: the Julia test suite runs `node` with zero installed packages (see
// format_parity.mjs), and adding a node_modules dependency to a Julia package's tests buys a network
// requirement in CI for a job this small.

const VOID = new Set(['input', 'br', 'hr', 'img', 'meta', 'link']);

class ClassList {
  constructor(el) { this.el = el; }
  _list() { return (this.el.getAttribute('class') || '').split(/\s+/).filter(Boolean); }
  _set(l) { this.el.setAttribute('class', l.join(' ')); }
  contains(c) { return this._list().includes(c); }
  add(c) { const l = this._list(); if (!l.includes(c)) { l.push(c); this._set(l); } }
  remove(c) { this._set(this._list().filter(x => x !== c)); }
  toggle(c, on) { (on === undefined ? !this.contains(c) : on) ? this.add(c) : this.remove(c); }
}

export class El {
  constructor(tag, attrs = {}) {
    this.tag = tag.toLowerCase();
    this.tagName = tag.toUpperCase();
    this.attrs = attrs;
    this.children = [];
    this.parentElement = null;
    this.listeners = {};
    this.text = '';
  }
  get className() { return this.getAttribute('class') || ''; }
  set className(v) { this.setAttribute('class', v); }
  getAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n) ? this.attrs[n] : null; }
  setAttribute(n, v) { this.attrs[n] = String(v); }
  removeAttribute(n) { delete this.attrs[n]; }
  hasAttribute(n) { return Object.prototype.hasOwnProperty.call(this.attrs, n); }
  get classList() { return new ClassList(this); }
  get textContent() { return this.text; }
  set textContent(v) { this.text = String(v); }
  // Enough of CSSOM for code that positions something — `paint()` writes left/right percentages on
  // a range slider's fill. Reads back what was written, so a test can assert the geometry.
  get style() { return (this._style = this._style || {}); }
  get min() { return this.getAttribute('min'); }
  get max() { return this.getAttribute('max'); }

  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  // Dispatch to THIS element only — the replay code never relies on bubbling, and pretending to
  // support it would be a lie the tests then depend on.
  dispatch(t) { (this.listeners[t] || []).forEach(f => f.call(this, { type: t, target: this })); }
  click() { this.dispatch('click'); }

  // ── form-control semantics the replay code actually uses ────────────────────────────────────
  get value() {
    if (this.tag === 'select') {
      const sel = this.options.filter(o => o.selected);
      return sel.length ? sel[0].value : (this.options[0] ? this.options[0].value : '');
    }
    return this.getAttribute('value') || '';
  }
  set value(v) {
    if (this.tag === 'select') {
      // A real <select> ignores a value none of its options carry; mirroring that keeps a bug in
      // `mirror()` visible instead of being absorbed by a permissive stub.
      const want = String(v);
      this.options.forEach(o => { o.selected = (o.value === want); });
      return;
    }
    this.setAttribute('value', String(v));
  }
  get options() { return this.queryAll('option'); }
  get selectedOptions() { return this.options.filter(o => o.selected); }
  get selected() { return this.hasAttribute('selected'); }
  set selected(b) { b ? this.setAttribute('selected', '') : this.removeAttribute('selected'); }
  get checked() { return this.hasAttribute('checked'); }
  set checked(b) { b ? this.setAttribute('checked', '') : this.removeAttribute('checked'); }
  get disabled() { return this.hasAttribute('disabled'); }
  set disabled(b) { b ? this.setAttribute('disabled', '') : this.removeAttribute('disabled'); }

  // ── tree mutation ───────────────────────────────────────────────────────────────────────────
  // Enough for the export's table enhancer, which builds its own filter/pager chrome and then moves
  // rows in and out of the tbody on every render. A moved node is DETACHED from its old parent first,
  // because the enhancer keeps its own list of every row and re-appends from it — a stub that let a
  // node sit in two parents would render each row twice and call it a pass.
  get parentNode() { return this.parentElement; }
  _detach(child) {
    const i = this.children.indexOf(child);
    if (i >= 0) this.children.splice(i, 1);
  }
  appendChild(child) {
    if (child.parentElement) child.parentElement._detach(child);
    child.parentElement = this;
    this.children.push(child);
    return child;
  }
  insertBefore(child, ref) {
    if (child.parentElement) child.parentElement._detach(child);
    child.parentElement = this;
    const i = ref ? this.children.indexOf(ref) : -1;
    i < 0 ? this.children.push(child) : this.children.splice(i, 0, child);
    return child;
  }
  remove() { if (this.parentElement) this.parentElement._detach(this); this.parentElement = null; }
  get nextSibling() {
    if (!this.parentElement) return null;
    const s = this.parentElement.children;
    return s[s.indexOf(this) + 1] || null;
  }
  // Only `innerHTML = ''` is supported — that is the one form the enhancer uses (clear, then re-append
  // the visible rows). Anything else would need a parser here and would be a different function.
  get innerHTML() { return ''; }
  set innerHTML(v) {
    if (String(v) !== '') throw new Error('minidom: innerHTML= only supports clearing ("")');
    this.children.forEach(c => { c.parentElement = null; });
    this.children = [];
  }
  closest(sel) {
    for (let e = this; e && e.matches; e = e.parentElement) if (e.matches(sel)) return e;
    return null;
  }

  // ── the table interface the enhancer reads ──────────────────────────────────────────────────
  get tHead() { return this.children.find(c => c.tag === 'thead') || null; }
  get tBodies() { return this.children.filter(c => c.tag === 'tbody'); }
  get rows() { return this.children.filter(c => c.tag === 'tr'); }
  get cells() { return this.children.filter(c => c.tag === 'td' || c.tag === 'th'); }

  // ── selectors ───────────────────────────────────────────────────────────────────────────────
  descendants(out = []) {
    for (const c of this.children) { out.push(c); c.descendants(out); }
    return out;
  }
  matches(sel) { return sel.split(',').some(s => matchSimple(this, s.trim())); }
  queryAll(sel) {
    return sel.split(',').flatMap(part => {
      const steps = part.trim().split(/\s+/);              // one descendant combinator is enough
      let pool = this.descendants();
      for (const st of steps) pool = (st === steps[0] ? pool : pool.flatMap(e => e.descendants()))
        .filter(e => matchSimple(e, st));
      return pool;
    }).filter((e, i, a) => a.indexOf(e) === i);
  }
  querySelectorAll(sel) { return this.queryAll(sel); }
  querySelector(sel) { return this.queryAll(sel)[0] || null; }
}

// tag / .class / [attr] / [attr=value] / [attr="value"] / :checked — composable, in that order.
function matchSimple(el, sel) {
  if (!sel) return false;
  const re = /^([a-zA-Z][\w-]*)?((?:\.[\w-]+)*)((?:\[[^\]]+\])*)((?::[\w-]+)*)$/;
  const m = re.exec(sel);
  if (!m) throw new Error(`minidom: unsupported selector ${JSON.stringify(sel)} — extend matchSimple`);
  const [, tag, classes, attrs, pseudos] = m;
  if (tag && el.tag !== tag.toLowerCase()) return false;
  for (const c of (classes.match(/\.[\w-]+/g) || []))
    if (!el.classList.contains(c.slice(1))) return false;
  for (const a of (attrs.match(/\[[^\]]+\]/g) || [])) {
    const body = a.slice(1, -1), eq = body.indexOf('=');
    if (eq < 0) { if (!el.hasAttribute(body)) return false; continue; }
    const name = body.slice(0, eq);
    const want = body.slice(eq + 1).replace(/^["']|["']$/g, '');
    if (el.getAttribute(name) !== want) return false;
  }
  for (const p of (pseudos.match(/:[\w-]+/g) || [])) {
    if (p === ':checked') { if (!(el.checked || el.selected)) return false; }
    else throw new Error(`minidom: unsupported pseudo ${p} — extend matchSimple`);
  }
  return true;
}

// ── parser ────────────────────────────────────────────────────────────────────────────────────
// Handles `<tag a="1" bare>`, `</tag>`, `<tag/>` and text. Anything it does not recognise throws.
export function parse(html) {
  const root = new El('#root');
  const stack = [root];
  const tagRe = /<(\/?)([a-zA-Z][\w-]*)((?:\s+[\w-]+(?:="[^"]*")?)*)\s*(\/?)>/g;
  let pos = 0, m;
  while ((m = tagRe.exec(html)) !== null) {
    const text = html.slice(pos, m.index).trim();
    if (text) stack[stack.length - 1].text += text;
    pos = tagRe.lastIndex;
    const [, closing, tag, attrText, selfClose] = m;
    if (closing) {
      const open = stack.pop();
      if (!open || open.tag !== tag.toLowerCase())
        throw new Error(`minidom: </${tag}> closes <${open ? open.tag : 'nothing'}>`);
      continue;
    }
    const attrs = {};
    for (const a of attrText.matchAll(/([\w-]+)(?:="([^"]*)")?/g)) attrs[a[1]] = a[2] === undefined ? '' : a[2];
    const el = new El(tag, attrs);
    el.parentElement = stack[stack.length - 1];
    stack[stack.length - 1].children.push(el);
    if (!selfClose && !VOID.has(el.tag)) stack.push(el);
  }
  const tail = html.slice(pos).trim();
  if (tail) stack[stack.length - 1].text += tail;
  if (stack.length !== 1)
    throw new Error(`minidom: unclosed <${stack[stack.length - 1].tag}>`);
  return root;
}

// A `document` with the methods the replay code and the export's table enhancer call on it. `body` is
// where a detached node ends up (the CSV download builds a link there); nothing reads it back.
export function makeDocument(html) {
  const root = parse(html);
  const body = new El('body');
  root.appendChild(body);
  return {
    root,
    body,
    createElement: tag => new El(tag),
    querySelectorAll: sel => root.queryAll(sel),
    querySelector: sel => root.queryAll(sel)[0] || null,
  };
}
