// Writing a notebook together (see collab.jl). The browsers of the people editing a notebook meet in
// its room at a knowledge base: a WebSocket there carries their WebRTC handshake, and relays the
// notebook's updates between browsers that cannot connect directly. Each browser keeps the shared
// document (Yjs) in step with its own hub. A markdown cell's text is shared as it is typed, in the
// editors of those who have it open, and a commit (Shift-Enter) on one side is committed on the
// others', whose hubs render it. Only markdown cells are shared, and only those the notebook had when
// the room was started.
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

  // ── The notebook's side: markdown cells' texts, their commits, and who is in which cell ─────────
  const cells = () => ((window.__slateState || window.nbState || {}).cells) || [];
  const isProse = c => c && window.kindInfo && window.kindInfo(c.kind).prose;
  const srcEq = (a, b) => window.slateStore && window.slateStore.srcEq ? window.slateStore.srcEq(a, b) : a === b;
  const bindAll = () => document.dispatchEvent(new CustomEvent('slate:collab'));

  // Start the room from this notebook's markdown cells, unless someone already has.
  function seed() {
    if (!S || S.texts.size > 0) return;
    const { Y } = S.SY;
    S.doc.transact(() => {
      for (const c of cells()) {
        if (!isProse(c)) continue;
        S.texts.set(c.id, new Y.Text(c.source || ''));
        S.committed.set(c.id, c.source || '');
      }
    });
    bindAll();
    ui.render();
  }

  // Another's commit of cell `id`: committed here too, which renders it.
  async function applyCommit(id) {
    if (!S) return;
    const src = S.committed.get(id);
    if (typeof src !== 'string') return;
    if (!cells().some(c => c.id === id)) { console.warn('collab: no cell ' + id + ' here'); return; }
    if (srcEq(src, (window.srcMap || {})[id] || '')) return;
    window.srcMap[id] = src;
    try { window.applyAck && window.applyAck(await api('POST', '/api/cell/' + id, { source: src })); }
    catch (e) { console.warn('collab: could not commit ' + id, e); }
  }

  // Who is in which cell, on each cell's header.
  function markEditing() {
    document.querySelectorAll('.collab-who').forEach(el => el.remove());
    if (!S) return;
    const by = {};
    S.awareness.getStates().forEach((st, client) => {
      if (client === S.awareness.clientID || !st.cell || !st.user) return;
      (by[st.cell] = by[st.cell] || []).push(st.user);
    });
    for (const [id, users] of Object.entries(by)) {
      const head = document.querySelector('#cell-' + CSS.escape(id) + ' .cellhead');
      if (!head) continue;
      const span = document.createElement('span');
      span.className = 'collab-who';
      span.style.cssText = 'margin-left:8px;font-size:11px;opacity:.9';
      span.innerHTML = users.map(u => `<span style="color:${esc(u.color)}">✎ ${esc(u.name)}</span>`).join(' ');
      head.appendChild(span);
    }
  }

  // A markdown cell's editor, bound to the cell's shared text while in a room that shares it.
  const editorExtension = ctx => {
    if (!ctx || !ctx.markdown || !ctx.cellId || !window.CM6) return [];
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
        if (view.hasFocus) S.awareness.setLocalStateField('cell', id);   // focused before it was bound
      };
      const unbind = () => {
        if (!undo) return;
        try { view.dispatch({ effects: comp.reconfigure([]) }); } catch (_) {}
        undo.destroy(); undo = null;
      };
      const onSession = () => queueMicrotask(() => (S ? bind() : unbind()));
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
    if (!S || !e.detail || !S.texts.has(e.detail.id)) return;
    S.committed.set(e.detail.id, e.detail.source);
  });

  async function join({ kb, project, mode, start }) {
    if (S) leave();
    localStorage.setItem('slateCollab', JSON.stringify({ kb, project, mode }));
    ui.say('Asking ' + kb + ' for a ticket…');
    let t;
    try { t = await api('POST', '/api/collab/ticket', { kb, project }); }
    catch (e) { ui.say('The hub did not answer'); return; }
    if (!t.ok) { ui.say(t.error || 'No ticket', t.signin ? kb : null, !t.signin && (t.status === 401 || t.status === 403) ? { kb, project, mode, start } : null); return; }
    let SY;
    try { SY = await loadBundle(); } catch (e) { ui.say(String(e.message || e)); return; }
    const doc = new SY.Y.Doc();
    const awareness = new SY.awareness.Awareness(doc);
    const color = COLORS[doc.clientID % COLORS.length];
    awareness.setLocalStateField('user', { name: t.name || 'Someone', color, colorLight: color + '33' });
    S = { SY, doc, awareness, texts: doc.getMap('text'), committed: doc.getMap('committed'), bound: new Map(),
          kb, project, mode, room: t.room, name: t.name, started: Date.now() };
    S.provider = new Room(SY, { ws: t.ws, room: t.room, doc, awareness, mode, onChange: () => { markEditing(); ui.render(); } });
    S.committed.observe(ev => { if (!ev.transaction.local) for (const id of ev.keysChanged) applyCommit(id); });
    S.texts.observe(ev => { if (!ev.transaction.local) bindAll(); });
    if (start) setTimeout(seed, 1500);
    ui.say('');
    ui.render();
  }

  function leave() {
    if (!S) return;
    const s = S;
    S = null;
    bindAll();                         // editors let go of the shared texts
    s.provider.close();
    s.awareness.destroy();
    s.doc.destroy();
    markEditing();
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
          '<div style="margin-top:8px;display:flex;gap:6px"><button data-act="start" title="Share this notebook\'s markdown cells, as they are here">Start from this copy</button>' +
          '<button data-act="join" title="Take the room\'s cells, as whoever started it has them">Join</button></div>' + msg + signin;
      } else {
        const p = S.provider, states = S.awareness.getStates();
        const nameOf = peer => { for (const c of peer.clients) { const st = states.get(c); if (st && st.user) return st.user.name; } return peer.id; };
        const rows = [...p.peers.values()].map(peer => {
          const how = peer.state === 'direct' ? `direct ${peer.kind}${peer.rtt != null ? ' · ' + peer.rtt + ' ms' : ''}` : peer.state;
          return `<tr><td>${esc(nameOf(peer))}</td><td>${esc(how)}</td><td style="text-align:right">${peer.direct}/${peer.relayed}</td></tr>`;
        }).join('') || '<tr><td colspan="3" style="opacity:.7">Nobody else yet</td></tr>';
        el.innerHTML = head +
          `<div>${esc(S.room)} · ${esc(S.mode)} · signaling ${esc(p.sockState)}</div>` +
          `<div style="opacity:.8">You: ${esc(S.name || '')} · ${S.texts.size} shared cell(s)</div>` +
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
      join({ kb, project, mode, start: a === 'start' });
    },
  };
  window.openCollab = () => ui.open();
  window.slateCollab = { join, leave, get session() { return S; } };
})();
