// Doc asset generator — headless screenshots + webm clips of the live Slate web UI.
//
// Boots ONE standalone Slate hub (`serve_notebook`, in-process kernel — no Kaimon, no gate worker),
// opens several curated demo notebooks (the first via serve_notebook, the rest via POST /api/open),
// drives the UI, and writes PNGs + WEBMs into docs/src/assets/. CI (.github/workflows/Docs.yml) runs
// this after `npx playwright install chromium`, uploads the media to the docs-assets GitHub Release,
// and the docs build consumes it via KAIMONSLATE_ASSET_BASE. Run locally:  node docs/generate_assets.mjs
//
// Curated notebooks (docs/screenshots/*.jl) use only Base + Slate's injected helpers (@bind, echart,
// slate_table), so the whole thing is reproducible in CI with no extra packages. Captures that need
// Kaimon (the agent pane, the Packages panel) are intentionally omitted.

import { chromium } from 'playwright'
import { spawn } from 'node:child_process'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const DOCS = dirname(fileURLToPath(import.meta.url))
const REPO = dirname(DOCS)
const OUT = join(DOCS, 'src', 'assets')
const SHOTDIR = join(DOCS, 'screenshots')
const PORT = Number(process.env.SLATE_DOCS_PORT || 8799)
const BASE = `http://127.0.0.1:${PORT}`
const SCALE = 2
const FIRST = 'demo'                                          // serve_notebook opens this one
const EXTRA = ['widgets', 'charts', 'anim', 'docs', 'tables'] // opened over /api/open

mkdirSync(OUT, { recursive: true })
const VIDTMP = mkdtempSync(join(tmpdir(), 'slate-vid-'))

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const log = (...a) => console.log('[assets]', ...a)

// Fetch with retry. `POST /api/open` runs a notebook synchronously (holding the hub lock), so
// the server can be mid-compile when the next request lands; undici also reuses the keep-alive
// socket from an earlier request, which the server may reset — surfacing as ECONNRESET. Force a
// fresh connection (Connection: close) and back off a few times before giving up.
async function fetchRetry(url, opts = {}, tries = 5) {
  const headers = { ...(opts.headers || {}), Connection: 'close' }
  for (let i = 0; i < tries; i++) {
    try { return await fetch(url, { ...opts, headers }) }
    catch (e) {
      if (i === tries - 1) throw e
      log(`fetch ${url} failed (${e.cause?.code || e.message.split('\n')[0]}), retry ${i + 1}/${tries - 1}`)
      await sleep(1000 * (i + 1))
    }
  }
}

// Static per-cell screenshots: { notebookId: { cellId: filename } }.
const CELL_SHOTS = {
  demo: { highlight: 'editor-highlighting.png', chart: 'chart.png', table: 'table.png',
          boom: 'error.png', mdinterp: 'markdown.png' },
  widgets: Object.fromEntries(['slider', 'numberfield', 'checkbox', 'toggle', 'textfield', 'textarea',
    'select', 'radio', 'multiselect', 'multicheckbox', 'colorpicker', 'datefield', 'timefield', 'button']
    .map((w) => [w, `widget-${w}.png`])),
  charts: Object.fromEntries(['line', 'bar', 'area', 'scatter', 'pie', 'heatmap', 'candlestick',
    'radar', 'boxplot', 'composable'].map((c) => [c, `chart-${c}.png`])),
  anim: { anim: 'animate.png' },                 // the WebGL animation player (heatmap frames)
  docs: { bib: 'references-card.png' },          // the bibliography cell → live references card
  tables: { formatted: 'table-formatted.png' },  // formatting + in-cell bar/heat viz
}

// ── server ──────────────────────────────────────────────────────────────────────────────────
function startServer() {
  log(`starting serve_notebook on :${PORT}`)
  const jl = `using KaimonSlate; KaimonSlate.serve_notebook(raw"${join(SHOTDIR, FIRST + '.jl')}"; port=${PORT})`
  const proc = spawn('julia', [`--project=${DOCS}`, '--color=no', '-e', jl], { cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'] })
  proc.stdout.on('data', (d) => process.stdout.write(`[server] ${d}`))
  proc.stderr.on('data', (d) => process.stderr.write(`[server] ${d}`))
  return proc
}
async function waitForServer(timeoutMs = 180_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try { if ((await fetch(`${BASE}/n/${FIRST}`, { headers: { Connection: 'close' } })).ok) { log('server up'); return } } catch (_) {}
    await sleep(1000)
  }
  throw new Error('server did not come up')
}
async function openExtra() {
  for (const id of EXTRA) {
    // Tolerate a single bad open: skip that notebook's shots rather than aborting the whole run.
    try {
      await fetchRetry(`${BASE}/api/open`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: join(SHOTDIR, id + '.jl') }) })
      log(`opened ${id}`)
    } catch (e) { log(`! open ${id} failed: ${e.cause?.code || e.message.split('\n')[0]}`) }
  }
}

// ── page helpers ────────────────────────────────────────────────────────────────────────────
async function newContext(browser, opts = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, deviceScaleFactor: SCALE, colorScheme: 'dark', ...opts })
  await ctx.addInitScript(() => { try { localStorage.setItem('slateTheme', 'dark'); localStorage.setItem('slateSyntaxTheme', 'dark-plus') } catch (_) {} })
  return ctx
}
// Open a notebook, run every cell, settle, and hide the standalone-only world-age .warn block.
async function runNotebook(page, id) {
  await page.goto(`${BASE}/n/${id}`, { waitUntil: 'domcontentloaded' })   // NOT networkidle: SSE stays open
  await page.waitForSelector('.cell', { timeout: 30_000 })
  const nbid = await page.evaluate(() => window.NB_ID)
  await page.evaluate(async (nbid) => { try { await fetch(`/api/${nbid}/rerun-all`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }) } catch (_) {} }, nbid)
  await page.waitForFunction(() => {
    const cs = (window.__slateState && window.__slateState.cells) || []
    return cs.length > 0 && cs.every((c) => c.state !== 'running' && c.state !== 'stale')
  }, { timeout: 90_000 }).catch(() => {})
  // Hide the standalone-only world-age .warn block, and the fixed bottom-right Docs launcher
  // (it's clutter in shots and Playwright pins it mid-image on full-page captures).
  await page.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
  await sleep(1400)
}
async function cellShot(page, cid, name) {
  const loc = page.locator(`.cell[data-cid="${cid}"]`)
  if (!(await loc.count())) { log(`! missing cell ${cid} (${name})`); return }
  await loc.screenshot({ path: join(OUT, name) })
  log(`✓ ${name}`)
}
async function elShot(page, selector, name) {
  const loc = page.locator(selector).first()
  try { await loc.waitFor({ state: 'visible', timeout: 8000 }); await loc.screenshot({ path: join(OUT, name) }); log(`✓ ${name}`) }
  catch (e) { log(`! ${name} skipped: ${e.message.split('\n')[0]}`) }
}
// Capture a full-height side panel (position:fixed, height:100vh) cropped to its CONTENT — the
// panels otherwise screenshot a tall column of blank space below the rows. Temporarily collapse the
// fixed height (and any flex:1 growable middle, e.g. the agent transcript) so the element's box
// shrinks to its content, screenshot, then restore. `growSel` is the inner element to un-grow.
async function panelShot(page, selector, name, growSel = null) {
  await page.evaluate(({ selector, growSel }) => {
    const el = document.querySelector(selector); if (!el) return
    el.dataset._h = el.style.height; el.dataset._mh = el.style.maxHeight
    el.style.height = 'auto'; el.style.maxHeight = 'none'
    if (growSel) { const g = el.querySelector(growSel); if (g) { g.dataset._f = g.style.flex; g.style.flex = '0 0 auto' } }
  }, { selector, growSel })
  await sleep(250)
  await elShot(page, selector, name)
  await page.evaluate(({ selector, growSel }) => {
    const el = document.querySelector(selector); if (!el) return
    el.style.height = el.dataset._h || ''; el.style.maxHeight = el.dataset._mh || ''
    if (growSel) { const g = el.querySelector(growSel); if (g) g.style.flex = g.dataset._f || '' }
  }, { selector, growSel })
}
// Screenshot an on-screen element CROPPED to its content (its top-left down to `bottomSel`'s
// bottom + pad). Used for the fixed/transform side panels (agent/packages) where panelShot's
// height:auto trick mis-crops into an off-screen capture; a plain clip is robust.
async function shotCropped(page, sel, name, bottomSel = null, pad = 16) {
  try {
    const clip = await page.evaluate(({ sel, bottomSel, pad }) => {
      const el = document.querySelector(sel); if (!el) return null
      const r = el.getBoundingClientRect()
      const b = bottomSel ? el.querySelector(bottomSel) : null
      const bottom = b ? b.getBoundingClientRect().bottom : r.bottom
      return { x: Math.max(0, Math.floor(r.x)), y: Math.max(0, Math.floor(r.y)),
               width: Math.ceil(r.width), height: Math.ceil(bottom - r.y + pad) }
    }, { sel, bottomSel, pad })
    if (!clip) { log(`! ${name} skipped: no ${sel}`); return }
    await page.screenshot({ path: join(OUT, name), clip }); log(`✓ ${name}`)
  } catch (e) { log(`! ${name} skipped: ${e.message.split('\n')[0]}`) }
}
// Synthetic publish ledger — clean demo content in the REAL JSON shape, so the publishing UI
// (manager dashboard, Sites strip, Publish panel) renders without any real targets/sites/secrets.
// Wire it with `mockPublish(page)` BEFORE navigating (route interception + /api/sites).
const PUB_LEDGER = {
  backend: 'gist', ghUser: 'ada',
  availableKinds: ['github-pages', 'cloudflare-pages', 'netlify', 's3', 'r2', 'rsync', 'zenodo'],
  documents: [], secretRefs: ['cloudflare-token', 'netlify-token', 'zenodo-token'],
  sites: [{ name: 'portfolio', hasHome: true, homeTitle: "Ada's Notebooks", targets: ['pages', 'cloudflare'],
    docs: [
      { slug: '', title: "Ada's Notebooks", description: 'Reactive Julia notebooks on numerical methods.', date: '2026-07-01', image: '', runnable: false, section: '', order: 0 },
      { slug: 'gram-schmidt', title: 'Gram–Schmidt, visualized', description: 'Orthogonalizing a basis, one projection at a time.', date: '2026-07-02', image: '', runnable: true, section: '', order: 1 },
      { slug: 'fft', title: 'FFT from scratch', description: 'A radix-2 transform, built up and benchmarked.', date: '2026-07-03', image: '', runnable: true, section: '', order: 2 },
      { slug: 'heat', title: 'The heat equation', description: 'Spectral vs finite-difference, side by side.', date: '2026-07-05', image: '', runnable: false, section: '', order: 3 },
    ] }],
  targets: [
    { name: 'pages', kind: 'github-pages', config: { repo: 'ada/notebooks', url: 'https://ada.github.io/notebooks/' } },
    { name: 'cloudflare', kind: 'cloudflare-pages', config: { project: 'ada-notebooks', accountId: '', secretRef: 'cloudflare-token', url: 'https://ada-notebooks.pages.dev/' } },
    { name: 'zenodo', kind: 'zenodo', config: { secretRef: 'zenodo-token' } },
  ],
}
async function mockPublish(page) {
  await page.route('**/api/publish/ledger*', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify(PUB_LEDGER) }))
  await page.route('**/api/sites', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ sites: ['portfolio'] }) }))
}

// ── regions / remotes (synthetic — no real hosts spawn) ───────────────────────────────────────
// A coherent fake fleet in the REAL JSON shapes, so every region/DAG/mesh surface renders clean
// demo content without provisioning a single remote worker. Two hosts, two regions: `gpu` (a warm
// pool over an ssh tunnel) and `db` (a direct·CURVE box). Stats that ride worker/roster objects are
// JSON *strings* (as the wire delivers them); cell stats are plain objects. `mb` = 2^20.
const MB = 1048576
const mkStats = (o) => JSON.stringify(o)
// Front-page registry (/api/regions) + Remotes-modal / activity-monitor / focus-view.
const REG_REGISTRY = {
  regions: [
    { name: 'gpu', host: 'gpu-box', transport: 'tunnel', base_port: 0, preload: '~/proj/vision', data_root: '/data/gpu',
      warm: 2, threads: '8,1', sysimage: true, status: { ok: true, msg: 'warm 2/2 ready', age: 7 } },
    { name: 'db', host: 'db-box', transport: 'direct', base_port: 9200, preload: '', data_root: '/srv/warehouse',
      warm: 1, threads: '4,1', sysimage: false, status: { ok: true, msg: 'warm 1/1 ready', age: 12 } },
  ],
  parked: [{ host: 'gpu-box', label: 'vision', port: 9312, idle_s: 43 }],
}
// Per-host live rosters (/api/remote-workers?host=). state ∈ attached|idle; stats/manifest are JSON strings.
const REG_ROSTERS = {
  'gpu-box': [
    { port: 9300, alive: true, state: 'attached', manifest: mkStats({ region: 'gpu', notebook: 'pipeline.jl', transport: 'tunnel', project: 'vision', spawned: 'attached · 6m', stream_port: 9301 }),
      stats: mkStats({ cpu: 78, rss: 940 * MB, memo_bytes: 512 * MB, running: ['train'], warm: 'ready · CUDA', sys_cpu: 61, load1: 3.2, sys_mem_total: 64000 * MB, sys_mem_free: 21000 * MB }) },
    { port: 9312, alive: true, state: 'idle', manifest: mkStats({ region: 'gpu', notebook: '', transport: 'tunnel', project: 'vision', spawned: 'warm · 43s idle', stream_port: 9313 }),
      stats: mkStats({ cpu: 2, rss: 260 * MB, memo_bytes: 0, running: [], warm: 'ready · CUDA', sys_cpu: 61, load1: 3.2 }) },
  ],
  'db-box': [
    { port: 9200, alive: true, state: 'attached', manifest: mkStats({ region: 'db', notebook: 'pipeline.jl', transport: 'direct', project: 'warehouse', spawned: 'attached · 6m', stream_port: 9201 }),
      stats: mkStats({ cpu: 33, rss: 1800 * MB, memo_bytes: 3400 * MB, running: [], warm: 'ready', sys_cpu: 22, load1: 1.1, sys_mem_total: 128000 * MB, sys_mem_free: 96000 * MB }) },
  ],
}
// Telemetry ring for the worker-detail sparklines (/api/worker-stats). A gentle synthetic wobble.
function regStatsHistory(port) {
  const base = port === 9300 ? 76 : port === 9200 ? 31 : 3
  const rssB = port === 9300 ? 940 : port === 9200 ? 1800 : 260
  const now = Math.floor(Date.now() / 1000)
  return Array.from({ length: 40 }, (_, i) => ({ t: now - (40 - i) * 3,
    cpu: Math.max(0, Math.round(base + 14 * Math.sin(i / 3) + (i % 5))),
    rss: Math.round((rssB + 30 * Math.sin(i / 4)) * MB) }))
}
// /api/{id}/peer-plan — resolved routes + host grants + live/recent boundary transfers.
const REG_PEERPLAN = {
  regions: ['gpu', 'db'], refreshed: true,
  // Region↔region peer routes resolve to a direct/ssh path; local↔region edges have no peer route
  // (the main kernel relays through the hub), so they read as `unresolved` on the map until a transfer
  // probes them — authentic behaviour, not faked away.
  routes: [
    { src: 'db', dst: 'gpu', kind: 'direct', addr: 'gpu-box:9302', age_s: 4 },
    { src: 'gpu', dst: 'db', kind: 'ssh', addr: 'db-box:9200', age_s: 4 },
    { src: 'local', dst: 'db', kind: 'relay', addr: 'hub', age_s: 9 },
  ],
  hosts: [
    { host: 'gpu-box', reachable: true, grants: [{ puller: 'db', source: 'gpu', port: 9302, placeholder: false }], pins: [{ source: 'gpu', addrs: ['gpu-box:9302'] }] },
    { host: 'db-box', reachable: true, grants: [{ puller: 'gpu', source: 'db', port: 9200, placeholder: false }], pins: [{ source: 'db', addrs: ['db-box:9200'] }] },
  ],
  transfers: [{ src: 'db', dst: 'gpu', name: 'feat', via: 'direct', done: 147 * MB, total: 210 * MB, active: true, err: '', mbps: 92.4 }],
}
// /api/{id}/transfer-stats — retained per-transfer (t, cumulative-bytes) traces for the dashboard.
function regTransferStats() {
  const now = Math.floor(Date.now() / 1000)
  const trace = (src, dst, name, via, dur, total, ago) => {
    const started = now - ago, n = 8
    const ts = Array.from({ length: n }, (_, i) => started + (dur * i) / (n - 1))
    const bs = Array.from({ length: n }, (_, i) => Math.round((total * i) / (n - 1)))
    return { src, dst, name, via, started, finished: started + dur, total, err: '', ts, bs }
  }
  return { now, traces: [
    trace('db', 'gpu', 'feat', 'direct', 3.1, 210 * MB, 30),
    trace('local', 'db', 'df', 'ssh', 1.4, 38 * MB, 55),
    trace('gpu', 'local', 'model', 'direct', 2.2, 96 * MB, 12),
    trace('db', 'gpu', 'weights', 'direct', 0.9, 44 * MB, 5),
  ] }
}
// Worker-log tail for the topbar pill popup (/api/{id}/worker-log?side=).
const REG_WORKER_LOG = [
  '[gate] worker gpu-box:9300 attached (adopted warm · 0.9s)',
  '[boot] sync_memo: 12 blobs deduped, 3 carried (512 MB)',
  '[eval] train ▶ running — CUDA device 0, batch 256',
  '[xfer] ⇄ feat: 210/210 MB ← db (direct, 92 MB/s)',
  '[telemetry] cpu 78% · rss 940 MB · 1 running',
].join('\n')
// Preflight SSE (/api/preflight-stream) — a canned "Test & prime" checklist. All events at once is
// fine: the client fills the list as it parses them.
function regPreflightSSE(host) {
  const step = (name, status, detail, ms) => `event: step\ndata: ${JSON.stringify({ name, status, detail, ms })}\n\n`
  return [
    step('SSH reachable', 'ok', `${host} · key auth`, 210),
    step('Julia present', 'ok', 'v1.12.0', 180),
    step('Environment', 'ok', 'provisioned · gate loaded', 4200),
    step('CURVE key', 'ok', 'server key pinned', 40),
    step('Spawn + connect', 'ok', 'worker :9300 · round-trip 1+1', 2600),
    step('Teardown', 'ok', 'clean', 120),
    `event: done\ndata: ${JSON.stringify({ ok: true, host, transport: 'tunnel' })}\n\n`,
  ].join('')
}
// Install every region/remote route interceptor on a page BEFORE navigating.
async function mockRegions(page) {
  const J = (o) => ({ contentType: 'application/json', body: JSON.stringify(o) })
  await page.route('**/api/regions', (r) => r.request().method() === 'GET' ? r.fulfill(J(REG_REGISTRY)) : r.continue())
  await page.route('**/api/remote-workers*', (r) => {
    const host = new URL(r.request().url()).searchParams.get('host') || ''
    r.fulfill(J({ host, workers: REG_ROSTERS[host] || [] }))
  })
  await page.route('**/api/worker-stats*', (r) => {
    const port = Number(new URL(r.request().url()).searchParams.get('port'))
    r.fulfill(J({ ok: true, port, samples: regStatsHistory(port) }))
  })
  await page.route('**/api/ssh-hosts', (r) => r.fulfill(J({ hosts: ['gpu-box', 'db-box', 'workstation'], global: '' })))
  await page.route('**/api/sysimage*', (r) => {
    const region = new URL(r.request().url()).searchParams.get('region') || ''
    r.fulfill(J({ ok: true, building: false, current: region === 'gpu', stale: false, bytes: 1780 * MB,
      built: 'built · 2h ago', compiler: true, host: region === 'gpu' ? 'gpu-box' : 'db-box', reachable: true }))
  })
  await page.route('**/peer-plan*', (r) => r.fulfill(J(REG_PEERPLAN)))
  await page.route('**/transfer-stats*', (r) => r.fulfill(J(regTransferStats())))
  await page.route('**/worker-log*', (r) => r.fulfill(J({ side: new URL(r.request().url()).searchParams.get('side') || '',
    host: 'gpu-box', port: 9300, connected: true, status: 'ok', note: '',
    stats: mkStats({ cpu: 78, rss: 940 * MB, evals: 1, memo: 512 * MB, running: ['train'] }), log: REG_WORKER_LOG })))
  await page.route('**/api/preflight-stream*', (r) => {
    const host = new URL(r.request().url()).searchParams.get('host') || 'gpu-box'
    r.fulfill({ contentType: 'text/event-stream', body: regPreflightSSE(host) })
  })
}
// Fake notebook state for the DAG region overlay: a 5-cell model pipeline split local→db→gpu, with
// declared regions + live workers. `renderAll(this)` publishes it; the real renderers draw the zones,
// region-map coloring, pills, and provenance from it.
const REG_NBSTATE = {
  title: 'pipeline', path: '/pipeline.jl', version: 3, hydrating: false,
  worker: { kind: 'gate', connected: true, port: 9100 }, runLocation: 'local',
  regions: [
    { name: 'gpu', host: 'gpu-box', transport: 'tunnel', warm: 2, base_port: 0, data_root: '/data/gpu', preload: '~/proj/vision', sysimage: true, defined: true, status: { ok: true, msg: 'ready' } },
    { name: 'db', host: 'db-box', transport: 'direct', warm: 1, base_port: 9200, data_root: '/srv/warehouse', preload: '', sysimage: false, defined: true, status: { ok: true, msg: 'ready' } },
  ],
  workers: [
    { side: '', host: '', port: 9100, status: 'ok', connected: true, transport: 'local', note: '', stats: mkStats({ cpu: 12, rss: 280 * MB, evals: 0 }) },
    { side: 'gpu', host: 'gpu-box', port: 9300, stream_port: 9301, status: 'ok', connected: true, transport: 'tunnel', note: '', stats: mkStats({ cpu: 78, rss: 940 * MB, evals: 1, running: ['train'], warm: 'ready · CUDA', memo: 512 * MB }) },
    { side: 'db', host: 'db-box', port: 9200, stream_port: 9201, status: 'ok', connected: true, transport: 'direct', note: '', stats: mkStats({ cpu: 33, rss: 1800 * MB, evals: 0, warm: 'ready', memo: 3400 * MB }) },
  ],
  cells: [
    { id: 'intro', kind: 'markdown', state: 'fresh', source: '# Model pipeline\nLocal ingest, features on the warehouse, training on the GPU box.', deps: [], needs: [], defs: [], tags: [] },
    { id: 'load', kind: 'code', state: 'fresh', source: 'df = load_frame("events.parquet")', deps: [], needs: [], defs: ['df'], tags: [], stats: { ranOn: 'local', total_ms: 340, last_ms: 340, evals: 1 } },
    { id: 'features', kind: 'code', state: 'fresh', source: 'feat = build_features(df)', deps: ['load'], needs: [], defs: ['feat'], tags: ['region=db'], stats: { ranOn: 'db (db-box)', total_ms: 2100, last_ms: 2100, evals: 1 } },
    { id: 'train', kind: 'code', state: 'running', source: 'model = train(feat; epochs=40)', deps: ['features'], needs: [], defs: ['model'], tags: ['region=gpu'], stats: { ranOn: 'gpu (gpu-box)', total_ms: 54000, last_ms: 54000, evals: 1 } },
    { id: 'evaluate', kind: 'code', state: 'stale', source: 'score = evaluate(model, df)', deps: ['train', 'load'], needs: [], defs: ['score'], tags: ['region=gpu'], stats: { ranOn: 'gpu (gpu-box)' } },
    { id: 'report', kind: 'code', state: 'fresh', source: 'summarize(score)', deps: ['evaluate'], needs: [], defs: [], tags: [], stats: { ranOn: 'local', total_ms: 90, last_ms: 90, evals: 1 } },
  ],
  multidefCells: {}, backrefCells: {},
}

// ── regions / DAG / mesh captures ─────────────────────────────────────────────────────────────
// All synthetic: inject a region-split notebook state and mock the region/remote endpoints, then let
// the REAL renderers draw. No worker ever spawns. Each capture is best-effort (skip-and-log), like
// the rest of this file.
async function regionShots(browser) {
  // ── notebook-page surfaces (DAG overlay, peer plan, transfers, worker log, mesh consent) ──────
  try {
    const page = await (await newContext(browser)).newPage()
    await mockRegions(page)
    await page.goto(`${BASE}/n/demo`, { waitUntil: 'domcontentloaded' })
    await page.waitForSelector('.cell', { timeout: 30_000 })
    await page.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
    // Publish the fake region-split state through the real pipeline, open the DAG, turn on the region map.
    await page.evaluate((st) => { window.renderAll(st) }, REG_NBSTATE)
    await sleep(500)
    await page.evaluate(() => { if (!document.getElementById('dagpane').classList.contains('open')) window.toggleDag() })
    await page.waitForSelector('#dagcanvas', { timeout: 8000 }).catch(() => {})
    await page.evaluate(() => { if (typeof window.dagRegions === 'function' && !window._dagRegionsOn) window.dagRegions() })
    await sleep(1400)                                        // dagre + region partition settle
    await elShot(page, '#dagpane', 'dag-region-map.png')

    // peer-plan panel (⇄ peer plan) — resolved routes + host grants
    try {
      await page.evaluate(() => window._dagPeerPlan && window._dagPeerPlan(false))
      await page.waitForSelector('#dagpeerpanel .dagpeerbody', { timeout: 6000 })
      await sleep(700)
      await elShot(page, '#dagpeerpanel', 'dag-peer-plan.png')
      await page.evaluate(() => document.getElementById('dagpeerpanel')?.remove())
    } catch (e) { log('! dag-peer-plan skipped:', e.message.split('\n')[0]) }

    // live transfers dashboard (📊 transfers)
    try {
      await page.evaluate(() => window._dagXferDash && window._dagXferDash())
      await page.waitForSelector('#dagxferdash', { timeout: 6000 })
      await sleep(1200)                                      // let the three ECharts lay out
      await elShot(page, '#dagxferdash', 'dag-transfers.png')
      await page.evaluate(() => document.getElementById('dagxferdash')?.remove())
    } catch (e) { log('! dag-transfers skipped:', e.message.split('\n')[0]) }

    // worker/region pills (topbar) + worker-log popup (pill → streamed log + telemetry)
    try {
      await elShot(page, '#workerpills', 'worker-pills.png')
      await page.evaluate(() => window.openWorkerPop && window.openWorkerPop('gpu'))
      await page.waitForSelector('#workerpop-log', { timeout: 6000 })
      await sleep(800)                                        // let the mocked log tail render
      await elShot(page, '#workerpopbg', 'worker-log.png')
      await page.evaluate(() => window.closeWorkerPop && window.closeWorkerPop())
    } catch (e) { log('! worker-log skipped:', e.message.split('\n')[0]) }

    // mesh consent popup — injected straight through its handler (app.js loads mesh.js). The host div
    // stays 0-size until the dialog renders, so wait on the card itself.
    try {
      await page.evaluate(() => window.onMeshConsent && window.onMeshConsent({
        connected: false, pending: true,
        pairs: [{ source: 'gpu', puller: 'db', source_host: 'gpu-box', puller_host: 'db-box' },
                { source: 'db', puller: 'gpu', source_host: 'db-box', puller_host: 'gpu-box' }],
        unreachable: [],
      }))
      await page.waitForSelector('.meshcard', { timeout: 5000 })
      await sleep(500)
      await elShot(page, '.meshcard', 'mesh-consent.png')
      await page.evaluate(() => window.onMeshConsent && window.onMeshConsent({ connected: true, pairs: [] }))
    } catch (e) { log('! mesh-consent skipped:', e.message.split('\n')[0]) }
    await page.context().close()
  } catch (e) { log('! notebook region shots skipped:', e.message.split('\n')[0]) }

  // ── home-page surfaces (Remotes modal, region focus, activity strip, preflight, worker detail) ─
  try {
    const page = await (await newContext(browser)).newPage()
    await mockRegions(page)
    await page.goto(`${BASE}/`, { waitUntil: 'domcontentloaded' })
    await sleep(1800)                                        // let the activity monitor poll /api/regions
    await elShot(page, '#actmon', 'remote-activity.png')

    // worker-detail popup — click a worker row (opens the CPU/RSS history popup)
    try {
      await page.locator('#actmon .actrow').first().click({ timeout: 3000 })
      await page.waitForSelector('.wdhead', { timeout: 5000 })
      await sleep(700)                                        // let the sparklines lay out
      await page.evaluate(() => { const e = document.querySelector('.wdhead'); if (e && e.parentElement) e.parentElement.id = '__wdpop' })
      await elShot(page, '#__wdpop', 'worker-detail.png')
      await page.keyboard.press('Escape')
    } catch (e) { log('! worker-detail skipped:', e.message.split('\n')[0]) }

    // Remotes modal — 🖧 Remotes
    try {
      await page.evaluate(() => { const b = document.getElementById('remotesbtn'); if (b) b.click() })
      await page.waitForSelector('#remotesbg', { timeout: 6000 })
      await sleep(900)
      await elShot(page, '#remotesbg .rtmodal, #remotesbg > div', 'remotes-modal.png')

      // preflight checklist — fill a host, then drive Test & prime (mocked SSE fills the step rows)
      try {
        await page.fill('#rthost', 'gpu-box')
        await page.getByText('Test & prime', { exact: false }).first().click({ timeout: 3000 })
        await page.waitForSelector('#remotesbg .rtstep', { timeout: 6000 })
        await sleep(900)
        await elShot(page, '#remotesbg .rtmodal, #remotesbg > div', 'preflight-checklist.png')
      } catch (e) { log('! preflight-checklist skipped:', e.message.split('\n')[0]) }

      // region focus view — open a host's regions
      try {
        await page.getByText('Regions', { exact: false }).first().click({ timeout: 3000 })
        await page.waitForSelector('#remotesbg .rtfocus', { timeout: 6000 })
        await sleep(900)
        await elShot(page, '#remotesbg .rtfocus, #remotesbg > div', 'region-focus.png')
      } catch (e) { log('! region-focus skipped:', e.message.split('\n')[0]) }
    } catch (e) { log('! remotes-modal skipped:', e.message.split('\n')[0]) }
    await page.context().close()
  } catch (e) { log('! home region shots skipped:', e.message.split('\n')[0]) }
}

async function main() {
  const server = startServer()
  let browser
  const cleanup = () => { try { browser?.close() } catch (_) {} ; try { server.kill('SIGTERM') } catch (_) {} }
  process.on('exit', cleanup); process.on('SIGINT', () => { cleanup(); process.exit(1) })
  try {
    await waitForServer()
    await openExtra()
    browser = await chromium.launch({ headless: true })

    // SLATE_REGION_ONLY=1 captures just the region/DAG/mesh shots (fast iteration on those alone).
    if (process.env.SLATE_REGION_ONLY === '1') { await regionShots(browser); log('done (region-only) — assets in', OUT); return }

    // ── per-notebook static cell screenshots ────────────────────────────────────────────────
    for (const [id, shots] of Object.entries(CELL_SHOTS)) {
      const page = await (await newContext(browser)).newPage()
      await runNotebook(page, id)
      if (id === 'demo') { await page.evaluate(() => window.scrollTo(0, 0)); await page.screenshot({ path: join(OUT, 'overview.png') }); log('✓ overview.png') }   // viewport, not the giant full page
      // Seek the animation player to a mid-frame so the shot shows a live "N / total" counter and a
      // representative frame (not the idle 0/0 first frame). Player registers at window._animPlayers[cellId].
      if (id === 'anim') {
        try {
          await page.waitForFunction(() => { const a = window._animPlayers && window._animPlayers['anim']; return a && a[0] && a[0].N > 1 }, { timeout: 15_000 })
          await page.evaluate(() => { const p = window._animPlayers['anim'][0]; p.pause(); p.layer = Math.floor((p.N - 1) * 0.4); p._draw(); p._tick() })
          await sleep(400)
        } catch (e) { log('! anim seek skipped:', e.message.split('\n')[0]) }
      }
      for (const [cid, name] of Object.entries(shots)) await cellShot(page, cid, name)

      // driven captures, per notebook
      if (id === 'demo') {
        // completion popup + doc-preview card (type into the chart cell)
        try {
          await page.locator('.cell[data-cid="chart"]').scrollIntoViewIfNeeded()
          await page.evaluate(() => window.scrollBy(0, -120))
          await page.evaluate(() => {
            const v = window.editors['chart']; v.focus()
            const end = v.state.doc.length
            v.dispatch({ changes: { from: end, insert: '\nround' }, selection: { anchor: end + 6 } })
            window.CM6?.startCompletion?.(v)
          })
          await page.waitForSelector('.cm-tooltip-autocomplete', { timeout: 5000 })
          await sleep(800)
          await page.screenshot({ path: join(OUT, 'completion.png') }); log('✓ completion.png')
          await page.keyboard.press('Escape')
        } catch (e) { log('! completion skipped:', e.message.split('\n')[0]) }

        // dependency focus (🔗): show only the chart cell's dependency chain
        try {
          await page.evaluate(() => window.toggleDeps && window.toggleDeps('chart'))
          await sleep(700)
          await page.screenshot({ path: join(OUT, 'deps-cone.png'), fullPage: true }); log('✓ deps-cone.png')
          await page.evaluate(() => window.slateStore && window.slateStore.setFocus(null))
        } catch (e) { log('! deps-cone skipped:', e.message.split('\n')[0]) }

        // DAG pane (🕸 / ⌘⇧G): the notebook's live dataflow graph
        try {
          await page.evaluate(() => window.toggleDag && window.toggleDag())
          await page.waitForSelector('#dagpane svg, #dagpane .dagnode', { timeout: 8000 }).catch(() => {})
          await sleep(1000)                                    // dagre layout settle
          await elShot(page, '#dagpane', 'dag-pane.png')
          await page.evaluate(() => window.toggleDag && window.toggleDag())
        } catch (e) { log('! dag-pane skipped:', e.message.split('\n')[0]) }

        // history / time-machine panel
        try {
          await page.evaluate(() => window.toggleHistory && window.toggleHistory())
          await page.waitForSelector('#histpanel.open .hrow', { timeout: 6000 })
          await sleep(500)
          await panelShot(page, '#histpanel', 'history-panel.png')
          await page.evaluate(() => window.toggleHistory && window.toggleHistory())
        } catch (e) { log('! history-panel skipped:', e.message.split('\n')[0]) }

        // settings modal
        try {
          await page.evaluate(() => window.openSettings && window.openSettings())
          await elShot(page, '#setbg .setmodal', 'settings.png')
          await page.evaluate(() => window.closeSettings && window.closeSettings())
        } catch (e) { log('! settings skipped:', e.message.split('\n')[0]) }

        // command palette (⌘K) — fuzzy command list with shortcut hints
        try {
          await page.evaluate(() => window.openPalette && window.openPalette())
          await page.waitForSelector('#cmdbg .cmdpal', { timeout: 6000 })
          await page.evaluate(() => { const i = document.querySelector('#cmdbg input'); if (i) i.value = '' })
          await sleep(400)
          await elShot(page, '#cmdbg .cmdpal', 'command-palette.png')
          await page.keyboard.press('Escape')
        } catch (e) { log('! command-palette skipped:', e.message.split('\n')[0]) }

        // help / docs dock (⌘⇧K) — populate with a real docstring lookup so the card has content
        try {
          await page.evaluate(() => window.openDocs && window.openDocs())
          await page.waitForSelector('#docpanel', { timeout: 6000 })
          await page.evaluate(() => window.helpLookup && window.helpLookup('sort'))
          await page.waitForSelector('#docpanel .docmd', { timeout: 6000 }).catch(() => {})
          await sleep(700)
          await elShot(page, '#docpanel', 'help-docs.png')
          await page.evaluate(() => window.minimizeDocs && window.minimizeDocs())
        } catch (e) { log('! help-docs skipped:', e.message.split('\n')[0]) }

        // export dialog (the unified Export modal — shown without triggering a download)
        try {
          await page.evaluate(() => window.openExport && window.openExport())
          await sleep(400)
          await elShot(page, '#exportbg .modal', 'export-dialog.png')
          await page.evaluate(() => document.getElementById('exportbg')?.classList.remove('show'))
        } catch (e) { log('! export-dialog skipped:', e.message.split('\n')[0]) }

        // packages panel (📦) — the standalone demo is detached (empty), so paint a representative
        // forked-environment state with the real markup so the provenance grouping is visible.
        try {
          await page.evaluate(() => {
            const p = document.getElementById('pkgpanel'); p.classList.add('open')
            document.getElementById('pkgstatus').textContent = '2 notebook · 5 from parent'
            const row = (n, v, rm) => `<div class="pkgrow"><span class="pkgname">${n}</span><span class="pkgver">${v}</span>` +
              (rm ? '<button class="cdel" title="remove">✕</button>' : '') + '</div>'
            document.getElementById('pkglist').innerHTML =
              '<div class="pkggrouphdr">Notebook adds</div>' +
              row('CSV', '0.10.14', true) + row('Plots', '1.40.5', true) +
              '<div class="pkggrouphdr">Parent project <span class="pkgpath">MyAnalysis</span></div>' +
              row('DataFrames', '1.6.1', false) + row('Distributions', '0.25.109', false) +
              row('JSON3', '1.14.0', false) + row('StatsBase', '0.34.3', false) + row('Tables', '1.11.1', false)
          })
          await sleep(900)   // settle the open transition before the cropped element shot
          await shotCropped(page, '#pkgpanel', 'packages-panel.png', '#pkglist')
          await page.evaluate(() => document.getElementById('pkgpanel').classList.remove('open'))
        } catch (e) { log('! packages-panel skipped:', e.message.split('\n')[0]) }

        // agent pane (💬) — the standalone server has no live agent, so inject a representative
        // transcript and let the REAL renderer draw it (authentic markup, illustrative content).
        try {
          await page.evaluate(() => {
            agentMsgs = [
              { role: 'user', text: 'Plot a sine wave with an adjustable frequency.', done: true },
              { role: 'think', text: 'A slider for the frequency, then a chart cell that reads it.', done: true },
              { role: 'assistant', text: "I'll add a frequency slider and a chart cell below it.", done: true },
              { role: 'tool', text: '➕ add cell', code: '@bind freq Slider(1:20; default = 3, label = "frequency")', cid: 'freq', done: true },
              { role: 'tool', text: '➕ add cell', code: 'echart(:line, 0:0.1:2π, sin.(freq .* (0:0.1:2π)))', cid: 'wave', done: true },
              { role: 'tool', text: '🖼 view figure', done: true },
              { role: 'assistant', text: 'Done — drag the slider and the wave recomputes live.', done: true },
            ]
            renderAgentMsgs()
            if (!document.getElementById('agentpanel').classList.contains('open')) toggleAgent()
          })
          // Settle the open transition, then a DIRECT element shot. (panelShot's height-collapse
          // trick mis-crops the agent panel's flex/transform layout → an off-screen capture.)
          await sleep(900)
          await elShot(page, '#agentpanel', 'agent-panel.png')
          await page.evaluate(() => { if (document.getElementById('agentpanel').classList.contains('open')) toggleAgent() })
        } catch (e) { log('! agent-panel skipped:', e.message.split('\n')[0]) }

        // cell tag editor (🏷) — open the popover on a cell and shoot it
        try {
          await page.locator('.cell[data-cid="highlight"]').scrollIntoViewIfNeeded()
          await sleep(200)
          await page.locator('.cell[data-cid="highlight"] .tagbtn').first().click()
          await page.waitForSelector('#tagpop.show', { timeout: 4000 })
          await sleep(300)
          await elShot(page, '#tagpop', 'tag-editor.png')
          await page.keyboard.press('Escape')
        } catch (e) { log('! tag-editor skipped:', e.message.split('\n')[0]) }

        // present mode (▶ Present / ⌘⇧P) — full-screen slide deck; capture the title slide
        try {
          await page.evaluate(() => window.enterPresent && window.enterPresent())
          await sleep(900)
          await page.screenshot({ path: join(OUT, 'present-slide.png') }); log('✓ present-slide.png')
          await page.keyboard.press('Escape'); await sleep(300)
        } catch (e) { log('! present-slide skipped:', e.message.split('\n')[0]) }
      }

      if (id === 'widgets') {
        // controls palette — every @bind across the notebook
        try {
          await page.evaluate(() => window.togglePalette && window.togglePalette())
          await sleep(600)
          await panelShot(page, '.palette', 'controls-palette.png')
        } catch (e) { log('! controls-palette skipped:', e.message.split('\n')[0]) }
      }
      await page.context().close()
    }

    // ── publishing UI (mocked ledger — no real targets/sites/secrets needed) ─────────────────
    // Route-intercept /api/publish/ledger + /api/sites with synthetic demo data (mockPublish), so
    // the Publish panel, the front-page manager dashboard, and the Sites strip all render clean
    // demo content — reproducible in CI without configuring any real publish target.
    try {
      // Publish panel — notebook ☰ → ☁ Publish… (Export dialog in Website mode)
      const p1 = await (await newContext(browser)).newPage()
      await mockPublish(p1)
      await p1.goto(`${BASE}/n/demo`, { waitUntil: 'domcontentloaded' })
      await p1.waitForSelector('.cell', { timeout: 30_000 })
      await p1.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
      await sleep(700)
      await p1.evaluate(() => window.openPublish && window.openPublish())
      await sleep(600)
      // pick the existing "portfolio" site so the destinations show
      await p1.evaluate(() => { const s = document.getElementById('sitepick'); if (s) { for (const o of s.options) { if (o.value === 'portfolio' || o.textContent.includes('portfolio')) { s.value = o.value; s.dispatchEvent(new Event('change', { bubbles: true })); break } } } })
      await sleep(500)
      await elShot(p1, '#exportbg .modal', 'publish-panel.png')
      await p1.context().close()

      // Manager dashboard + Sites strip — the hub front page
      const p2 = await (await newContext(browser)).newPage()
      await mockPublish(p2)
      await p2.goto(`${BASE}/`, { waitUntil: 'domcontentloaded' })
      await sleep(1600)                                        // let loadPublished() refresh the strip
      // Full front page — the open row (path + Run on + ⬆ Upload + 🖧 Remotes), ☁ Publishing, the
      // open-notebooks list, and the mocked Sites strip. This is the "open or upload a document" shot.
      await p2.screenshot({ path: join(OUT, 'home.png'), fullPage: true }); log('✓ home.png')
      await p2.evaluate(() => { const c = document.querySelector('#published .sitecard'); if (c) c.click() })
      await sleep(500)
      await shotCropped(p2, '#published', 'sites-strip.png', null, 6)
      await p2.evaluate(() => window.openPubDash && window.openPubDash())
      await sleep(1000)
      await elShot(p2, '#pubdashbg .pubdash', 'publishing-manager.png')
      await p2.context().close()
    } catch (e) { log('! publishing shots skipped:', e.message.split('\n')[0]) }

    // ── regions / DAG / mesh (synthetic — no real hosts) ─────────────────────────────────────
    await regionShots(browser)

    // ── webm: drag the slider → the chart re-renders live (reactivity) ───────────────────────
    // Frame the slider AND the chart together (slider is the cell right above the chart) so the
    // viewer sees the plot redraw as the control moves.
    try {
      const SZ = { width: 960, height: 720 }
      const ctx = await newContext(browser, { viewport: SZ, deviceScaleFactor: 1, recordVideo: { dir: VIDTMP, size: SZ } })
      const page = await ctx.newPage()
      await page.goto(`${BASE}/n/demo`, { waitUntil: 'domcontentloaded' })   // cells already FRESH (state persists)
      await page.waitForSelector('.cell[data-cid="chart"] canvas, .cell[data-cid="chart"] svg', { timeout: 20_000 }).catch(() => {})
      await page.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
      // Put the controls cell near the top so the chart cell below fills the rest of the frame.
      await page.locator('.cell[data-cid="controls"]').evaluate((el) => el.scrollIntoView({ block: 'start' }))
      await page.evaluate(() => window.scrollBy(0, -70))
      await sleep(900)
      const controls = page.locator('.cell[data-cid="controls"]')
      const freq = controls.locator('input[type="range"]').first()
      if (await freq.count()) {
        await freq.focus()
        for (let i = 0; i < 14; i++) { await freq.press('ArrowRight'); await sleep(180) }   // crank the frequency — the wave compresses
        await sleep(500)
        const cos = controls.locator('input[type="checkbox"]').first()
        if (await cos.count()) { await cos.click({ force: true }); await sleep(1000) }       // toggle the cosine series on
        for (let i = 0; i < 10; i++) { await freq.press('ArrowLeft'); await sleep(180) }     // ease it back down
      } else { log('! no range input for reactivity clip'); await sleep(1500) }
      await sleep(700)
      const video = page.video()
      await ctx.close()
      if (video) { await video.saveAs(join(OUT, 'reactivity.webm')); log('✓ reactivity.webm') }
    } catch (e) { log('! reactivity.webm skipped:', e.message.split('\n')[0]) }

    log('done — assets in', OUT)
  } finally {
    cleanup()
  }
}

main().catch((e) => { console.error(e); process.exit(1) })
