// Writing a notebook together (see collab.jl). The browsers of the people editing a notebook meet in
// its room at a knowledge base: a WebSocket there carries their WebRTC handshake, and relays the
// notebook's updates between browsers that cannot connect directly. Each browser keeps the shared
// document (Yjs) in step with its own hub: the cells, their order, kinds and tags, and their text,
// typed into live in the editors of those who have a cell open. A commit (Shift-Enter, or a run) is
// committed on the others' hubs: a markdown cell is rendered there, any other saved without running.
// Nothing the others write runs on this machine until someone here runs it.
//
// Modes: `auto` connects directly and relays for a peer it cannot reach; `direct` never relays the
// document; `relay` never connects directly. The panel shows, for each peer, how it is reached.
(function () {
  'use strict';
  const ICE = [{ urls: 'stun:stun.cloudflare.com:3478' }, { urls: 'stun:stun.l.google.com:19302' }];
  const COLORS = ['#e06c75', '#61afef', '#98c379', '#e5c07b', '#c678dd', '#56b6c2', '#d19a66', '#be5046'];
  const MSG_SYNC = 0, MSG_AWARENESS = 1;
  const RELAY_AFTER_MS = 5000;           // how long a direct connection gets before the relay carries a peer
  const saved = () => { try { return JSON.parse(localStorage.getItem('slateCollab') || '{}'); } catch (_) { return {}; } };
  let S = null;                          // the session while in a room
  const style = document.createElement('style');
  style.textContent = '.md.collab-preview{outline:1px dashed rgba(229,192,123,.6);outline-offset:4px}';
  document.head.appendChild(style);

  const loadBundle = () => window.SlateY ? Promise.resolve(window.SlateY) : new Promise((ok, no) => {
    const s = document.createElement('script');
    s.src = '/assets/js/collab.bundle.js';
    s.onload = () => ok(window.SlateY);
    s.onerror = () => no(new Error('collab.bundle.js did not load'));
    document.head.appendChild(s);
  });
  const toB64 = u8 => { let s = ''; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000)); return btoa(s); };
  const fromB64 = b => Uint8Array.from(atob(b), c => c.charCodeAt(0));
  const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

  // ── The room: signaling, direct connections and the relay ───────────────────────────────────────
  class Room {
    constructor(SY, { ws, room, doc, awareness, mode, onChange }) {
      Object.assign(this, { SY, url: ws, room, relayTopic: room + '#relay', doc, awareness, mode, onChange });
      this.me = Math.random().toString(36).slice(2, 12);
      this.peers = new Map();
      this.closed = false; this.sock = null; this.sockState = 'connecting'; this.retry = 0;
      this._onUpdate = (u, origin) => { if (origin !== this) this.broadcast(this.encUpdate(u)); };
      this._onAware = ({ added, updated, removed }, origin) => {
        if (origin === 'local') this.broadcast(this.encAware(added.concat(updated, removed)));
      };
      this._onAwareChange = ({ added, updated }, origin) => {
        if (origin && origin.clients) for (const c of added.concat(updated)) origin.clients.add(c);
        this.onChange();
      };
      doc.on('update', this._onUpdate);
      awareness.on('update', this._onAware);
      awareness.on('change', this._onAwareChange);
      this.timers = [setInterval(() => this.stats(), 3000), setInterval(() => this.sendSig({ type: 'ping' }), 25000)];
      this._bye = () => this.publish(this.room, { type: 'bye', from: this.me });
      window.addEventListener('beforeunload', this._bye);
      this.connect();
    }
    connect() {
      if (this.closed) return;
      const sock = this.sock = new WebSocket(this.url);
      sock.onopen = () => {
        this.retry = 0; this.sockState = 'open';
        this.sendSig({ type: 'subscribe', topics: [this.room, this.relayTopic] });
        this.publish(this.room, { type: 'announce', from: this.me });
        this.onChange();
      };
      sock.onmessage = ev => {
        let m; try { m = JSON.parse(ev.data); } catch (_) { return; }
        if (m.type === 'publish') this.onPublish(m.topic, m.data);
      };
      sock.onclose = () => {
        if (this.sock !== sock) return;
        this.sockState = 'closed'; this.onChange();
        if (!this.closed) setTimeout(() => this.connect(), Math.min(30000, 1000 * 2 ** this.retry++));
      };
    }
    sendSig(m) { if (this.sock && this.sock.readyState === 1) this.sock.send(JSON.stringify(m)); }
    publish(topic, data) { this.sendSig({ type: 'publish', topic, data }); }
    onPublish(topic, data) {
      if (!data || data.from === this.me || (data.to && data.to !== this.me)) return;
      if (topic === this.room) {
        if (data.type === 'announce') this.meet(data.from, !data.to);
        else if (data.type === 'signal') this.signal(data.from, data.signal);
        else if (data.type === 'bye') this.drop(data.from);
      } else if (topic === this.relayTopic && typeof data.m === 'string') {
        if (this.mode === 'direct') return;
        const p = this.meet(data.from, false);
        if (p.state === 'direct' && this.mode === 'auto') return;      // it reaches us directly: this is a copy
        if (p.state !== 'direct') p.state = 'relay';
        this.receive(p, fromB64(data.m), 'relay');
      }
    }
    // A peer announced, or was heard from: known from now on, and called if it is ours to call.
    meet(id, answer) {
      let p = this.peers.get(id);
      if (p) return p;
      p = { id, state: 'connecting', kind: '', rtt: null, direct: 0, relayed: 0, clients: new Set(), since: Date.now(), pc: null, dc: null, pending: [] };
      this.peers.set(id, p);
      if (answer) this.publish(this.room, { type: 'announce', from: this.me, to: id });
      if (this.mode !== 'relay' && this.me < id) this.call(p);
      if (this.mode !== 'direct') {
        setTimeout(() => { if (this.peers.get(id) === p && p.state !== 'direct') this.relaySync(p); },
                   this.mode === 'relay' ? 0 : RELAY_AFTER_MS);
      }
      this.onChange();
      return p;
    }
    drop(id) {
      const p = this.peers.get(id); if (!p) return;
      this.peers.delete(id);
      try { p.pc && p.pc.close(); } catch (_) {}
      this.SY.awareness.removeAwarenessStates(this.awareness, [...p.clients], this);
      this.onChange();
    }
    relaySync(p) {
      if (p.state !== 'direct') p.state = 'relay';
      this.sendTo(p, this.encStep1(), 'relay');
      this.sendTo(p, this.encAware([this.awareness.clientID]), 'relay');
      this.onChange();
    }
    lost(p) {
      if (p.state !== 'direct') return;
      p.state = this.mode === 'direct' ? 'lost' : 'relay';
      if (this.mode !== 'direct') this.relaySync(p);
      this.onChange();
    }
    makePc(p) {
      const pc = p.pc = new RTCPeerConnection({ iceServers: ICE });
      pc.onicecandidate = e => { if (e.candidate) this.publish(this.room, { type: 'signal', from: this.me, to: p.id, signal: { candidate: e.candidate.toJSON() } }); };
      pc.onconnectionstatechange = () => { if (['failed', 'closed', 'disconnected'].includes(pc.connectionState)) this.lost(p); };
      pc.ondatachannel = e => this.channel(p, e.channel);
      return pc;
    }
    async call(p) {
      try {
        const pc = this.makePc(p);
        this.channel(p, pc.createDataChannel('yjs'));
        await pc.setLocalDescription(await pc.createOffer());
        this.publish(this.room, { type: 'signal', from: this.me, to: p.id, signal: { sdp: pc.localDescription.toJSON() } });
      } catch (e) { console.warn('collab: could not call a peer', e); }
    }
    async signal(from, s) {
      if (this.mode === 'relay' || !s) return;
      const p = this.meet(from, false);
      try {
        if (s.sdp) {
          const pc = p.pc || this.makePc(p);
          await pc.setRemoteDescription(s.sdp);
          if (s.sdp.type === 'offer') {
            await pc.setLocalDescription(await pc.createAnswer());
            this.publish(this.room, { type: 'signal', from: this.me, to: p.id, signal: { sdp: pc.localDescription.toJSON() } });
          }
          for (const c of p.pending.splice(0)) await pc.addIceCandidate(c);
        } else if (s.candidate) {
          if (p.pc && p.pc.remoteDescription) await p.pc.addIceCandidate(s.candidate);
          else p.pending.push(s.candidate);
        }
      } catch (e) { console.warn('collab: signaling failed', e); }
    }
    channel(p, dc) {
      p.dc = dc; dc.binaryType = 'arraybuffer';
      dc.onopen = () => {
        p.state = 'direct';
        this.sendTo(p, this.encStep1(), 'direct');
        this.sendTo(p, this.encAware([this.awareness.clientID]), 'direct');
        this.stats();
      };
      dc.onmessage = e => this.receive(p, new Uint8Array(e.data), 'direct');
      dc.onclose = () => this.lost(p);
    }
    sendTo(p, bytes, via) {
      if (via === 'direct' && p.dc && p.dc.readyState === 'open') p.dc.send(bytes);
      else if (this.mode !== 'direct') this.publish(this.relayTopic, { from: this.me, to: p.id, m: toB64(bytes) });
    }
    broadcast(bytes) {
      let relay = false;
      for (const p of this.peers.values()) {
        if (p.dc && p.dc.readyState === 'open') p.dc.send(bytes);
        else relay = true;
      }
      if (relay && this.mode !== 'direct') this.publish(this.relayTopic, { from: this.me, m: toB64(bytes) });
    }
    encUpdate(u) { const { encoding: e, sync } = this.SY; const enc = e.createEncoder(); e.writeVarUint(enc, MSG_SYNC); sync.writeUpdate(enc, u); return e.toUint8Array(enc); }
    encStep1() { const { encoding: e, sync } = this.SY; const enc = e.createEncoder(); e.writeVarUint(enc, MSG_SYNC); sync.writeSyncStep1(enc, this.doc); return e.toUint8Array(enc); }
    encAware(ids) {
      const { encoding: e, awareness: a } = this.SY; const enc = e.createEncoder();
      e.writeVarUint(enc, MSG_AWARENESS); e.writeVarUint8Array(enc, a.encodeAwarenessUpdate(this.awareness, ids));
      return e.toUint8Array(enc);
    }
    // A message from peer `p`, by `via`: applied, and what it asks for answered the same way.
    receive(p, data, via) {
      const { encoding: e, decoding: d, sync, awareness: a } = this.SY;
      try {
        const dec = d.createDecoder(data), enc = e.createEncoder();
        const t = d.readVarUint(dec);
        if (t === MSG_SYNC) {
          e.writeVarUint(enc, MSG_SYNC);
          sync.readSyncMessage(dec, enc, this.doc, this);
          if (e.length(enc) > 1) this.sendTo(p, e.toUint8Array(enc), via);
        } else if (t === MSG_AWARENESS) {
          a.applyAwarenessUpdate(this.awareness, d.readVarUint8Array(dec), p);
        }
      } catch (err) { console.warn('collab: a message could not be read', err); return; }
      via === 'direct' ? p.direct++ : p.relayed++;
    }
    // How each direct connection is made (host, srflx, prflx or relay candidates) and its round trip.
    async stats() {
      for (const p of this.peers.values()) {
        if (!p.pc || p.state !== 'direct') continue;
        try {
          const r = await p.pc.getStats(); let pair = null;
          r.forEach(s => { if (s.type === 'transport' && s.selectedCandidatePairId) pair = r.get(s.selectedCandidatePairId); });
          if (!pair) r.forEach(s => { if (s.type === 'candidate-pair' && s.state === 'succeeded' && (s.nominated || s.selected)) pair = s; });
          if (pair) {
            const l = r.get(pair.localCandidateId), rm = r.get(pair.remoteCandidateId);
            p.kind = (l && l.candidateType || '?') + '↔' + (rm && rm.candidateType || '?');
            p.rtt = pair.currentRoundTripTime != null ? Math.round(pair.currentRoundTripTime * 1000) : null;
          }
        } catch (_) {}
      }
      this.onChange();
    }
    close() {
      this.closed = true;
      this._bye();
      window.removeEventListener('beforeunload', this._bye);
      this.timers.forEach(clearInterval);
      this.doc.off('update', this._onUpdate);
      this.awareness.off('update', this._onAware);
      this.awareness.off('change', this._onAwareChange);
      for (const p of this.peers.values()) { try { p.pc && p.pc.close(); } catch (_) {} }
      this.peers.clear();
      try { this.sock && this.sock.close(); } catch (_) {}
    }
  }

  // ── The notebook in the room ────────────────────────────────────────────────────────────────────
  // The room's document holds the notebook: `order` (the cells' ids), `meta` (each cell's kind and
  // tags), `text` (each cell's text, typed into live) and `committed` (each cell's text as last
  // committed, Shift-Enter or a run). Each browser keeps its hub in step with it. Changes are found by
  // comparing this hub's notebook and the room's with `base`, what both last agreed on: what differs
  // here from `base` was done here and goes to the room; what differs in the room was done by the
  // others and is applied here, through the hub's `collab/apply`, which runs nothing. Cells this copy
  // had and the room did not when it joined stay out of it (`unshared`).
  const cells = () => ((window.__slateState || window.nbState || {}).cells) || [];
  const isProse = kind => !!(window.kindInfo && window.kindInfo(kind).prose);
  const srcEq = (a, b) => window.slateStore && window.slateStore.srcEq ? window.slateStore.srcEq(a, b) : a === b;
  const bindAll = () => document.dispatchEvent(new CustomEvent('slate:collab'));
  const metaOf = c => ({ kind: c.kind, tags: [...(c.tags || [])].sort() });
  const metaEq = (a, b) => !!a && !!b && a.kind === b.kind && a.tags.join('\u0000') === b.tags.join('\u0000');
  const listEq = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

  function localNb() {
    const order = [], meta = {}, source = {};
    for (const c of cells()) {
      if (S.unshared.has(c.id)) continue;
      order.push(c.id); meta[c.id] = metaOf(c); source[c.id] = c.source || '';
    }
    return { order, meta, source };
  }
  function roomNb() {
    const order = S.order.toArray(), meta = {};
    for (const id of order) { const m = S.meta.get(id); if (m) meta[id] = { kind: m.kind, tags: [...(m.tags || [])] }; }
    return { order, meta };
  }

  // Put cell `id` into the room after `after` (first when not in the room).
  function roomInsert(id, meta, source, after) {
    const { Y } = S.SY;
    const at = after == null ? -1 : S.order.toArray().indexOf(after);
    S.order.insert(at + 1, [id]);
    S.meta.set(id, meta);
    S.texts.set(id, new Y.Text(source));
    S.committed.set(id, source);
  }
  function roomDelete(id) {
    const i = S.order.toArray().indexOf(id);
    if (i >= 0) S.order.delete(i, 1);
    S.meta.delete(id); S.texts.delete(id); S.committed.delete(id);
  }

  // Start the room from this notebook, unless someone already has.
  function seed() {
    if (S.order.length > 0) return false;
    S.doc.transact(() => {
      let prev = null;
      for (const c of cells()) { roomInsert(c.id, metaOf(c), c.source || '', prev); prev = c.id; }
    }, 'local');
    S.base = roomNb();
    return true;
  }

  // Joining a room that has a notebook: what both have is agreed; the room's cells this copy lacks
  // are added here by the first reconcile; this copy's cells the room lacks stay out of it.
  function adopt() {
    const R = roomNb(), here = new Set(cells().map(c => c.id));
    S.unshared = new Set([...here].filter(id => !(id in R.meta)));
    const order = R.order.filter(id => here.has(id)), meta = {};
    for (const id of order) meta[id] = R.meta[id];
    S.base = { order, meta };
  }

  let pending = null;
  function reconcileSoon() {
    if (!S || !S.base) return;
    clearTimeout(pending);
    pending = setTimeout(reconcile, 120);
  }

  async function reconcile() {
    if (!S || !S.base) return;
    if (S.applying) { S.again = true; return; }
    const L = localNb(), B = S.base;
    // What was done here goes to the room.
    S.doc.transact(() => {
      let R = roomNb();
      L.order.forEach((id, i) => {
        if (id in B.meta || id in R.meta) return;
        let after = null;
        for (let j = i - 1; j >= 0; j--) if (L.order[j] in R.meta) { after = L.order[j]; break; }
        roomInsert(id, L.meta[id], L.source[id], after);
        R = roomNb();
      });
      for (const id of B.order) if (!(id in L.meta) && id in R.meta) roomDelete(id);
      R = roomNb();
      const common = new Set(L.order.filter(id => id in R.meta && id in B.meta));
      const Lc = L.order.filter(id => common.has(id)), Bc = B.order.filter(id => common.has(id));
      if (!listEq(Lc, Bc)) {
        // Moved here: the room takes this order, its cells this copy lacks kept after the cell before them.
        const next = [];
        const rest = R.order.filter(id => !common.has(id));
        const placed = new Set();
        for (const id of Lc) {
          next.push(id); placed.add(id);
          for (const r of rest) if (!placed.has(r) && R.order[R.order.indexOf(r) - 1] === id) { next.push(r); placed.add(r); }
        }
        for (const r of rest) if (!placed.has(r)) next.push(r);
        if (!listEq(next, R.order)) { S.order.delete(0, S.order.length); S.order.insert(0, next); }
      }
      for (const id of common) if (!metaEq(L.meta[id], B.meta[id]) && !metaEq(L.meta[id], R.meta[id])) S.meta.set(id, L.meta[id]);
    }, 'local');
    bindAll();                         // an editor opened before its cell was in the room binds now
    // What the others did comes here.
    const R = roomNb(), ops = [];
    const have = new Set(L.order);
    R.order.forEach((id, i) => {
      if (have.has(id) || id in B.meta || S.unshared.has(id)) return;
      const yt = S.texts.get(id);
      ops.push({ op: 'insert', id, kind: R.meta[id].kind, tags: R.meta[id].tags, source: yt ? yt.toString() : '',
                 after: i > 0 ? R.order[i - 1] : '' });
      have.add(id);
    });
    for (const id of B.order) if (!(id in R.meta) && id in L.meta) ops.push({ op: 'delete', id });
    const common = R.order.filter(id => id in L.meta && id in B.meta);
    const Lc = L.order.filter(id => common.includes(id)), Bc = B.order.filter(id => common.includes(id));
    if (listEq(Lc, Bc) && !listEq(common, Bc)) {
      common.forEach((id, i) => { if (Lc.indexOf(id) !== i) ops.push({ op: 'move', id, after: i > 0 ? common[i - 1] : '' }); });
    }
    for (const id of common) {
      const r = R.meta[id], l = L.meta[id], b = B.meta[id];
      if (metaEq(l, b) && !metaEq(r, b)) {
        if (r.kind !== l.kind) ops.push({ op: 'kind', id, kind: r.kind });
        if (r.tags.join('\u0000') !== l.tags.join('\u0000')) ops.push({ op: 'tags', id, tags: r.tags });
      }
    }
    S.base = R;
    if (ops.length) {
      S.applying = true;
      try {
        const st = await api('POST', '/api/collab/apply', { ops });
        if (st && st.cells && window.renderAll) window.renderAll(st);
      } catch (e) { console.warn('collab: the room\'s changes were not applied', e); }
      S.applying = false;
      bindAll();
    }
    decorate();
    ui.render();
    if (S && S.again) { S.again = false; reconcileSoon(); }
  }

  // Another's commit of cell `id`, committed here: a markdown cell is rendered (as Shift-Enter does),
  // any other cell's text is saved without running it.
  async function applyCommit(id) {
    if (!S) return;
    const src = S.committed.get(id);
    const c = cells().find(x => x.id === id);
    if (typeof src !== 'string' || !c || srcEq(src, c.source || '')) return;
    try {
      if (isProse(c.kind)) {
        window.srcMap[id] = src;
        window.applyAck && window.applyAck(await api('POST', '/api/cell/' + id, { source: src }));
      } else {
        const st = await api('POST', '/api/collab/apply', { ops: [{ op: 'source', id, source: src }] });
        if (st && st.cells && window.renderAll) window.renderAll(st);
      }
    } catch (e) { console.warn('collab: could not commit ' + id, e); }
    const el = document.querySelector('#cell-' + CSS.escape(id) + ' .md');
    if (el) el.classList.remove('collab-preview');
  }

  // A markdown cell another is typing in, rendered as they pause, when it is not open here.
  const previewTimers = {};
  function previewSoon(id) {
    clearTimeout(previewTimers[id]);
    previewTimers[id] = setTimeout(async () => {
      if (!S || S.bound.has(id) || !S.texts.has(id)) return;
      const c = cells().find(x => x.id === id);
      if (!c || !isProse(c.kind)) return;
      const source = S.texts.get(id).toString();
      if (srcEq(source, c.source || '')) return;
      try {
        const r = await api('POST', '/api/collab/render', { id, source });
        const el = document.querySelector('#cell-' + CSS.escape(id) + ' .md');
        if (el && r && typeof r.html === 'string') {
          el.innerHTML = r.html;
          el.classList.add('collab-preview');
          el.title = 'Being written by others: not committed yet';
        }
      } catch (_) {}
    }, 400);
  }

  // Who is in which cell, and which cells are not in the room, on the cells' headers.
  function decorate() {
    document.querySelectorAll('.collab-who').forEach(el => el.remove());
    if (!S) { document.querySelectorAll('.collab-preview').forEach(el => el.classList.remove('collab-preview')); return; }
    const by = {};
    S.awareness.getStates().forEach((st, client) => {
      if (client === S.awareness.clientID || !st.cell || !st.user) return;
      (by[st.cell] = by[st.cell] || []).push(st.user);
    });
    const tag = (id, html) => {
      const head = document.querySelector('#cell-' + CSS.escape(id) + ' .cellhead');
      if (!head) return;
      const span = document.createElement('span');
      span.className = 'collab-who';
      span.style.cssText = 'margin-left:8px;font-size:11px;opacity:.9';
      span.innerHTML = html;
      head.appendChild(span);
    };
    for (const [id, users] of Object.entries(by)) tag(id, users.map(u => `<span style="color:${esc(u.color)}">✎ ${esc(u.name)}</span>`).join(' '));
    for (const id of S.unshared) tag(id, '<span style="opacity:.7" title="This copy had this cell when it joined; the room does not">not shared</span>');
  }

  // A cell's editor (markdown or code; not a web cell's panes), bound to the cell's text in the room.
  const editorExtension = ctx => {
    if (!ctx || !ctx.cellId || ctx.lang || !window.CM6) return [];
    const { ViewPlugin, Compartment, Transaction, Prec, keymap } = window.CM6;
    const comp = new Compartment(), id = ctx.cellId;
    return [comp.of([]), ViewPlugin.define(view => {
      let undo = null, gone = false;
      const bind = () => {
        if (gone || undo || !S || !S.texts.has(id)) return;
        const SY = S.SY, yt = S.texts.get(id);
        const text = yt.toString(), cur = view.state.doc.toString();
        undo = new SY.Y.UndoManager(yt);
        // One transaction: the editor takes the shared text, and the binding starts on it.
        view.dispatch({
          changes: cur === text ? undefined : { from: 0, to: cur.length, insert: text },
          effects: comp.reconfigure([SY.yCollab(yt, S.awareness, { undoManager: undo }), Prec.high(keymap.of(SY.yUndoManagerKeymap))]),
          annotations: Transaction.addToHistory.of(false),
        });
        S.bound.set(id, view);
        const md = document.querySelector('#cell-' + CSS.escape(id) + ' .md');
        if (md) md.classList.remove('collab-preview');
        if (view.hasFocus) S.awareness.setLocalStateField('cell', id);   // focused before it was bound
      };
      const unbind = () => {
        if (!undo) return;
        try { view.dispatch({ effects: comp.reconfigure([]) }); } catch (_) {}
        undo.destroy(); undo = null;
      };
      const onSession = () => queueMicrotask(() => {
        if (!S) return unbind();
        if (undo && S.bound.get(id) !== view) unbind();   // a new room: bind again to its text
        bind();
      });
      const focus = on => () => { if (S && undo) S.awareness.setLocalStateField('cell', on ? id : null); };
      const fin = focus(true), fout = focus(false);
      document.addEventListener('slate:collab', onSession);
      view.dom.addEventListener('focusin', fin);
      view.dom.addEventListener('focusout', fout);
      queueMicrotask(bind);
      return {
        destroy() {
          gone = true;
          document.removeEventListener('slate:collab', onSession);
          view.dom.removeEventListener('focusin', fin);
          view.dom.removeEventListener('focusout', fout);
          if (undo) undo.destroy();
          if (S && S.bound.get(id) === view) { S.bound.delete(id); S.awareness.setLocalStateField('cell', null); }
        },
      };
    })];
  };
  window.slateRegisterEditorExtension && window.slateRegisterEditorExtension(editorExtension);

  // An editor bound to a shared text follows the text: the hub's source is only a commit of it.
  window.slateCollabBound = id => !!(S && S.bound.has(id));
  document.addEventListener('slate:source-committed', e => {
    if (!S || !S.base || !e.detail || !S.texts.has(e.detail.id)) return;
    S.committed.set(e.detail.id, e.detail.source);
  });
  document.addEventListener('slate:state', () => { if (S && S.base && !S.applying) reconcileSoon(); decorate(); });

  // Until the room's notebook has arrived from the others: at once when nobody else is there, at
  // most a few seconds otherwise (the relay takes over a peer not reached directly after five).
  function whenSynced(done) {
    const t0 = Date.now();
    const check = () => {
      if (!S) return;
      const waited = Date.now() - t0, peers = S.provider.peers.size;
      if (S.order.length > 0 || (peers === 0 && waited > 2000) || waited > 9000) done();
      else setTimeout(check, 200);
    };
    check();
  }

  async function join({ kb, project, mode }) {
    if (S) leave();
    localStorage.setItem('slateCollab', JSON.stringify({ kb, project, mode }));
    ui.say('Asking ' + kb + ' for a ticket…');
    let t;
    try { t = await api('POST', '/api/collab/ticket', { kb, project }); }
    catch (e) { ui.say('The hub did not answer'); return; }
    if (!t.ok) { ui.say(t.error || 'No ticket', t.signin ? kb : null, !t.signin && (t.status === 401 || t.status === 403) ? { kb, project, mode } : null); return; }
    let SY;
    try { SY = await loadBundle(); } catch (e) { ui.say(String(e.message || e)); return; }
    const doc = new SY.Y.Doc();
    const awareness = new SY.awareness.Awareness(doc);
    const color = COLORS[doc.clientID % COLORS.length];
    awareness.setLocalStateField('user', { name: t.name || 'Someone', color, colorLight: color + '33' });
    S = { SY, doc, awareness, order: doc.getArray('order'), meta: doc.getMap('meta'), texts: doc.getMap('text'),
          committed: doc.getMap('committed'), bound: new Map(), unshared: new Set(), base: null, applying: false,
          kb, project, mode, room: t.room, name: t.name, others: t.rooms || [], started: Date.now() };
    S.provider = new Room(SY, { ws: t.ws, room: t.room, doc, awareness, mode, onChange: () => { decorate(); ui.render(); } });
    S.committed.observe(ev => { if (!ev.transaction.local && S.base) for (const id of ev.keysChanged) applyCommit(id); });
    S.texts.observeDeep(evs => {
      if (!S.base || evs.every(e => e.transaction.local)) return;
      for (const e of evs) { const id = e.path && e.path[0]; if (typeof id === 'string') previewSoon(id); }
      bindAll();
    });
    const roomChanged = ev => { if (!ev.transaction.local && S.base) reconcileSoon(); };
    S.order.observe(roomChanged);
    S.meta.observe(roomChanged);
    ui.say('Joining ' + t.room + '…');
    whenSynced(() => {
      if (!S) return;
      const started = seed();
      if (!started) adopt();
      ui.say(started ? 'You started the room from this copy.' : '');
      bindAll();
      reconcile();
    });
  }

  function leave() {
    if (!S) return;
    const s = S;
    S = null;
    bindAll();                         // editors let go of the shared texts
    s.provider.close();
    s.awareness.destroy();
    s.doc.destroy();
    decorate();
    ui.render();
  }

  // ── The panel ───────────────────────────────────────────────────────────────────────────────────
  const ui = {
    el: null, msg: '', signinKb: null, tokenFor: null,
    open() {
      if (!this.el) {
        this.el = document.createElement('div');
        this.el.id = 'collabpanel';
        this.el.style.cssText = 'position:fixed;right:16px;top:56px;z-index:900;width:340px;background:var(--panel-bg,#151a2c);' +
          'color:var(--fg,#d4d8e8);border:1px solid var(--border,#2a3150);border-radius:8px;padding:12px;font:13px system-ui,sans-serif;' +
          'box-shadow:0 8px 24px rgba(0,0,0,.4)';
        document.body.appendChild(this.el);
      }
      this.el.style.display = '';
      this.render();
    },
    close() { if (this.el) this.el.style.display = 'none'; },
    // `tokenFor`: the join that failed for want of a token, tried again once one is given.
    say(msg, signinKb = null, tokenFor = null) { this.msg = msg; this.signinKb = signinKb; this.tokenFor = tokenFor; this.render(); },
    render() {
      const el = this.el; if (!el || el.style.display === 'none') return;
      const head = '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">' +
        '<b>Write together</b><button data-act="close" style="background:none;border:0;color:inherit;cursor:pointer">✕</button></div>';
      const msg = this.msg ? `<div style="margin:6px 0;color:#e5c07b">${esc(this.msg)}</div>` : '';
      const signin = (this.signinKb ? `<button data-act="signin">Sign in to ${esc(this.signinKb)}</button>` : '') +
        (this.tokenFor ? `<label style="display:block;margin:6px 0">API token for ${esc(this.tokenFor.kb)} <input data-f="token" type="password" style="width:100%" autocomplete="off"></label>` +
                         '<button data-act="token">Save and join</button>' : '');
      if (!S) {
        const v = saved();
        el.innerHTML = head +
          `<label style="display:block;margin:4px 0">Knowledge base <input data-f="kb" style="width:100%" value="${esc(v.kb || 'http://localhost:8000')}"></label>` +
          `<label style="display:block;margin:4px 0">Project <input data-f="project" style="width:100%" value="${esc(v.project || '')}"></label>` +
          `<label style="display:block;margin:4px 0">Connect <select data-f="mode">` +
          ['auto', 'direct', 'relay'].map(m => `<option${(v.mode || 'auto') === m ? ' selected' : ''}>${m}</option>`).join('') + '</select></label>' +
          '<div style="margin-top:8px"><button data-act="join" title="Join this notebook\'s room: the first in starts it from their copy, the others take its cells">Join</button></div>' +
          msg + signin;
      } else {
        const p = S.provider, states = S.awareness.getStates();
        const nameOf = peer => { for (const c of peer.clients) { const st = states.get(c); if (st && st.user) return st.user.name; } return peer.id; };
        const rows = [...p.peers.values()].map(peer => {
          const how = peer.state === 'direct' ? `direct ${peer.kind}${peer.rtt != null ? ' · ' + peer.rtt + ' ms' : ''}` : peer.state;
          return `<tr><td>${esc(nameOf(peer))}</td><td>${esc(how)}</td><td style="text-align:right">${peer.direct}/${peer.relayed}</td></tr>`;
        }).join('') || '<tr><td colspan="3" style="opacity:.7">Nobody else yet</td></tr>';
        const people = [];
        states.forEach((st, c) => { if (st && st.user) people.push(c === S.awareness.clientID ? st.user.name + ' (you)' : st.user.name); });
        // Others of the project in another room: a copy whose document id differs is a different room.
        const elsewhere = (S.others || []).filter(r => r.room !== S.room).flatMap(r => r.people.map(x => `${x.name} (${r.document.slice(0, 8)}…)`));
        el.innerHTML = head +
          `<div title="The room is the project and this notebook's document id">${esc(S.room)}</div>` +
          `<div style="opacity:.8">${esc(S.mode)} · signaling ${esc(p.sockState)} · ${S.order.length} cell(s) in the room` +
          (S.unshared.size ? ` · ${S.unshared.size} here not shared` : '') + '</div>' +
          `<div style="margin-top:4px">In the room: ${esc(people.join(', ') || '—')}</div>` +
          (elsewhere.length ? `<div style="margin-top:4px;color:#e5c07b">In another copy's room: ${esc(elsewhere.join(', '))}. ` +
                              'A copy with another document id is another room.</div>' : '') +
          '<table style="width:100%;margin:8px 0;border-collapse:collapse"><tr style="opacity:.7"><td>Peer</td><td>Reached</td>' +
          '<td style="text-align:right" title="messages received directly / through the relay">msgs</td></tr>' + rows + '</table>' +
          '<button data-act="leave">Leave</button>' + msg;
      }
      el.querySelectorAll('[data-act]').forEach(b => b.onclick = () => this.act(b.dataset.act));
    },
    field(f) { const i = this.el.querySelector(`[data-f="${f}"]`); return i ? i.value.trim() : ''; },
    async act(a) {
      if (a === 'close') return this.close();
      if (a === 'leave') return leave();
      if (a === 'token') {
        const j = this.tokenFor, token = this.field('token');
        if (!j || !token) return;
        const r = await api('POST', '/api/collab/token', { kb: j.kb, token });
        if (!r || !r.ok) return this.say((r && r.error) || 'The token was not kept');
        return join(j);
      }
      if (a === 'signin') {
        const r = await api('POST', '/api/collab/signin', { kb: this.signinKb });
        if (r && r.to) window.open(r.to, '_blank'); else this.say((r && r.error) || 'Signing in failed');
        return;
      }
      const kb = this.field('kb').replace(/\/+$/, ''), project = this.field('project').toUpperCase(), mode = this.field('mode') || 'auto';
      if (!kb || !project) return this.say('Give the knowledge base and the project');
      join({ kb, project, mode });
    },
  };
  window.openCollab = () => ui.open();
  window.slateCollab = { join, leave, get session() { return S; } };
})();
