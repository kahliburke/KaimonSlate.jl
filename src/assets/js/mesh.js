// ── Consent-gated region introduction (PEER_TUNNEL_PLAN §5.1) ────────────────────────────────────────
// When a region is added to this notebook (via the region picker OR an MCP `region_on`/tag) and it forms a
// cross-host pair that isn't meshed yet, the hub pushes a `mesh-consent:` SSE frame (panels.js →
// window.onMeshConsent); a tab that loaded AFTER the push picks the same payload up from GET
// /api/<nb>/mesh-consent below. We surface a popup that spells out EXACTLY what arming installs and where;
// only on the user's grant does POST /api/<nb>/mesh-introduce touch any ~/.ssh file. Declining routes
// cross-region transfers through the hub relay instead — correctness never needs the mesh, it's a speed path.
//
// Preact/ESM island (imported by app.js), same shape as health.js: an imperative SSE/fetch handler assigns
// a signal and the component follows. Uses window.api (core.js — already scopes to this notebook) and
// window.toast; repaints the DAG overlay via window._dagFetchRoutes after a successful arm.
import { html, render } from 'htm/preact';
import { signal, effect } from '@preact/signals';

const consent = signal(null);      // mesh_consent_status payload while the popup is up, else null
const busy = signal(false);        // true while arming (POST mesh-introduce in flight)

// ── styles (injected once so notebook.css stays untouched — same pattern as health.js) ──────────────────
const style = document.createElement('style');
style.textContent = `
  .meshbg{position:fixed;inset:0;z-index:120;display:flex;align-items:center;justify-content:center;
    background:rgba(6,8,14,.6);backdrop-filter:blur(2px);}
  .meshcard{width:min(560px,92vw);max-height:88vh;overflow:auto;background:#141828;border:1px solid #2a2e40;
    border-radius:14px;box-shadow:0 18px 54px rgba(0,0,0,.55);padding:18px 20px;color:#d4d8e8;}
  .meshcard h3{margin:0 0 4px;font-size:1.02rem;color:#eef1fb;display:flex;align-items:center;gap:8px;}
  .meshcard h3 .meshicon{color:#7cc0ff;}
  .meshcard .meshp{font-size:.82rem;line-height:1.45;color:#c2c8dc;margin:6px 0 10px;}
  .meshcard .meshsec{font-size:.66rem;text-transform:uppercase;letter-spacing:.05em;color:#8a90a8;margin:12px 0 4px;}
  .meshpairs{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:5px;}
  .meshpairs li{background:#1b2133;border:1px solid #2a3047;border-radius:8px;padding:7px 10px;font-size:.86rem;}
  .meshpairs b{color:#eef1fb;font-weight:600;}
  .meshhost{color:#8a90a8;font-size:.74rem;font-family:Menlo,monospace;}
  .meshamp{color:#7cc0ff;margin:0 6px;}
  .meshinstalls{margin:0;padding-left:18px;display:flex;flex-direction:column;gap:3px;font-size:.8rem;line-height:1.4;color:#c2c8dc;}
  .meshinstalls b{color:#dfe4f2;font-weight:600;}
  .meshwarn{margin:10px 0 0;font-size:.78rem;color:#e8a13f;background:rgba(232,161,63,.1);
    border:1px solid rgba(232,161,63,.28);border-radius:8px;padding:7px 10px;}
  .meshdim{font-size:.76rem;color:#7a8098;line-height:1.4;margin:12px 0 0;}
  .meshacts{display:flex;justify-content:flex-end;gap:9px;margin-top:16px;}
  .meshbtn{font-size:.82rem;padding:7px 15px;border-radius:9px;cursor:pointer;border:1px solid #2f3550;
    background:#1c2136;color:#c6ccdd;}
  .meshbtn:hover{background:#242a44;}
  .meshbtn.primary{background:#2b6cff;border-color:#2b6cff;color:#fff;font-weight:600;}
  .meshbtn.primary:hover{background:#3a79ff;}
  .meshbtn[disabled]{opacity:.55;cursor:default;}
  .meshspin{display:inline-block;width:12px;height:12px;border:2px solid rgba(255,255,255,.4);
    border-top-color:#fff;border-radius:50%;animation:meshspin .7s linear infinite;vertical-align:-2px;margin-right:6px;}
  @keyframes meshspin{to{transform:rotate(360deg);}}`;
document.head.appendChild(style);

// Ordered source→puller pairs → unordered "A ↔ B" rows, one per host-pair.
function pairRows(pairs) {
  const seen = new Set(), rows = [];
  for (const p of (pairs || [])) {
    const key = [p.source, p.puller].sort().join(' ');
    if (seen.has(key)) continue; seen.add(key);
    rows.push(p);
  }
  return rows;
}

async function arm() {
  if (busy.value) return;
  busy.value = true;
  try {
    const r = await window.api('POST', '/api/mesh-introduce', {});
    if (r && r.ok) {
      window.toast && window.toast(`Regions connected — ${r.installed || 0} grant${r.installed === 1 ? '' : 's'} installed`, 4500, 'ok');
      consent.value = null;
      try { window._dagFetchRoutes && window._dagFetchRoutes(); } catch (_) {}   // repaint the overlay verdicts
    } else {
      window.toast && window.toast('Could not connect the regions: ' + ((r && r.error) || 'unknown error'), 7000, 'err');
    }
  } catch (_) {
    window.toast && window.toast('Could not reach the hub to connect the regions.', 6000, 'err');
  } finally { busy.value = false; }
}

async function dismiss() {
  const c = consent.value; consent.value = null;
  if (c) { try { await window.api('POST', '/api/mesh-dismiss', {}); } catch (_) {} }
}

function MeshConsent() {
  const c = consent.value;
  if (!c || c.connected || !(c.pairs && c.pairs.length)) return null;
  const rows = pairRows(c.pairs), unreachable = (c.unreachable || []).filter(Boolean);
  const b = busy.value;
  // Backdrop click / Escape = "decide later" (no dismiss persisted; re-offers on reload). The buttons act.
  const onBg = e => { if (e.target === e.currentTarget && !b) consent.value = null; };
  return html`<div class="meshbg" onClick=${onBg}>
    <div class="meshcard" role="dialog" aria-modal="true">
      <h3><span class="meshicon">⇄</span> Connect these regions for direct transfer?</h3>
      <p class="meshp">They run on different hosts. To move boundary values worker&#8209;to&#8209;worker over an
        SSH&#8209;bridged link — instead of relaying every byte through this hub — Slate needs to exchange keys between them:</p>
      <ul class="meshpairs">${rows.map(p => html`<li>
        <b>${p.source}</b> <span class="meshhost">${p.source_host}</span>
        <span class="meshamp">↔</span>
        <b>${p.puller}</b> <span class="meshhost">${p.puller_host}</span></li>`)}</ul>
      <div class="meshsec">What this installs</div>
      <ul class="meshinstalls">
        <li>an <b>ed25519 key</b> on each host — the private half is generated on&#8209;host and never leaves it</li>
        <li>a locked&#8209;down <b>grant</b> on the source authorizing a forward to <b>only</b> its blob port — no shell, no other ports</li>
        <li>a <b>host&#8209;key pin</b> so the bridge never trusts a host on first sight</li>
      </ul>
      ${unreachable.length ? html`<div class="meshwarn">⚠ currently unreachable over SSH: ${unreachable.join(', ')} — arming will fail until it's back.</div>` : null}
      <p class="meshdim">Decline and transfers still work — they route through the hub relay, just slower. You can
        connect later from the DAG's <b>⇄ peer routing plan</b>.</p>
      <div class="meshacts">
        <button class="meshbtn" disabled=${b} onClick=${dismiss}>Not now</button>
        <button class="meshbtn primary" disabled=${b} onClick=${arm}>${b ? html`<span class="meshspin"></span>Connecting…` : 'Connect & exchange keys'}</button>
      </div>
    </div></div>`;
}

// Mount into a body-appended host (no notebook.html change needed for the overlay node).
const host = document.createElement('div');
host.id = 'meshconsentbg';
document.body.appendChild(host);
render(html`<${MeshConsent} />`, host);

// Escape closes (decide later) — only while the popup is up and not mid-arm.
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && consent.value && !busy.value) { e.stopPropagation(); consent.value = null; }
}, true);

// Live push from the hub (panels.js SSE dispatch).
window.onMeshConsent = status => { consent.value = status; };

// A tab that loaded AFTER the hub raised a pending consent (missed the live SSE) still shows it.
setTimeout(async () => {
  try {
    const d = await window.api('GET', '/api/mesh-consent');
    if (d && d.pending) consent.value = d;
  } catch (_) {}
}, 800);
