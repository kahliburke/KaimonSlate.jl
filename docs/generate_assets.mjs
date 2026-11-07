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
import { execSync, spawn } from 'node:child_process'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
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
const EXTRA = ['widgets', 'charts', 'anim', 'docs', 'tables', 'hero', 'app', 'live', 'web', 'profile', 'debug', 'slides', 'sweep'] // opened over /api/open

mkdirSync(OUT, { recursive: true })
const VIDTMP = mkdtempSync(join(tmpdir(), 'slate-vid-'))
// The hub's own home, so its machines, regions and sweep stores are the ones defined here and not the
// machine's. `lab` has no scheduler and no host: its sweeps run as processes on this machine.
const HOME = mkdtempSync(join(tmpdir(), 'slate-docs-home-'))
mkdirSync(join(HOME, 'config'), { recursive: true })
writeFileSync(join(HOME, 'config', 'clusters.json'), JSON.stringify([{ name: 'lab', kind: 'exec', procs: '4', root: join(HOME, 'sweeps') }]))

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
  // KAIMONSLATE_NO_OPEN: don't pop the system browser (Safari) — the captures run in headless Chromium.
  // Several threads, so the profiler's timeline has a lane for each. Cells run in this process.
  const proc = spawn('julia', [`--project=${DOCS}`, '--startup-file=no', '--color=no', '--threads=4', '-e', jl],
    { cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, KAIMONSLATE_NO_OPEN: '1', KAIMONSLATE_HOME: HOME } })
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
  const nbid = await page.evaluate(() => NB_ID)   // core.js declares it with const: a global binding, not a window property
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
// This notebook's per-site membership (/api/publish/doc + /api/publish/sites) for the Publish panel
// (#pubbg) — a dedicated panel now, not the Export dialog. Left column = sites this notebook can join;
// right column = where it's already published.
const PUB_SITES = {
  slug: 'gram-schmidt',
  sites: [
    { name: 'portfolio', title: "Ada's Notebooks", targets: ['pages', 'cloudflare'], member: true,
      isHome: false, hasHome: true, homeTitle: "Ada's Notebooks", url: 'https://ada.github.io/notebooks/' },
    { name: 'teaching', title: 'Numerical Methods', targets: ['pages'], member: false,
      isHome: false, hasHome: false, homeTitle: '' },
  ],
}
const PUB_DOC = {
  title: 'Gram–Schmidt, visualized', slug: 'gram-schmidt',
  events: [
    { target: 'pages', status: 'ok', ts: '2026-07-02T10:15:00', url: 'https://ada.github.io/notebooks/gram-schmidt/' },
    { target: 'cloudflare', status: 'ok', ts: '2026-06-20T09:40:00', url: 'https://ada-notebooks.pages.dev/gram-schmidt/' },
  ],
}
async function mockPublish(page) {
  const J = (o) => ({ contentType: 'application/json', body: JSON.stringify(o) })
  await page.route('**/publish/ledger*', (r) => r.fulfill(J(PUB_LEDGER)))   // manager dashboard + panel targets
  await page.route('**/publish/sites*', (r) => r.fulfill(J(PUB_SITES)))     // Publish panel: site membership
  await page.route('**/publish/doc*', (r) => r.fulfill(J(PUB_DOC)))         // Publish panel: this doc's history
  await page.route('**/api/sites', (r) => r.fulfill(J({ sites: ['portfolio'] })))   // front-page Sites strip
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
    // Defined globally but NOT enabled in the demo notebook — so it shows as an available destination
    // to add (regions are global; a notebook opts into the subset it uses).
    { name: 'bigmem', host: 'mem-box', transport: 'tunnel', base_port: 0, preload: '', data_root: '/scratch',
      warm: 1, threads: '16,1', sysimage: false, status: { ok: true, msg: 'warm 1/1 ready', age: 20 } },
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
  // mem-box (region `bigmem`) intentionally has no live worker here — it exists in the registry so it
  // shows as an available destination to add, without adding a third row to the activity strip.
  'mem-box': [],
  // A plain ssh box with no region defined — it is in the fleet only because a notebook is RUN ON it.
  'workstation': [
    { port: 9400, alive: true, state: 'attached', manifest: mkStats({ notebook: 'seismic_month.jl', transport: 'tunnel', project: 'seismic', spawned: 'attached · 21m', stream_port: 9401 }),
      stats: mkStats({ cpu: 46, rss: 2600 * MB, memo_bytes: 780 * MB, running: ['quakes'], warm: 'ready', sys_cpu: 51, load1: 2.4, sys_mem_total: 32000 * MB, sys_mem_free: 9000 * MB }) },
  ],
}
// The hub's OFF-MACHINE kernels (/api/remote-notebook-workers) — a notebook whose run-on target is
// another machine. `workstation` is in no region, so this is the only thing that puts it on the monitor.
const REG_NB_REMOTE = [
  { host: 'workstation', region: '', port: 9400, alive: true, state: 'attached', lastActivity: 0, logBytes: 0, stateSince: 0,
    manifest: mkStats({ notebook: 'seismic_month.jl', nbid: 'nb-seismic', region: '', side: 'local',
                        transport: 'tunnel', project: 'seismic', port: '9400', stream_port: '9401', hub: 'laptop' }),
    stats: mkStats({ cpu: 46, rss: 2600 * MB, memo_bytes: 780 * MB, running: ['quakes'], warm: 'ready', sys_cpu: 51, load1: 2.4 }) },
]
// Telemetry ring for the worker-detail sparklines (/api/worker-stats). A gentle synthetic wobble.
function regStatsHistory(port) {
  const base = port === 9300 ? 76 : port === 9200 ? 31 : 3
  const rssB = port === 9300 ? 940 : port === 9200 ? 1800 : 260
  const now = Math.floor(Date.now() / 1000)
  return Array.from({ length: 40 }, (_, i) => ({ t: now - (40 - i) * 3,
    cpu: Math.max(0, Math.round(base + 14 * Math.sin(i / 3) + (i % 5))),
    rss: Math.round((rssB + 30 * Math.sin(i / 4)) * MB) }))
}
// The telemetry view's own read (full=1): each sample also names the cells running in it and the
// collections it saw, and the hub adds the runs it timed. That is what the dock's Timeline draws.
// The runs are timed from the first read, so every poll returns the same ones and the view keeps
// one copy of each.
let regRunsAt = 0
function regTelemetryFull(port) {
  const samples = regStatsHistory(port), now = (regRunsAt ||= samples[samples.length - 1].t)
  let pauses = 0, fulls = 0, gcms = 0
  for (const [i, x] of samples.entries()) {
    const gc = []
    if (i % 3 === 0 && (i < 14 || i >= 31)) gc.push([x.t - 0.4, 4 + (i % 7), false, (620 + 8 * i) * MB])
    if (i === 12) gc.push([x.t - 1.2, 145, true, 540 * MB])
    pauses += gc.length; fulls += gc.filter((g) => g[2]).length; gcms += gc.reduce((a, g) => a + g[1], 0)
    Object.assign(x, { running: i >= 32 ? ['train'] : [], gc, gc_ms: gcms, proc: { gc_pauses: pauses, gc_full: fulls, threads: 9 } })
  }
  const run = (id, a, b, o = {}) => ({ id, t0: now - a, t1: now - b, memo: '', err: false, profile: '', ...o })
  return { ok: true, port, host: 'gpu-box', connected: true, samples, runs: [
    run('train', 116, 79, { profile: '1762531200000' }), run('evaluate', 77, 66),
    run('evaluate', 63, 62.6, { memo: 'restored' }), run('train', 58, 47, { err: true })] }
}
// /api/{id}/transfer-rules — what a provision to a region would send, one level of the project at a
// time, with the `.slateignore` already holding the checkpoints back.
const REG_TRAVEL_DIR = '/home/ada/pipeline'
const REG_TRAVEL = {
  '': [
    { name: 'data', path: 'data', dir: true, bytes: 1840 * MB, files: 212, sent_bytes: 1840 * MB, sent_files: 212, state: 'sent', ruled: false },
    { name: 'checkpoints', path: 'checkpoints', dir: true, bytes: 6200 * MB, files: 48, sent_bytes: 0, sent_files: 0, state: 'held', ruled: true },
    { name: 'runs', path: 'runs', dir: true, bytes: 930 * MB, files: 1604, sent_bytes: 0, sent_files: 0, state: 'gitignored', ruled: false },
    { name: 'src', path: 'src', dir: true, bytes: 0.4 * MB, files: 23, sent_bytes: 0.4 * MB, sent_files: 23, state: 'sent', ruled: false },
    { name: 'pipeline.jl', path: 'pipeline.jl', dir: false, bytes: 0.03 * MB, files: 1, sent_bytes: 0.03 * MB, sent_files: 1, state: 'sent', ruled: false },
    { name: 'Project.toml', path: 'Project.toml', dir: false, bytes: 0.002 * MB, files: 1, sent_bytes: 0.002 * MB, sent_files: 1, state: 'sent', ruled: false },
  ],
  data: [
    { name: 'raw', path: 'data/raw', dir: true, bytes: 1610 * MB, files: 180, sent_bytes: 1610 * MB, sent_files: 180, state: 'sent', ruled: false },
    { name: 'labels.csv', path: 'data/labels.csv', dir: false, bytes: 210 * MB, files: 1, sent_bytes: 210 * MB, sent_files: 1, state: 'sent', ruled: false },
    { name: 'splits', path: 'data/splits', dir: true, bytes: 20 * MB, files: 31, sent_bytes: 20 * MB, sent_files: 31, state: 'sent', ruled: false },
  ],
}
function regTravel(region, path) {
  const all = REG_TRAVEL[''], sent = all.reduce((a, e) => a + e.sent_bytes, 0), bytes = all.reduce((a, e) => a + e.bytes, 0)
  const nsent = all.reduce((a, e) => a + e.sent_files, 0), files = all.reduce((a, e) => a + e.files, 0)
  return { region, dir: REG_TRAVEL_DIR, warn_mb: 100, file: REG_TRAVEL_DIR + '/.slateignore', exists: true,
    last: { files: nsent, bytes: sent, ago: 3 * 3600, dir: 'pipeline' }, text: 'checkpoints/\n', path,
    entries: REG_TRAVEL[path] || [], sent: { files: nsent, bytes: sent }, held: { files: files - nsent, bytes: bytes - sent } }
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
// A region worker's log (/api/{id}/worker-log for the dock's recent messages, worker-log-io for its
// Log tab), as the worker writes it: Julia log records, level then clock.
const REG_WORKER_LOG = [
  '┌ Info 12:04:11: slate worker: ready', '│   port = 9300', '│   tools = 36', '└   revise = true',
  '┌ Info 12:04:12: gate: attached', '│   origin = "adopted from the warm pool"', '└   dial_s = 0.9',
  '[ Info 12:04:15: sync_memo: 12 blobs deduplicated, 3 carried (512 MB)',
  '┌ Info 12:04:18: slate eval: ran cell', '│   cell = "train"', '└   ms = 4182.6',
  '┌ Warning 12:05:02: GPU memory 92% used', '└   device = 0',
  '┌ Info 12:05:30: transfer: feat 210 MB from db', '│   route = "direct"', '└   rate = "92 MB/s"',
  '[ Info 12:06:41: slate eval: ran cell train in 8.2 s',
].join('\n') + '\n'
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
// ── extensions gallery (synthetic catalog — no registry, no installs) ─────────────────────────
// A fixed catalog in the real `/api/catalog` shape. Mocked rather than fetched so the docs show a
// stable, complete picture: entries at every tier (rich with imagery, described, bare), one already
// installed, and one with an update pending — states that a live capture could only produce by
// actually installing packages into the docs run.
const CAT_ENTRIES = [
  { name: 'CesiumSlate', title: 'CesiumSlate', version: '0.1.1', tier: 'rich', visibility: 'public',
    tagline: 'A CesiumJS 3D globe with live satellites, as a notebook output',
    description: 'An interactive CesiumJS 3D globe with live satellites as a first-class Kaimon Slate output.',
    categories: ['visualization', 'geospatial'], icon: '🛰', installed: false, inParent: false, updatable: false,
    repo: 'https://github.com/kahliburke/CesiumSlate.jl',
    screenshots: ['https://github.com/kahliburke/CesiumSlate.jl/releases/download/media/CesiumSlate-notebook.png'] },
  { name: 'GiacSlate', title: 'GiacSlate', version: '0.1.1', tier: 'rich', visibility: 'public',
    tagline: 'The Xcas computer-algebra engine, through live inline math fields',
    categories: ['math', 'controls'], icon: '∫', installed: false, inParent: false, updatable: false,
    repo: 'https://github.com/kahliburke/GiacSlate.jl' },
  { name: 'MermaidSlate', title: 'Mermaid', version: '0.1.0', tier: 'rich', visibility: 'public',
    tagline: 'Mermaid diagrams as computed values — text in, diagram out',
    categories: ['visualization', 'documents'], icon: '🧜', installed: false, inParent: false, updatable: false,
    repo: 'https://github.com/kahliburke/MermaidSlate.jl' },
  // Installed, and the registry has moved on — this is the card that carries the update affordance.
  { name: 'StarRating', title: 'Star Rating', version: '0.1.3', tier: 'rich', visibility: 'public',
    tagline: 'A ★ rating control for @bind — the smallest complete Slate extension',
    description: 'A sample Slate extension: a typed @bind star-rating control, built entirely against the lean SlateExtensionsBase SDK.',
    categories: ['controls', 'examples'], icon: '★',
    provides: ['@bind control: Stars(; max, label) — binds an Int in 0:max',
               'Cell toolbar action: ★ inserts a Stars() snippet',
               'Command palette: insert a Stars() control'],
    snippet: 'using StarRating\n@bind rating Stars(; max = 5, label = "How good?")\n',
    installed: true, inParent: false, installedVersion: '0.1.2', updatable: true,
    repo: 'https://github.com/kahliburke/KaimonSlate.jl', subdir: 'examples/extensions/StarRating' },
  { name: 'SlateAFM', title: 'SlateAFM', version: '0.1.1', tier: 'rich', visibility: 'public',
    tagline: 'Anywidget front-end modules, hosted in a Slate notebook',
    categories: ['widgets', 'interop'], icon: '🧩', installed: false, inParent: false, updatable: false,
    repo: 'https://github.com/kahliburke/KaimonSlate.jl' },
  { name: 'SlateBench', title: 'SlateBench', version: '0.1.1', tier: 'described', visibility: 'public',
    description: 'A streaming-transport benchmark widget for Kaimon Slate. Drop it in a cell and it renders a live dashboard.',
    categories: ['diagnostics'], installed: false, inParent: false, updatable: false,
    repo: 'https://github.com/kahliburke/SlateBench.jl' },
]
const CAT_PAYLOAD = {
  entries: CAT_ENTRIES,
  categories: ['controls', 'diagnostics', 'documents', 'examples', 'geospatial', 'interop', 'math', 'visualization', 'widgets'],
  meta: { source: 'published', url: 'https://kahliburke.github.io/SlateRegistry/catalog.json' },
  registryInstalled: true, registryName: 'SlateRegistry',
  registryUrl: 'https://github.com/kahliburke/SlateRegistry',
  manageable: true,
  installedCount: 1, updatableCount: 1,
}
async function mockCatalog(page) {
  await page.route('**/api/*/catalog*', (r) =>
    r.fulfill({ contentType: 'application/json', body: JSON.stringify(CAT_PAYLOAD) }))
}

// Install every region/remote route interceptor on a page BEFORE navigating.
async function mockRegions(page) {
  const J = (o) => ({ contentType: 'application/json', body: JSON.stringify(o) })
  // The page reads the region registry and its workers from the hub's facts (model.js), one full frame on
  // /api/facts and the same frame on the /api/facts/events stream, keyed `region/<name>`,
  // `parked/<host>/<label>/<port>` and `worker/<nb>/<side>`. A full frame replaces every fact, so the
  // mocked regions join the hub's own frame, which keeps the notebook's workers for the top-bar pill.
  // The activity monitor probes the hosts those regions name.
  const facts = async (r) => {
    const hub = await r.fetch({ url: BASE + '/api/facts' }).then((x) => x.json()).catch(() => ({}))
    const set = { ...(hub.set || {}) }
    for (const g of REG_REGISTRY.regions) set['region/' + g.name] = { ...g, scheduler: 'none' }
    for (const p of REG_REGISTRY.parked) set[`parked/${p.host}/${p.label}/${p.port}`] = p
    return { t: 'facts', full: true, rev: hub.rev || 1, now: Date.now() / 1000, set }
  }
  await page.route('**/api/facts', async (r) => r.fulfill(J(await facts(r))))
  await page.route('**/api/facts/events', async (r) =>
    r.fulfill({ contentType: 'text/event-stream', body: 'data: ' + JSON.stringify(await facts(r)) + '\n\n' }))
  await page.route('**/api/regions', (r) => r.request().method() === 'GET' ? r.fulfill(J(REG_REGISTRY)) : r.continue())
  await page.route('**/api/remote-workers*', (r) => {
    const host = new URL(r.request().url()).searchParams.get('host') || ''
    r.fulfill(J({ host, workers: REG_ROSTERS[host] || [] }))
  })
  await page.route('**/api/remote-notebook-workers', (r) => r.fulfill(J({ workers: REG_NB_REMOTE })))
  await page.route('**/api/worker-stats*', (r) => {
    const q = new URL(r.request().url()).searchParams
    // The dock names its worker by notebook and side rather than by port.
    const port = q.get('side') === 'gpu' ? 9300 : q.get('side') === 'db' ? 9200 : Number(q.get('port'))
    // Only the gpu worker has runs to show; it is the one the dock opens on.
    r.fulfill(J(q.get('full') === '1' && port === 9300 ? regTelemetryFull(port) : { ok: true, port, samples: regStatsHistory(port) }))
  })
  await page.route('**/api/ssh-hosts', (r) => r.fulfill(J({ hosts: ['gpu-box', 'db-box', 'mem-box', 'workstation'], global: '' })))
  await page.route('**/api/sysimage*', (r) => {
    const region = new URL(r.request().url()).searchParams.get('region') || ''
    r.fulfill(J({ ok: true, building: false, current: region === 'gpu', stale: false, bytes: 1780 * MB,
      packages: 38, built: Date.now() / 1000 - 2 * 3600, compiler: true, host: region === 'gpu' ? 'gpu-box' : 'db-box', reachable: true }))
  })
  await page.route('**/peer-plan*', (r) => r.fulfill(J(REG_PEERPLAN)))
  await page.route('**/transfer-rules*', (r) => {
    if (r.request().method() !== 'GET') return r.continue()
    const q = new URL(r.request().url()).searchParams
    r.fulfill(J(regTravel(q.get('region') || '', q.get('path') || '')))
  })
  await page.route('**/transfer-stats*', (r) => r.fulfill(J(regTransferStats())))
  await page.route((u) => u.pathname.endsWith('/worker-log'), (r) => r.fulfill(J({ side: new URL(r.request().url()).searchParams.get('side') || '',
    host: 'gpu-box', port: 9300, connected: true, status: 'ok', note: '',
    stats: mkStats({ cpu: 78, rss: 940 * MB, evals: 1, memo: 512 * MB, running: ['train'] }), log: REG_WORKER_LOG })))
  // The Log tab's reads. The file is mocked; what counts as a level or a record is the hub's own
  // vocabulary, fetched from it, so the shot classifies lines the way the product does.
  await page.route((u) => u.pathname.endsWith('/worker-log-io'), async (r) => {
    const q = JSON.parse(r.request().postData() || '{}'), size = Buffer.byteLength(REG_WORKER_LOG)
    if (q.action === 'logs') {
      const real = await (await r.fetch()).json()
      return r.fulfill(J({ logsev: real.logsev, loglist: [{ path: '~/.cache/kaimonslate/worker/worker-9300.log',
        name: 'worker-9300.log', job: '', bytes: size, modified: Math.floor(Date.now() / 1000), running: true }] }))
    }
    if (q.action === 'log_stat') return r.fulfill(J({ bytes: size, modified: Math.floor(Date.now() / 1000) }))
    // `to` is the slice's last byte, inclusive, as the hub reports it.
    if (q.action === 'log_slice') return r.fulfill(J({ text: REG_WORKER_LOG, from: 0, to: size - 1, size }))
    // Searched like the hub does: a regex when asked (the level chips count with one), and `limit: 0`
    // for the count alone.
    const lines = REG_WORKER_LOG.split('\n'), pat = String(q.pattern || '')
    const fold = !!q.ignorecase, re = q.regex ? new RegExp(pat, fold ? 'i' : '') : null
    const hit = t => re ? re.test(t) : (fold ? t.toLowerCase().includes(pat.toLowerCase()) : t.includes(pat))
    let off = 0; const hits = []
    lines.forEach((t, i) => { if (pat && hit(t)) hits.push({ offset: off, line: i + 1, text: t }); off += Buffer.byteLength(t) + 1 })
    return r.fulfill(J({ total: hits.length, capped: false, hits: q.limit === 0 ? [] : hits }))
  })
  await page.route('**/api/preflight-stream*', (r) => {
    const host = new URL(r.request().url()).searchParams.get('host') || 'gpu-box'
    r.fulfill({ contentType: 'text/event-stream', body: regPreflightSSE(host) })
  })
  // Never resolve the mesh-introduce POST — the consent dialog then stays in its "Connecting…"
  // building state. (The real path is notebook-scoped, /api/<id>/mesh-introduce, so match loosely.)
  await page.route('**/mesh-introduce*', () => new Promise(() => {}))
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
    { id: 'train', kind: 'code', state: 'running', source: 'model = train(feat; epochs=40)', deps: ['features'], needs: [], defs: ['model'], tags: ['region=gpu'], stats: { ranOn: 'gpu (gpu-box)', total_ms: 54000, last_ms: 54000, mean_ms: 52000, std_ms: 3500, evals: 1, pulls: 2, last_ts: Math.floor(Date.now() / 1000) - 8, recent: [51000, 53500, 52000, 54000, 52500], xferBytes: 220 * 1048576 } },
    { id: 'evaluate', kind: 'code', state: 'stale', source: 'score = evaluate(model, df)', deps: ['train', 'load'], needs: [], defs: ['score'], tags: ['region=gpu'], stats: { ranOn: 'gpu (gpu-box)' } },
    { id: 'report', kind: 'code', state: 'fresh', source: 'summarize(score)', deps: ['evaluate'], needs: [], defs: [], tags: [], stats: { ranOn: 'local', total_ms: 90, last_ms: 90, evals: 1 } },
  ],
  multidefCells: {}, backrefCells: {},
}

// README hero — a clean reactive example (title + controls + a live chart, no errors), captured
// tight to its content so there's no empty tail below the last cell.
async function heroShot(browser) {
  try {
    const page = await (await newContext(browser)).newPage()
    await runNotebook(page, 'hero')
    await page.evaluate(() => window.scrollTo(0, 0))
    await sleep(500)
    const clip = await page.evaluate(() => {
      const cells = [...document.querySelectorAll('.cell')]
      const last = cells[cells.length - 1]
      const bottom = last ? last.getBoundingClientRect().bottom : window.innerHeight
      return { x: 0, y: 0, width: Math.min(window.innerWidth, 1280),
               height: Math.min(window.innerHeight, Math.ceil(bottom + 24)) }
    })
    await page.screenshot({ path: join(OUT, 'hero.png'), clip })
    log('✓ hero.png')
    await page.context().close()
  } catch (e) { log('! hero skipped:', e.message.split('\n')[0]) }
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

    // worker/region pills (topbar) + worker dock (pill → streamed log + telemetry)
    try {
      await elShot(page, '#workerpills', 'worker-pills.png')
      // The DAG pane from the shots above would cover the dock's right half.
      await page.evaluate(() => { if (document.getElementById('dagpane')?.classList.contains('open')) window.toggleDag() })
      page.on('pageerror', (e) => log('  page error:', e.message))
      await page.addStyleTag({ content: '#runchip{display:none!important}' })   // the mocked running cell's chip
      await page.evaluate(() => document.body.style.setProperty('--wdockh', '64vh'))   // room for the charts
      await page.evaluate(() => window.wpOpenTelemetry && window.wpOpenTelemetry('gpu'))
      await page.waitForSelector('#wdock-tel.on', { timeout: 6000 })
      await sleep(2500)                                       // the telemetry view's first samples
      await elShot(page, '#workerdock', 'worker-dock.png')
      await elShot(page, '#workerdock .tm-sec:has(h3:text-is("Timeline"))', 'worker-timeline.png')
      await page.evaluate(() => document.body.style.removeProperty('--wdockh'))
      await page.evaluate(() => window.wpOpenLog && window.wpOpenLog('gpu'))
      await page.waitForSelector('#wdock-log.on', { timeout: 6000 })
      await sleep(1500)                                       // the viewer's first window and the recent messages
      await elShot(page, '#workerdock', 'worker-log.png')
      await page.evaluate(() => window.closeWorkerDock && window.closeWorkerDock())
      await page.evaluate(() => { if (!document.getElementById('dagpane')?.classList.contains('open')) window.toggleDag() })
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

    // mesh-connect "Connecting…" building state — accept the consent, then stall the introduce POST
    try {
      await sleep(400)                                       // let the prior consent dialog finish tearing down
      await page.evaluate(() => window.onMeshConsent && window.onMeshConsent({
        connected: false, pairs: [{ source: 'gpu', puller: 'db', source_host: 'gpu-box', puller_host: 'db-box' }], unreachable: [],
      }))
      await page.waitForSelector('.meshcard .meshbtn.primary', { timeout: 6000 })
      await sleep(300)
      // arm() awaits window.api(POST /api/…/mesh-introduce); hang exactly that call so `busy` stays
      // true and the card holds its "Connecting…" state (transport/URL-agnostic — page.route can't
      // catch a WS RPC, and the HTTP path is notebook-scoped).
      await page.evaluate(() => { const o = window.api; window.api = (m, p, b) => (p && String(p).includes('mesh-introduce')) ? new Promise(() => {}) : o(m, p, b) })
      await page.evaluate(() => document.querySelector('.meshcard .meshbtn.primary')?.click())
      await sleep(300)
      await page.evaluate(() => window.onMeshBuild && window.onMeshBuild({ phase: 'run', src: 'gpu', puller: 'db', i: 1, n: 2 }))
      await sleep(500)
      await elShot(page, '.meshcard', 'mesh-connecting.png')
      await page.evaluate(() => window.onMeshConsent && window.onMeshConsent({ connected: true, pairs: [] }))
    } catch (e) { log('! mesh-connecting skipped:', e.message.split('\n')[0]) }

    // DAG node detail card for a remote cell — provenance chips (last ran 🖧 host · moved ⇄ MB) + Run-on picker
    try {
      await page.evaluate(() => window._dagCard && window._dagCard('train', 0, 0))
      await page.waitForSelector('#dagcard', { timeout: 5000 })
      await sleep(600)
      await elShot(page, '#dagcard', 'dag-node-card.png')
      await page.evaluate(() => window._dagCardClose && window._dagCardClose())
    } catch (e) { log('! dag-node-card skipped:', e.message.split('\n')[0]) }

    // region hover card — a zone's worker status card in the DAG
    try {
      await page.evaluate(() => window._dagRegCardShow && window._dagRegCardShow({
        name: 'gpu', isLocal: false, host: 'gpu-box', wstatus: 'ok',
        worker: { port: 9300, transport: 'tunnel', host: 'gpu-box', note: '',
          stats: JSON.stringify({ cpu: 78, rss: 940 * 1048576, evals: 1, running: ['train'], warm: 'ready · CUDA', memo: 512 * 1048576 }) },
      }, 420, 70))
      await page.waitForSelector('#dagregcard', { timeout: 5000 })
      await sleep(500)
      await elShot(page, '#dagregcard', 'region-hover-card.png')
      await page.evaluate(() => document.getElementById('dagregcard')?.remove())
    } catch (e) { log('! region-hover-card skipped:', e.message.split('\n')[0]) }

    // peer-plan mid-probe state — the recalculate flow testing a route
    try {
      await page.evaluate(() => window._dagPeerPlan && window._dagPeerPlan(false))
      await page.waitForSelector('#dagpeerpanel .dagpeerbody', { timeout: 6000 })
      await page.evaluate(() => window.onProbeProgress && window.onProbeProgress({ phase: 'run', src: 'gpu', dst: 'db', i: 1, n: 3 }))
      await sleep(600)
      await elShot(page, '#dagpeerpanel', 'dag-peer-plan-probing.png')
      await page.evaluate(() => document.getElementById('dagpeerpanel')?.remove())
    } catch (e) { log('! dag-peer-plan-probing skipped:', e.message.split('\n')[0]) }

    // a region's detail panel: what a provision to it sends, as a tree with sizes
    try {
      // The hub's own workers frame has replaced the mocked list by now; put the mocked one back.
      await page.evaluate((ws) => window._dagOnWorkers && window._dagOnWorkers(ws), REG_NBSTATE.workers)
      await page.evaluate(() => window._dagRegionDetail && window._dagRegionDetail('gpu'))
      await page.waitForSelector('#dagregpanel .dagtvrow', { timeout: 6000 })
      await page.evaluate(() => window._dagTravelsExpand && window._dagTravelsExpand('data'))
      await page.waitForSelector('#dagregpanel .dagtvrow[style*="padding-left:14px"]', { timeout: 6000 })
      await sleep(500)
      await elShot(page, '#dagregpanel', 'dag-what-travels.png')
      await page.evaluate(() => { document.getElementById('dagregpanel')?.remove(); window._dagRegPanelClear && window._dagRegPanelClear() })
    } catch (e) { log('! dag-what-travels skipped:', e.message.split('\n')[0]) }

    // close the DAG pane so the cell-level popovers/bars aren't covered
    await page.evaluate(() => { if (document.getElementById('dagpane')?.classList.contains('open')) window.toggleDag() })
    await sleep(400)

    // tag editor "Run on" section — radio rows (💻 local / 🖧 region / ＋ Add destination)
    try {
      await page.evaluate(() => window.openTagEditor && window.openTagEditor('features'))
      await page.waitForSelector('#tagpop.show', { timeout: 5000 })
      await sleep(500)
      await elShot(page, '#tagpop', 'tag-runon.png')
      await page.evaluate(() => window.hideTagEditor && window.hideTagEditor())
    } catch (e) { log('! tag-runon skipped:', e.message.split('\n')[0]) }

    // destinations manager — enable which declared regions the notebook uses
    try {
      await page.evaluate(() => window.openDestinations && window.openDestinations())
      await page.waitForSelector('#destbg.show', { timeout: 5000 })
      await sleep(600)
      await elShot(page, '#destbg .destmodal, #destbg > div', 'destinations.png')
      await page.evaluate(() => window.closeDestinations && window.closeDestinations())
    } catch (e) { log('! destinations skipped:', e.message.split('\n')[0]) }

    // a cell's live boundary-transfer progress bar (⇄ name: N/M MB ← host)
    try {
      await page.evaluate(() => {
        window.onCellRun && window.onCellRun({ id: 'train' })
        window.onCellProgress && window.onCellProgress({ cid: 'train', id: 'xfer-train', frac: 0.375, msg: '⇄ feat: 79/210 MB ← 🖧 gpu-box' })
      })
      await page.waitForSelector('.cell[data-cid="train"] .cellprog', { timeout: 5000 })
      await sleep(500)
      await elShot(page, '.cell[data-cid="train"]', 'cell-transfer-progress.png')
    } catch (e) { log('! cell-transfer-progress skipped:', e.message.split('\n')[0]) }
    await page.context().close()
  } catch (e) { log('! notebook region shots skipped:', e.message.split('\n')[0]) }

  // ── home-page surfaces (Remotes modal, region focus, activity strip, preflight, worker detail) ─
  try {
    const page = await (await newContext(browser)).newPage()
    await mockRegions(page)
    await page.goto(`${BASE}/`, { waitUntil: 'domcontentloaded' })
    await sleep(1800)                                        // let the activity monitor poll /api/regions
    await elShot(page, '#actmon', 'remote-activity.png')

    // worker telemetry view — click a worker row (opens its telemetry view, actions above the charts)
    try {
      await page.locator('#actmon .actrow').first().click({ timeout: 3000 })
      await page.waitForSelector('.tm-card .tm-chart', { timeout: 8000 })
      await sleep(900)                                        // let the charts lay out
      await elShot(page, '.tm-card', 'worker-detail.png')
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

// ── job cells and sweeps ──────────────────────────────────────────────────────────────────────
// A real sweep on the `lab` machine (processes on this one): submitted from its card, captured while
// units land, then settled, with its job log open.
async function sweepShots(browser) {
  // The card while its run is held for the environment test. Only a machine with a scheduler tests
  // first, so the card's poll is answered as that run's would be, and the line under it reads the
  // test of `hpc` (mockHpc) in progress.
  try {
    const page = await (await newContext(browser)).newPage()
    await mockHpc(page)
    await page.addInitScript(() => {
      let real = null
      const held = (s) => (s && s.state === 'ready') ? { ...s, state: 'held', color: '#d9a441',
        label: 'held — testing its environment on the nodes first', actions: [['cancel', 'Cancel'], ['reset', 'Reset']],
        prepare: 'batch_hpc', prepare_machine: 'hpc' } : s
      Object.defineProperty(window, 'slateCall', { configurable: true, set: (f) => { real = f },
        get: () => real && ((...a) => real(...a).then(held)) })
    })
    await runNotebook(page, 'sweep')
    const card = '.cell[data-cid="scan"] [data-sweep]'
    await page.locator(`${card} [data-sw="testing"]`, { hasText: 'testing' }).waitFor({ timeout: 30_000 })
    await sleep(500)
    await elShot(page, card, 'sweep-testing.png')
    await page.context().close()
  } catch (e) { log('! sweep-testing skipped:', e.message.split('\n')[0]) }
  try {
    const page = await (await newContext(browser)).newPage()
    // What the page saw, printed if the card stalls: its console, its errors and the requests that failed.
    const seen = []
    page.on('console', (m) => seen.push(`console.${m.type()}: ${m.text()}`))
    page.on('pageerror', (e) => seen.push(`pageerror: ${e.message}`))
    page.on('requestfailed', (r) => seen.push(`requestfailed: ${r.method()} ${r.url()} ${r.failure()?.errorText || ''}`))
    page.on('response', (r) => { if (r.status() >= 400) seen.push(`http ${r.status()}: ${r.request().method()} ${r.url()}`) })
    await runNotebook(page, 'sweep')
    const card = '.cell[data-cid="scan"] [data-sweep]'
    await page.waitForSelector(`${card} [data-sw-do="submit"]`, { timeout: 60_000 })
    await page.click(`${card} [data-sw-do="submit"]`)
    await page.getByRole('button', { name: 'Submit', exact: true }).click({ timeout: 5000 })   // the confirmation
    // The card renders in the output's shadow root, which Playwright's locators reach and a page-side
    // querySelector does not.
    const count = page.locator(`${card} [data-sw="count"]`).first()
    const landed = async (frac) => {
      for (const end = Date.now() + 300_000; Date.now() < end; await sleep(250)) {
        const [d, n] = ((await count.textContent().catch(() => '')) || '').split('/').map((x) => parseInt(x))
        if (n > 0 && d >= n * frac) return
      }
      throw new Error('the sweep did not reach ' + Math.round(frac * 100) + '%')
    }
    try { await landed(0.35) }
    catch (e) {
      // Say why in the build log, and keep the card as it stands so the pages that show it still build.
      log('! ' + e.message + '; the card reads:\n' + ((await page.locator(card).first().innerText().catch(() => '')) || '(empty)'))
      log('the page saw:\n' + (seen.slice(-60).join('\n') || '(nothing)'))
      for (const f of execSync(`find ${HOME} -name '*.log' 2>/dev/null | head -6`).toString().split('\n').filter(Boolean))
        log(`--- ${f}\n` + execSync(`tail -n 30 '${f}'`).toString())
      for (const n of ['sweep-running.png', 'sweep-card.png']) await cellShot(page, 'scan', n)
      await elShot(page, card, 'sweep-logs.png')
      await page.context().close()
      return
    }
    await cellShot(page, 'scan', 'sweep-running.png')
    await landed(1)
    await sleep(2500)                                       // the settled render and its chart
    await cellShot(page, 'scan', 'sweep-card.png')
    try {
      await page.click(`${card} [data-sw-do="logs"]`)
      await sleep(2000)
      await elShot(page, '.logv-bg .logv', 'sweep-logs.png')
    } catch (e) { log('! sweep-logs skipped:', e.message.split('\n')[0]) }
    await page.context().close()
  } catch (e) { log('! sweep shots skipped:', e.message.split('\n')[0]) }
}

// ── a SLURM machine (synthetic, like the regions above) ────────────────────────────────────────
// `hpc` exists only in these routes: no host is contacted. The machine, its scheduler, what preparing
// it found, the commands sent to it, a sign-in prompt, and a region cell waiting for its node.
const HPC_HOST = 'login.hpc.example.edu'
const HPC = { name: 'hpc', kind: 'slurm', host: HPC_HOST, root_remote: '/scratch/ada/slate', partition: 'cpu',
              walltime: '02:00:00', cpus: '8', mem: '16G', options: {} }
const HPC_SCHED = { kinds: ['slurm'], suggested: 'slurm', versions: { slurm: '24.05.4' },
  partitions: { slurm: [
    { name: 'cpu', gpus: '', maxtime: '2-00:00:00', up: true },
    { name: 'gpu', gpus: '4× A100', maxtime: '1-00:00:00', up: true },
    { name: 'debug', gpus: '', maxtime: '00:30:00', up: true },
    { name: 'bigmem', gpus: '', maxtime: '7-00:00:00', up: false }] } }
function hpcView() {
  const now = Date.now() / 1000
  return { ok: true, name: 'hpc', host: HPC_HOST, depot: '/scratch/ada/.julia', key: 'machine_hpc', preparing: null,
    site: { prepared_at: now - 3 * 3600, facts: { julia: 'Julia 1.12.1' } },
    tests: [
      { key: 'damping', project: '/home/ada/damping', node_type: 'cpu', by: 'scan', load_s: 14.2, tested_at: now - 3 * 3600, status: 'ok', changed: false },
      { key: 'vision', project: '/home/ada/vision', node_type: 'gpu', by: 'gpu', load_s: 41.8, tested_at: now - 26 * 3600, status: 'ok', changed: false,
        cuda: { functional: 'true' } }] }
}
// The prepare dialog mid-run: the machine's steps, then the notebook's packages on a node.
function hpcPrepare() {
  const now = Date.now() / 1000
  const steps = [
    { step: 'Sign in to ' + HPC_HOST, status: 'ok', secs: 2, detail: 'password and one-time code' },
    { step: 'Julia on ' + HPC_HOST, status: 'ok', secs: 1, detail: 'Julia 1.12.1 (juliaup)' },
    { step: 'Read the site', status: 'ok', secs: 4, detail: '128 cores per node · scratch at /scratch · CUDA 12.4 on gpu' },
    { step: 'Depot', status: 'ok', secs: 1, detail: '/scratch/ada/.julia' },
    { step: 'Build the environment on a node', status: 'running', started: now - 74 }]
  const t = (s) => '[' + new Date((now - s) * 1000).toISOString().replace('T', ' ').replace('Z', '') + '] '
  const log = [t(80) + 'sign in: ' + HPC_HOST + ' (keyboard-interactive)', t(78) + 'julia: 1.12.1 at ~/.juliaup/bin/julia',
    t(74) + '⟨instantiate on c0412⟩ srun --partition=debug --time=00:30:00 --cpus-per-task=8',
    t(60) + '⟨instantiate on c0412⟩    Updating registry at `/scratch/ada/.julia/registries/General.toml`',
    t(40) + '⟨instantiate on c0412⟩  Installing 46 packages',
    t(12) + '⟨instantiate on c0412⟩ Precompiling packages...', t(3) + '⟨instantiate on c0412⟩   31 of 46 complete']
  return { ok: true, preparing: { running: true, started: now - 80, now, last_output: now - 3, steps, log } }
}
function hpcSchedCalls(hours) {
  const nowMin = Math.floor(Date.now() / 60000), n = Math.round(hours * 60)
  const series = Array.from({ length: n }, (_, i) => {
    const m = nowMin - n + i, busy = i > n * 0.55 && i < n * 0.8
    return [m * 60000, Math.max(0, Math.round((busy ? 11 : 3) + 3 * Math.sin(i / 7) + (i % 4)))]
  })
  const total = series.reduce((a, [, v]) => a + v, 0)
  const by = [['squeue', 'poll_jobs!', 0.62], ['sacct', 'reconcile!', 0.21], ['sbatch', 'submit!', 0.09],
              ['sinfo', 'region_load', 0.06], ['scancel', 'cancel!', 0.02]]
    .map(([command, caller, f]) => ({ command, caller, n: Math.round(total * f) }))
  return { ok: true, host: HPC_HOST, budget: 30, hours, last_minute: 4, last_10: 37, since_start: 2814,
           in_window: total, peak: Math.max(...series.map(([, v]) => v)), over: 0, series, by }
}
const HPC_LOAD = { ok: true, ask: '1 node · 8 cpus · 16G · gpu:1 · 02:00:00', gpus: '1', partition: 'gpu',
  queues: [
    { name: 'gpu', cpus_free: 0, cpus_total: 4096, nodes_free: 0, nodes_total: 32, queued: 214, down: 1, eta: '14 min' },
    { name: 'cpu', cpus_free: 3712, cpus_total: 32768, nodes_free: 29, nodes_total: 256 },
    { name: 'debug', cpus_free: 512, cpus_total: 1024, nodes_free: 4, nodes_total: 8 }] }
// Regions on the cluster's login host: the machine's own, and `gpu`, which names the machine and
// changes its shape. `gpu` holds a node, with one worker on it.
function hpcRegions() {
  const now = Date.now() / 1000
  const ready = { ok: true, prepared_at: now - 3 * 3600, steps: [], liveness_grace_s: 120,
                  site: { prepared_at: now - 3 * 3600, depot: '/scratch/ada/.julia' } }
  const base = { host: HPC_HOST, machine: 'hpc', scheduler: 'slurm', transport: 'tunnel', base_port: 0, preload: '',
                 warm: 0, threads: '', sysimage: false, account: '', alloc_name: '', submit: '', prologue: '',
                 options: {}, liveness_grace: '', readiness: ready, preparing: null, status: { ok: true, msg: 'ready', ts: now - 60 } }
  const inherits = { partition: 'cpu', walltime: '02:00:00', cpus: 8, mem: '16G', options: { mail_type: 'FAIL' } }
  const gpuOwn = { partition: 'gpu', walltime: '04:00:00', cpus: 16, mem: '64G', gpus: 'a100:1', options: { constraint: 'a100_80g' } }
  return [
    { ...base, name: 'hpc', partition: 'cpu', walltime: '02:00:00', cpus: 8, mem: '16G', gpus: '', data_root: '',
      idle_release: '', idle_warn: '', own: {}, inherits, node: HPC_HOST },
    { ...base, ...gpuOwn, name: 'gpu', data_root: '/scratch/ada/vision', sysimage: true, idle_release: '30m', idle_warn: '5m',
      prologue: 'module load cuda/12.4', own: gpuOwn, inherits, node: 'g0117' },
  ]
}
async function mockHpc(page, { prompt = null, regions = false } = {}) {
  const J = (o) => ({ contentType: 'application/json', body: JSON.stringify(o) })
  // The hub's facts, plus a session for the cluster and, when asked, a sign-in prompt it is waiting on.
  const facts = async (r) => {
    const hub = await r.fetch({ url: BASE + '/api/facts' }).then((x) => x.json()).catch(() => ({}))
    const set = { ...(hub.set || {}) }
    set['session/' + HPC_HOST] = { host: HPC_HOST, usedBy: ['machine hpc'], nbs: [], connected: !prompt, opening: !!prompt,
                                   auth: 'interactive', error: '', asks: ['Password', 'Verification code'] }
    if (prompt) set['sshauth/a1'] = { id: 'a1', host: HPC_HOST, prompt, secret: true, at: Date.now() / 1000 }
    if (regions) for (const g of hpcRegions()) set['region/' + g.name] = g
    return { t: 'facts', full: true, rev: hub.rev || 1, now: Date.now() / 1000, set }
  }
  await page.route('**/api/facts', async (r) => r.fulfill(J(await facts(r))))
  await page.route('**/api/facts/events', async (r) =>
    r.fulfill({ contentType: 'text/event-stream', body: 'data: ' + JSON.stringify(await facts(r)) + '\n\n' }))
  await page.route('**/api/clusters', async (r) => {
    if (r.request().method() !== 'GET') return r.continue()
    const hub = await (await r.fetch()).json()
    r.fulfill(J({ ...hub, clusters: [HPC, ...(hub.clusters || [])] }))
  })
  await page.route('**/api/scheduler?*', (r) => r.fulfill(J(HPC_SCHED)))
  await page.route('**/api/machines/view?*', (r) => new URL(r.request().url()).searchParams.get('name') === 'hpc' ? r.fulfill(J(hpcView())) : r.continue())
  await page.route('**/api/regions/prepare?*', (r) => r.fulfill(J(hpcPrepare())))
  await page.route('**/api/regions/prepare/reports?*', (r) => r.fulfill(J({ reports: [] })))
  await page.route('**/api/sched-calls?*', (r) => r.fulfill(J(hpcSchedCalls(+new URL(r.request().url()).searchParams.get('hours') || 24))))
  await page.route('**/api/region-load?*', (r) => r.fulfill(J(HPC_LOAD)))
  if (!regions) return
  const now = Date.now() / 1000
  await page.route('**/api/regions', (r) => r.request().method() === 'GET' ? r.fulfill(J({ regions: hpcRegions(), parked: [] })) : r.continue())
  await page.route('**/api/remote-workers*', (r) => r.fulfill(J({ host: HPC_HOST, workers: [
    { port: 9300, alive: true, state: 'attached', manifest: mkStats({ region: 'gpu', notebook: 'vision.jl', transport: 'tunnel', project: 'vision', spawned: 'attached · 18m', stream_port: 9301 }),
      stats: mkStats({ cpu: 92, rss: 3100 * MB, memo_bytes: 640 * MB, running: ['train'], warm: 'ready · CUDA' }) }] })))
  await page.route('**/api/allocation?*', (r) => r.fulfill(J({ ok: true, scheduler: 'slurm', job_name: 'slate-gpu', id: '4812345',
    state: 'running', node: 'g0117', held: true, allocState: 'running', timeleft: '3:12:40', via: HPC_HOST })))
  await page.route('**/api/sysimage*', (r) => r.fulfill(J({ ok: true, building: false, current: true, stale: false, bytes: 1640 * MB,
    packages: 46, built: now - 3 * 3600, compiler: true, host: 'g0117', reachable: true })))
  // The region's own prepare is done; the machine's batch test (above) is the one still running.
  await page.route('**/api/regions/prepare?name=gpu*', (r) => r.fulfill(J({ ok: true, preparing: null,
    readiness: hpcRegions()[1].readiness, now })))
}
// A notebook whose training cell waits for a GPU node on `hpc`.
const HPC_NBSTATE = {
  title: 'vision', path: '/vision.jl', version: 3, hydrating: false,
  worker: { kind: 'gate', connected: true, port: 9100 }, runLocation: 'local',
  regions: [{ name: 'gpu', host: HPC_HOST, machine: 'hpc', transport: 'tunnel', warm: 0, base_port: 0, data_root: '',
              preload: '', sysimage: false, defined: true, status: { ok: true, msg: 'waiting for a node' } }],
  workers: [{ side: '', host: '', port: 9100, status: 'ok', connected: true, transport: 'local', note: '', stats: mkStats({ cpu: 4, rss: 310 * MB, evals: 2 }) }],
  cells: [
    { id: 'intro', kind: 'markdown', state: 'fresh', source: '# Training on the cluster\nData prepared here, the model trained on a GPU node.', deps: [], needs: [], defs: [], tags: [] },
    { id: 'data', kind: 'code', state: 'fresh', source: 'images = load_images("train/")', deps: [], needs: [], defs: ['images'], tags: [], stats: { ranOn: 'local', total_ms: 820, last_ms: 820, evals: 1 } },
    { id: 'train', kind: 'code', state: 'blocked', blocked: 'queued', blockedAt: Math.floor(Date.now() / 1000) - 260, blockedHost: HPC_HOST,
      source: 'model = train(images; epochs = 40)', deps: ['data'], needs: [], defs: ['model'], tags: ['region=gpu'] },
    { id: 'score', kind: 'code', state: 'stale', source: 'accuracy(model, images)', deps: ['train'], needs: [], defs: [], tags: [] },
  ],
  multidefCells: {}, backrefCells: {},
}
// /api/{id}/cluster-status for `hpc`: the cluster's store and jobs as the notebook's worker reads them,
// one sweep of this notebook's running and an earlier one finished.
function hpcClusterStatus() {
  const now = Math.floor(Date.now() / 1000), nb = 'docs-vision'
  const sw = (sweep, o) => ({ sweep, cell: 'scan', notebook: nb, blocked: '', idle: 0, read: 0, hosts: [], ...o })
  return { name: 'hpc', root: '~/.cache/kaimonslate/sweeps/hpc', store_path: '/scratch/ada/slate', kind: 'slurm', host: HPC_HOST,
    store: { bytes: 5210 * MB, blobs: 9120 }, jobs: { running: 3, pending: 2, live: 5, known: 9 },
    xfer: { bytes: 1180 * MB, reads: 14, chunks: 310, rate: '182 MB/s', recent: [] },
    sweeps: [
      sw('s_8c1f2a9e44d07b31', { state: 'running', total: 400, done: 236, ok: 233, failed: 3, missing: 164, started: true,
         rate: 0.41, eta: 400, hosts: ['c0412', 'c0413', 'c0419'], stored: 2950 * MB,
         created: now - 2100, started_at: now - 1500, finished_at: 0 }),
      sw('s_51d0c7aa2e9f6013', { state: 'succeeded', total: 120, done: 120, ok: 120, failed: 0, missing: 0, started: true,
         rate: 0, eta: -1, stored: 1840 * MB, created: now - 90000, started_at: now - 89000, finished_at: now - 86500 }),
    ],
    notebook: nb, err: '' }
}
// A notebook with a job cell on `hpc`, for its ⚙ panel.
const HPC_JOB_NBSTATE = {
  title: 'damping', path: '/damping.jl', version: 3, hydrating: false,
  worker: { kind: 'gate', connected: true, port: 9100 }, runLocation: 'local', regions: [],
  clusters: [HPC],
  workers: [{ side: '', host: '', port: 9100, status: 'ok', connected: true, transport: 'local', note: '', stats: mkStats({ cpu: 3, rss: 290 * MB, evals: 2 }) }],
  cells: [
    { id: 'intro', kind: 'markdown', state: 'fresh', source: '# Damping scan', deps: [], needs: [], defs: [], tags: [] },
    { id: 'scan', kind: 'code', state: 'fresh', source: '@sweep for ζ in 0.01:0.01:4.0\n    simulate(ζ)\nend', deps: [], needs: [], defs: ['scan'],
      tags: ['job', 'cluster=hpc', 'chunk=25', 'walltime=04:00:00'] },
  ],
  multidefCells: {}, backrefCells: {},
}
async function clusterShots(browser) {
  // The Machines tab: the cluster, what its host reports, readiness and scheduler use.
  try {
    const page = await (await newContext(browser, { viewport: { width: 1280, height: 1000 } })).newPage()
    await mockHpc(page)
    await page.goto(`${BASE}/#clusters`, { waitUntil: 'domcontentloaded' })
    await page.waitForSelector('#remotesbg .mchrow:not(.new)', { timeout: 10_000 })
    await sleep(1500)                                        // the scheduler, the view and the counts
    await elShot(page, '#remotesbg .rtmodal, #remotesbg > div', 'machines.png')
    try {
      await page.getByText('Details', { exact: true }).last().click({ timeout: 3000 })
      await page.waitForSelector('.sc-card .tm-tiles', { timeout: 6000 })
      await sleep(1500)                                      // the chart lays out
      await elShot(page, '.sc-card', 'sched-use.png')
      await page.click('.sc-card .tm-x')                     // Escape would close the Machines modal too
    } catch (e) { log('! sched-use skipped:', e.message.split('\n')[0]) }
    try {
      await page.locator('#remotesbg .rppprep button', { hasText: 'Details' }).click({ timeout: 3000 })
      await page.waitForSelector('#prepdialogbg .rpcard .rppprepstep', { timeout: 6000 })
      await sleep(800)
      await elShot(page, '#prepdialogbg .rpcard', 'prepare-dialog.png')
    } catch (e) { log('! prepare-dialog skipped:', e.message.split('\n')[0]) }
    await page.context().close()
  } catch (e) { log('! machine shots skipped:', e.message.split('\n')[0]) }
  // A sign-in prompt: the cluster asks for a one-time code after the password.
  try {
    const page = await (await newContext(browser)).newPage()
    await mockHpc(page, { prompt: '(ada@' + HPC_HOST + ') Verification code: ' })
    await page.goto(`${BASE}/`, { waitUntil: 'domcontentloaded' })
    await page.waitForSelector('.sshauth', { timeout: 10_000 })
    await sleep(500)
    await elShot(page, '.sshauth', 'ssh-signin.png')
    await page.context().close()
  } catch (e) { log('! ssh-signin skipped:', e.message.split('\n')[0]) }
  // A cell waiting for its node, with the cluster's load, and the notice before an idle node goes.
  try {
    const page = await (await newContext(browser)).newPage()
    await mockHpc(page)
    await page.goto(`${BASE}/n/demo`, { waitUntil: 'domcontentloaded' })
    await page.waitForSelector('.cell', { timeout: 30_000 })
    await page.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
    await page.evaluate((st) => { window.renderAll(st) }, HPC_NBSTATE)
    await sleep(800)
    await page.hover('.cell[data-cid="train"] .cregion.blocked')
    await page.waitForSelector('.blkpanel.on .blkqt', { timeout: 6000 })
    await sleep(400)
    const clip = await page.evaluate(() => {
      const a = document.querySelector('.cell[data-cid="train"]').getBoundingClientRect()
      const b = document.querySelector('.blkpanel.on').getBoundingClientRect()
      const x = Math.min(a.left, b.left) - 8, y = a.top - 8
      return { x, y, width: Math.max(a.right, b.right) - x + 8, height: Math.max(a.bottom, b.bottom) - y + 8 }
    })
    await page.screenshot({ path: join(OUT, 'region-blocked.png'), clip }); log('✓ region-blocked.png')
    await page.mouse.move(0, 0)
    try {
      await page.evaluate(() => window.onAllocNotice && window.onAllocNotice({
        kind: 'idle', region: 'gpu', node: 'g0117', host: 'login.hpc.example.edu', walltime_left: 5400,
        seconds_left: 240, idle_release: 1800, extendable: true }))
      await page.waitForSelector('.ancard', { timeout: 5000 })
      await sleep(500)
      await elShot(page, '.ancard', 'alloc-notice.png')
    } catch (e) { log('! alloc-notice skipped:', e.message.split('\n')[0]) }
    await page.context().close()
  } catch (e) { log('! region-blocked skipped:', e.message.split('\n')[0]) }
  // A job cell's ⚙ panel: its settings against the cluster's live store.
  try {
    const page = await (await newContext(browser, { viewport: { width: 1440, height: 900 } })).newPage()
    await mockHpc(page)
    const J = (o) => ({ contentType: 'application/json', body: JSON.stringify(o) })
    await page.route('**/sweep-options?*', (r) => r.fulfill(J({ ok: true, options: { qos: 'normal', licenses: 'ansys@srv' } })))
    await page.route('**/cluster-status?*', (r) => r.fulfill(J(hpcClusterStatus())))
    await page.goto(`${BASE}/n/demo`, { waitUntil: 'domcontentloaded' })
    await page.waitForSelector('.cell', { timeout: 30_000 })
    await page.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
    await page.evaluate((st) => { window.renderAll(st) }, HPC_JOB_NBSTATE)
    await sleep(800)
    await page.evaluate(() => window.openSweepConfig('scan'))
    await page.waitForSelector('#swcfgpop.show .swst-stats', { timeout: 8000 })
    await page.evaluate(() => document.activeElement && document.activeElement.blur())   // opening focuses the first field
    await sleep(800)
    await elShot(page, '#swcfgpop .swcfg-panel', 'job-panel.png')
    await page.context().close()
  } catch (e) { log('! job-panel skipped:', e.message.split('\n')[0]) }
  // The region editor for a region on the cluster's login host, opened from the activity monitor.
  try {
    const page = await (await newContext(browser, { viewport: { width: 1280, height: 1500 } })).newPage()
    await mockHpc(page, { regions: true })
    await page.goto(`${BASE}/`, { waitUntil: 'domcontentloaded' })
    await page.locator('#actmon .actgroupname', { hasText: 'gpu' }).first().click({ timeout: 10_000 })
    await page.locator('#remotesbg .rppcfg', { hasText: 'Request with' }).waitFor({ timeout: 8000 })
    await sleep(1200)                                        // the allocation, sysimage and readiness rows
    // The form has no padding of its own, so the clip adds a margin.
    const clip = await page.evaluate(() => {
      const r = document.querySelector('#remotesbg .rppcfg').getBoundingClientRect()
      return { x: r.left - 16, y: r.top - 16, width: r.width + 32, height: r.height + 32 }
    })
    await page.screenshot({ path: join(OUT, 'region-cluster.png'), clip }); log('✓ region-cluster.png')
    await page.context().close()
  } catch (e) { log('! region-cluster skipped:', e.message.split('\n')[0]) }
}

// The Extensions gallery, in the four states the docs need to explain it: the browse grid, a rich
// detail card, the Installed/Updates views, and an entry with an update pending. Driven off the
// mocked catalog, so no package is installed and no registry is touched.
async function galleryShots(browser) {
  try {
    const page = await (await newContext(browser, { viewport: { width: 1280, height: 900 } })).newPage()
    await mockCatalog(page)
    await page.goto(`${BASE}/n/demo`, { waitUntil: 'domcontentloaded' })
    await page.waitForSelector('.cell', { timeout: 30_000 })
    await page.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
    await sleep(700)

    await page.evaluate(() => window.openExtensions && window.openExtensions())
    await page.waitForSelector('.extbg.show', { timeout: 8000 })
    await page.waitForFunction(() => document.querySelectorAll('.extitem').length > 0, { timeout: 8000 })
    await sleep(700)
    await elShot(page, '.extmodal', 'extensions-gallery.png')

    // A rich card: imagery, what it provides, the starter snippet — and, because this entry is the
    // installed-but-outdated one, the Update action.
    await page.evaluate(() => {
      const it = [...document.querySelectorAll('.extitem')].find((e) => /Star Rating/.test(e.textContent))
      if (it) it.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    })
    await sleep(900)
    await elShot(page, '.extmodal', 'extensions-detail.png')

    // The Updates view — the one state a user goes looking for rather than stumbles into.
    await page.evaluate(() => {
      const v = [...document.querySelectorAll('.extview')].find((e) => /Updates/.test(e.textContent))
      if (v) v.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    })
    await sleep(700)
    await elShot(page, '.extmodal', 'extensions-updates.png')
    await page.context().close()
  } catch (e) { log('! gallery shots skipped:', e.message.split('\n')[0]) }
}

// ── app mode / workbook (real: `?app=1` is a view-only preview on an ordinary hub) ─────────────
// The app posture is a property of the PROCESS, so a docs hub cannot actually be locked down —
// `?app=1` renders exactly the reader's view without the enforcement, which is what a screenshot
// needs. `&workbook=1` additionally returns the editor on cells the document tags `workbook`.
async function appShots(browser) {
  try {
    const page = await (await newContext(browser)).newPage()
    await runNotebook(page, 'app')

    for (const [qs, name] of [['?app=1', 'app-view.png'], ['?app=1&workbook=1', 'app-workbook.png']]) {
      await page.goto(`${BASE}/n/app${qs}`, { waitUntil: 'domcontentloaded' })
      await page.waitForSelector('.cell', { timeout: 30_000 })
      await page.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
      await sleep(1600)
      await page.evaluate(() => window.scrollTo(0, 0))
      const clip = await page.evaluate(() => ({ x: 0, y: 0, width: Math.min(window.innerWidth, 1280),
                                                height: Math.min(window.innerHeight, 860) }))
      await page.screenshot({ path: join(OUT, name), clip })
      log(`✓ ${name}`)
    }

    // A single workbook exercise cell: the accent frame, the "your turn" label, Run / Reset.
    await page.goto(`${BASE}/n/app?app=1&workbook=1`, { waitUntil: 'domcontentloaded' })
    await page.waitForSelector('.cell', { timeout: 30_000 })
    await page.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
    await sleep(1600)
    await cellShot(page, 'ex_inertia', 'workbook-cell.png')
    await page.context().close()
  } catch (e) { log('! app shots skipped:', e.message.split('\n')[0]) }
}

// ── the Settings dialog, both scopes (the full run captures these inline too) ───────────────────
async function settingsShots(browser) {
  try {
    const page = await (await newContext(browser)).newPage()
    await runNotebook(page, 'demo')
    await page.evaluate(() => window.openSettings && window.openSettings())
    await sleep(900)
    await elShot(page, '#setbg .setmodal', 'settings.png')
    await page.evaluate(() => window.setSettingsScope && window.setSettingsScope('notebook'))
    await sleep(1200)
    await elShot(page, '#setbg .setmodal', 'settings-notebook.png')
    await page.context().close()
  } catch (e) { log('! settings shots skipped:', e.message.split('\n')[0]) }
}

// ── the Files panel (real — the demo notebooks sit in a project, so the tree has a root) ───────
async function filesShots(browser) {
  try {
    const page = await (await newContext(browser)).newPage()
    await runNotebook(page, 'demo')
    await page.evaluate(() => window.toggleFiles && window.toggleFiles())
    await page.waitForSelector('#filespanel.open', { timeout: 8000 })
    await sleep(1200)
    await elShot(page, '#filespanel', 'files-panel.png')

    // Filter to one file and click its row, so the right pane shows the editor (with highlighting)
    // instead of the "select a file" empty state. `_filesOpen` is module-local, so click the row.
    await page.evaluate(() => {
      const box = document.getElementById('filesfilter')
      if (box) { box.value = 'widgets.jl'; box.dispatchEvent(new Event('input', { bubbles: true })) }
    })
    await sleep(900)
    const opened = await page.evaluate(() => {
      const row = [...document.querySelectorAll('#filestree [data-kind]')]
        .find((r) => /widgets\.jl/.test(r.textContent || ''))
      if (!row) return false
      row.click(); return true
    })
    if (!opened) { log('! files-editor: no widgets.jl row'); await page.context().close(); return }
    await page.waitForSelector('#filespanel .cm-content', { timeout: 8000 })
    await sleep(1200)
    await elShot(page, '#filespanel', 'files-editor.png')
    await page.context().close()
  } catch (e) { log('! files shots skipped:', e.message.split('\n')[0]) }
}

// ── hot-reload + memo badges (synthetic: both need a gate worker, which the docs hub has not) ──
// The banner is rendered by panels.js off an SSE frame, so calling the renderer directly produces
// the identical DOM without needing Revise, a worker, or a source edit.
async function bannerShots(browser) {
  try {
    const page = await (await newContext(browser)).newPage()
    await runNotebook(page, 'demo')
    await page.evaluate(() => window.showSrcReload && window.showSrcReload(4))
    await sleep(500)
    await elShot(page, '#srcbanner', 'srcreload-banner.png')
    await page.evaluate(() => window.showSrcError && window.showSrcError('UndefVarError: `stiffness` not defined'))
    await sleep(500)
    await elShot(page, '#srcbanner', 'srcerror-banner.png')
    await page.context().close()
  } catch (e) { log('! banner shots skipped:', e.message.split('\n')[0]) }
}

// ── the export dialog's replay step (synthetic plan: a real sweep needs a gate worker) ─────────
// `/replay-plan` answers `{replays: {<mark id>: {…}}}`; the dialog reads control/cell/kind/slice/
// values/strideable/bytes_per_value off each entry and reveals itself with `display:flex`.
const REPLAY_PLAN = {
  replays: {
    'figure:w': { control: 'w', cell: 'figure', kind: 'slider', strideable: true,
                  values: 41, slice: [240], bytes_per_value: 1920, seconds_per_value: 0.031 },
    'tbl:w': { control: 'w', cell: 'tbl', kind: 'slider', strideable: true,
               values: 41, slice: [24], bytes_per_value: 192, seconds_per_value: 0.004 },
    'surface:mode': { control: 'mode', cell: 'surface', kind: 'select', strideable: false,
                      values: 3, slice: [64, 64], bytes_per_value: 32768, seconds_per_value: 0.12 },
  },
}
async function replayShots(browser) {
  try {
    const page = await (await newContext(browser)).newPage()
    await page.route('**/replay-plan*', (r) =>
      r.fulfill({ contentType: 'application/json', body: JSON.stringify(REPLAY_PLAN) }))
    await runNotebook(page, 'demo')
    await page.evaluate(() => window.openReplayStep && window.openReplayStep())
    await page.waitForSelector('#exreplaybg .exrp', { timeout: 8000 })
    await sleep(700)
    await elShot(page, '#exreplaybg .exrp', 'replay-step.png')
    await page.context().close()
  } catch (e) { log('! replay shots skipped:', e.message.split('\n')[0]) }
}

// ── live updates + web cells (real) ────────────────────────────────────────────────────────────
async function liveShots(browser) {
  try {
    const page = await (await newContext(browser)).newPage()
    await runNotebook(page, 'live')
    await cellShot(page, 'gauge', 'reactive-gauge.png')
    await cellShot(page, 'go', 'onclick-button.png')
    // Re-run the progress cell and catch it mid-flight, so the bar is partway rather than done.
    await page.evaluate(() => window.runCell && window.runCell('progress', true))
    await sleep(700)
    await cellShot(page, 'progress', 'progress-bar.png')
    await page.context().close()
  } catch (e) { log('! live shots skipped:', e.message.split('\n')[0]) }
}
async function webShots(browser) {
  try {
    const page = await (await newContext(browser)).newPage()
    await runNotebook(page, 'web')
    await cellShot(page, 'webcell', 'web-cell.png')
    await page.context().close()
  } catch (e) { log('! web shots skipped:', e.message.split('\n')[0]) }
}

// The slide deck (docs/screenshots/slides.jl): a slide with prose beside its chart, an equation
// mid-build, the contact sheet, and the presenter window. `?deck=S.K` presents slide S at step K and
// marks <html data-deck-shot="ready"> once it is in; the presenter window follows the deck tab over a
// BroadcastChannel, so it opens in the same browser context.
async function slideShots(browser) {
  const ctx = await newContext(browser, { viewport: { width: 1280, height: 720 } })   // 16:9, the slide's own shape
  try {
    const page = await ctx.newPage()
    await runNotebook(page, 'slides')
    // A data attribute rather than waitForSelector, which also waits for <html> to count as visible.
    const deckReady = (p) => p.waitForFunction(() => document.documentElement.dataset.deckShot === 'ready', null, { timeout: 30_000 })
    const deck = async (at, name, opts = async () => ({})) => {
      await page.goto(`${BASE}/n/slides?deck=${at}&shot=1`, { waitUntil: 'domcontentloaded' })
      await deckReady(page)
      await sleep(900)
      await page.screenshot({ path: join(OUT, name), ...(await opts()) }); log(`✓ ${name}`)
    }
    await deck('2.end', 'present-columns.png')
    await deck('3.2', 'present-math.png')
    await deck('sheet', 'present-sheet.png', async () => {
      // The sheet fills the window; crop it to the rows of slides.
      const bottom = await page.evaluate(() => Math.max(...[...document.querySelectorAll('.deck-sheet-cell')].map(c => c.getBoundingClientRect().bottom)))
      return { clip: { x: 0, y: 0, width: 1280, height: Math.ceil(bottom) + 14 } }
    })
    await page.goto(`${BASE}/n/slides?deck=2.1`, { waitUntil: 'domcontentloaded' })
    await deckReady(page)
    const presenter = await ctx.newPage()
    await presenter.setViewportSize({ width: 1180, height: 760 })
    await presenter.goto(`${BASE}/n/slides?present=1`, { waitUntil: 'domcontentloaded' })
    await sleep(2500)
    await presenter.screenshot({ path: join(OUT, 'presenter.png') }); log('✓ presenter.png')
  } catch (e) { log('! slide shots skipped:', e.message.split('\n')[0]) }
  await ctx.close()
}

// The profiler and the debugger, on the hub's own kernel. Both run for real: the profile notebook's
// cell is profiled slow, then fast, so the second shot is a genuine comparison; the debug notebook is
// stopped by a conditional breakpoint partway through its loop.
async function toolShots(browser) {
  const page = await (await newContext(browser, { viewport: { width: 1440, height: 900 } })).newPage()
  try {
    await runNotebook(page, 'profile')
    const profiled = () => page.waitForFunction(() => {
      const d = document.querySelector('.pfdock')
      const b = d && [...d.querySelectorAll('button')].find(x => x.textContent.includes('Run and profile'))
      return d && d.querySelector('.pfflame:not(.pfempty)') && b && !b.disabled
    }, null, { timeout: 120_000 })
    const runProfile = async () => {
      await page.evaluate(() => [...document.querySelectorAll('.pfdock button')]
        .find(b => b.textContent.includes('Run and profile')).click())
      await sleep(500); await profiled(); await sleep(1200)
    }
    await page.evaluate(() => window.slateProfileCell('hot'))
    await page.waitForSelector('.pfdock', { timeout: 15_000 })
    await runProfile()
    await elShot(page, '.pfdock', 'profiler-flame.png')
    // The fast version runs (and compiles) once before it is profiled, so the comparison is of the
    // two loops rather than of the compiler.
    await page.evaluate(() => window.slateSetBind('version', 'fast'))
    await sleep(800)
    await page.waitForFunction(() => ((window.__slateState || {}).cells || []).every(c => c.state !== 'running' && c.state !== 'stale'),
                               null, { timeout: 120_000 }).catch(() => {})
    await runProfile()
    await elShot(page, '.pfdock', 'profiler-compare.png')
    // Profiled on the flame tab, which is what `profiled` waits on, then shown as a lane per thread.
    await page.evaluate(() => window.slateProfileCell('spread'))
    await sleep(800)
    await runProfile()
    await page.locator('.pfdock .pfbar2 .slate-tabs button', { hasText: 'Timeline' }).click({ timeout: 3000 })
    await sleep(1200)
    await elShot(page, '.pfdock', 'profiler-timeline.png')
  } catch (e) { log('! profiler shots skipped:', e.message.split('\n')[0]) }
  try {
    await page.keyboard.press('Escape')
    await runNotebook(page, 'debug')
    await page.evaluate(() => window.api('POST', '/api/debug/mark', { file: 'cell:run', line: 5, cond: 'k == 4200' }))
    // A watch on the loop, so the rail's watches section shows a sampled value.
    await page.evaluate(() => window.api('POST', '/api/debug/watch', { file: 'cell:run', line: 6, expr: 'u' }))
    await page.evaluate(() => window.slateDebugCell('run'))
    await page.waitForSelector('.dbgfocus', { timeout: 60_000 })
    await sleep(1500)
    await page.evaluate(() => window.slateDebugStep('continue'))
    await page.waitForFunction(() => /4200|breakpoint/.test((document.querySelector('.dbgfocus') || {}).textContent || ''), null, { timeout: 60_000 }).catch(() => {})
    await sleep(1500)
    await elShot(page, '.dbgfocus', 'debugger-workspace.png')
    // The breakpoint's line calls both gain_at and advance, so Into asks which.
    try {
      await page.evaluate(() => window.slateDebugInto())
      await page.waitForSelector('.dbginto .dbgintorow', { timeout: 15_000 })
      await sleep(500)
      // The source pane down to the picker, which opens over the variables below it.
      const clip = await page.evaluate(() => {
        const a = document.querySelector('.dbgfmid').getBoundingClientRect()
        const b = document.querySelector('.dbginto').getBoundingClientRect()
        return { x: a.left, y: a.top, width: a.width, height: b.bottom - a.top + 24 }
      })
      await page.screenshot({ path: join(OUT, 'debugger-into.png'), clip }); log('✓ debugger-into.png')
      await page.locator('.dbginto .dbgfx').click({ timeout: 3000 })
    } catch (e) { log('! debugger-into skipped:', e.message.split('\n')[0]) }
    await page.evaluate(() => window.slateDebugStep && window.api('POST', '/api/debug/stop', {})).catch(() => {})
  } catch (e) { log('! debugger shot skipped:', e.message.split('\n')[0]) }
  await page.context().close()
}

async function main() {
  const server = startServer()
  let browser
  const cleanup = () => { try { browser?.close() } catch (_) {} ; try { server.kill('SIGKILL') } catch (_) {} }   // the hub keeps nothing; a SIGTERM can leave it holding the port
  process.on('exit', cleanup); process.on('SIGINT', () => { cleanup(); process.exit(1) })
  try {
    await waitForServer()
    await openExtra()
    browser = await chromium.launch({ headless: true })

    // SLATE_REGION_ONLY=1 captures just the region/DAG/mesh shots (fast iteration on those alone).
    if (process.env.SLATE_REGION_ONLY === '1') { await regionShots(browser); log('done (region-only) — assets in', OUT); return }
    // SLATE_HERO_ONLY=1 captures just the README hero.
    if (process.env.SLATE_HERO_ONLY === '1') { await heroShot(browser); log('done (hero-only) — assets in', OUT); return }
    // SLATE_GALLERY_ONLY=1 captures just the Extensions gallery (fast iteration on those shots).
    if (process.env.SLATE_GALLERY_ONLY === '1') { await galleryShots(browser); log('done (gallery-only) — assets in', OUT); return }
    // One gate per newer group, same fast-iteration pattern as the ones above.
    if (process.env.SLATE_APP_ONLY === '1') { await appShots(browser); log('done (app-only)'); return }
    if (process.env.SLATE_FILES_ONLY === '1') { await filesShots(browser); log('done (files-only)'); return }
    if (process.env.SLATE_BANNER_ONLY === '1') { await bannerShots(browser); log('done (banner-only)'); return }
    if (process.env.SLATE_REPLAY_ONLY === '1') { await replayShots(browser); log('done (replay-only)'); return }
    if (process.env.SLATE_LIVE_ONLY === '1') { await liveShots(browser); log('done (live-only)'); return }
    if (process.env.SLATE_WEB_ONLY === '1') { await webShots(browser); log('done (web-only)'); return }
    if (process.env.SLATE_SETTINGS_ONLY === '1') { await settingsShots(browser); log('done (settings-only)'); return }
    if (process.env.SLATE_TOOLS_ONLY === '1') { await toolShots(browser); log('done (tools-only)'); return }
    if (process.env.SLATE_SWEEP_ONLY === '1') { await sweepShots(browser); log('done (sweep-only)'); return }
    if (process.env.SLATE_CLUSTER_ONLY === '1') { await clusterShots(browser); log('done (cluster-only)'); return }
    if (process.env.SLATE_SLIDES_ONLY === '1') { await slideShots(browser); log('done (slides-only)'); return }
    // All of the above in one server boot, for iterating on the newer groups together.
    if (process.env.SLATE_NEW_ONLY === '1') {
      await appShots(browser); await filesShots(browser); await bannerShots(browser)
      await replayShots(browser); await liveShots(browser); await webShots(browser)
      log('done (new-only)'); return
    }
    // SLATE_PUBLISH_ONLY=1 captures just the Publish panel (fast iteration on that capture).
    if (process.env.SLATE_PUBLISH_ONLY === '1') {
      const p = await (await newContext(browser)).newPage()
      await mockPublish(p)
      await p.goto(`${BASE}/n/demo`, { waitUntil: 'domcontentloaded' })
      await p.waitForSelector('.cell', { timeout: 30_000 })
      await p.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
      await sleep(700)
      await p.evaluate(() => (window.openPublishing || window.openPublish)())
      await p.waitForSelector('#pubbg.show', { timeout: 6000 }).catch(() => {})
      await sleep(800)
      await elShot(p, '#pubbg .pubmodal', 'publish-panel.png')
      log('done (publish-only) — assets in', OUT); return
    }

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

        // Settings modal, both scopes. The section list is built from the group headers of whichever
        // scope is active, and the per-notebook rows are fetched, so give each a moment to populate.
        try {
          await page.evaluate(() => window.openSettings && window.openSettings())
          await sleep(900)
          await elShot(page, '#setbg .setmodal', 'settings.png')
          await page.evaluate(() => window.setSettingsScope && window.setSettingsScope('notebook'))
          await sleep(1200)
          await elShot(page, '#setbg .setmodal', 'settings-notebook.png')
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
            // Open the panel directly rather than via toggleAgent() — it refuses to open when no live
            // agent is connected (agentAvailable()), and the standalone docs server never has one.
            document.getElementById('agentpanel').classList.add('open')
            document.body.classList.add('agent-open')
          })
          // Settle the open transition, then a DIRECT element shot. (panelShot's height-collapse
          // trick mis-crops the agent panel's flex/transform layout → an off-screen capture.)
          await sleep(900)
          await elShot(page, '#agentpanel', 'agent-panel.png')
          await page.evaluate(() => { document.getElementById('agentpanel').classList.remove('open'); document.body.classList.remove('agent-open') })
        } catch (e) { log('! agent-panel skipped:', e.message.split('\n')[0]) }

        // cell tag editor (🏷) — open the popover on a cell and shoot it
        try {
          await page.locator('.cell[data-cid="highlight"]').scrollIntoViewIfNeeded()
          await sleep(200)
          // Hover first: a cell's action buttons take no pointer events until the cell is hovered,
          // and Playwright tests what is under the pointer before its own hover lands.
          await page.locator('.cell[data-cid="highlight"]').hover()
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
      // Publish panel — notebook ☰ → ☁ Publish… (the dedicated #pubbg panel: site membership + history)
      const p1 = await (await newContext(browser)).newPage()
      await mockPublish(p1)
      await p1.goto(`${BASE}/n/demo`, { waitUntil: 'domcontentloaded' })
      await p1.waitForSelector('.cell', { timeout: 30_000 })
      await p1.addStyleTag({ content: '.warn{display:none!important} #doclauncher{display:none!important}' })
      await sleep(700)
      await p1.evaluate(() => (window.openPublishing || window.openPublish)())
      await p1.waitForSelector('#pubbg.show', { timeout: 6000 })
      await sleep(800)                                        // let loadSites / loadDoc render both columns
      await elShot(p1, '#pubbg .pubmodal', 'publish-panel.png')
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

    // ── README hero ──────────────────────────────────────────────────────────────────────────
    await heroShot(browser)

    // ── regions / DAG / mesh (synthetic — no real hosts) ─────────────────────────────────────
    await regionShots(browser)
    await galleryShots(browser)

    // ── app mode, files, banners, replay, live updates, web cells ────────────────────────────
    await appShots(browser)
    await filesShots(browser)
    await bannerShots(browser)
    await replayShots(browser)
    await liveShots(browser)
    await webShots(browser)
    await toolShots(browser)
    await sweepShots(browser)
    await clusterShots(browser)
    await slideShots(browser)

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
