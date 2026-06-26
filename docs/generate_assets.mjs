// Doc asset generator — headless screenshots of the live Slate web UI.
//
// Boots a STANDALONE Slate server (`serve_notebook`, in-process kernel — no Kaimon, no gate
// worker) on a spare port, opens a curated demo notebook, drives a few UI states, and captures
// PNGs into docs/src/assets/. CI (.github/workflows/Docs.yml) runs this after `npx playwright
// install chromium`, then uploads the PNGs to the `docs-assets` GitHub Release; the docs build
// consumes them via KAIMONSLATE_ASSET_BASE. Run locally:  node docs/generate_assets.mjs
//
// Everything is reproducible from the repo: no system Chrome (Playwright's bundled chromium),
// no external packages in the demo (only Base + Slate's injected helpers: @bind, echart,
// slate_table), and the server is torn down on exit.

import { chromium } from 'playwright'
import { spawn } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const DOCS = dirname(fileURLToPath(import.meta.url))           // .../KaimonSlate.jl/docs
const REPO = dirname(DOCS)
const OUT = join(DOCS, 'src', 'assets')
const NOTEBOOK = join(DOCS, 'screenshots', 'demo.jl')
const PORT = Number(process.env.SLATE_DOCS_PORT || 8799)      // off the extension's default 8765
const NB = 'demo'                                             // serve_notebook → /n/<basename>
const BASE = `http://127.0.0.1:${PORT}`
const SCALE = 2                                               // retina-crisp PNGs

mkdirSync(OUT, { recursive: true })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const log = (...a) => console.log('[assets]', ...a)

// ── boot the standalone Slate server as a child process ──────────────────────────────────────
function startServer() {
  log(`starting serve_notebook on :${PORT} (${NOTEBOOK})`)
  const jl = `using KaimonSlate; KaimonSlate.serve_notebook(raw"${NOTEBOOK}"; port=${PORT})`
  const proc = spawn('julia', [`--project=${DOCS}`, '--color=no', '-e', jl], {
    cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'],
  })
  proc.stdout.on('data', (d) => process.stdout.write(`[server] ${d}`))
  proc.stderr.on('data', (d) => process.stderr.write(`[server] ${d}`))
  proc.on('exit', (code) => log(`server exited (${code})`))
  return proc
}

async function waitForServer(timeoutMs = 180_000) {
  const url = `${BASE}/n/${NB}`
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const r = await fetch(url)
      if (r.ok) { log('server is up'); return }
    } catch (_) { /* not yet */ }
    await sleep(1000)
  }
  throw new Error(`server did not come up at ${url} within ${timeoutMs}ms`)
}

// ── capture helpers ──────────────────────────────────────────────────────────────────────────
async function openNotebook(browser) {
  const ctx = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    deviceScaleFactor: SCALE,
    colorScheme: 'dark',
  })
  const page = await ctx.newPage()
  // Pin the dark notebook + default syntax theme so screenshots are deterministic.
  await page.addInitScript(() => {
    try { localStorage.setItem('slateTheme', 'dark'); localStorage.setItem('slateSyntaxTheme', 'dark-plus'); } catch (_) {}
  })
  // NOT 'networkidle' — the notebook holds a persistent SSE connection, so the network is never
  // idle. Wait for DOM + the first rendered cell instead.
  await page.goto(`${BASE}/n/${NB}`, { waitUntil: 'domcontentloaded' })
  await page.waitForSelector('.cell', { timeout: 30_000 })
  // Run every cell so outputs (chart/table/error) render, then let them settle.
  const id = await page.evaluate(() => window.NB_ID)
  await page.evaluate(async (id) => {
    try { await fetch(`/api/${id}/rerun-all`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }) } catch (_) {}
  }, id)
  await page.waitForFunction(() => {
    const cells = (window.__slateState && window.__slateState.cells) || []
    return cells.length > 0 && cells.every((c) => c.state !== 'running' && c.state !== 'stale')
  }, { timeout: 60_000 }).catch(() => {})
  // Hide stderr `.warn` blocks: standalone in-process eval emits a benign world-age notice for the
  // injected @bind sink that never appears in real (gate-worker) use — so it shouldn't be in docs.
  await page.addStyleTag({ content: '.warn{display:none!important}' })
  await sleep(1200)                                            // chart animation + layout settle
  return page
}

// Screenshot a single cell (by its id). `locator.screenshot` auto-scrolls the element into view
// and captures exactly its box — robust regardless of where the cell sits in the (tall) page.
async function cellShot(page, cid, name) {
  const loc = page.locator(`.cell[data-cid="${cid}"]`)
  if (!(await loc.count())) { log(`! cell ${cid} not found — skipping ${name}`); return }
  await loc.screenshot({ path: join(OUT, name) })
  log(`✓ ${name}`)
}

async function fullShot(page, name) {
  await page.screenshot({ path: join(OUT, name), fullPage: true })
  log(`✓ ${name}`)
}

async function main() {
  const server = startServer()
  let browser
  const cleanup = () => { try { browser?.close() } catch (_) {} ; try { server.kill('SIGTERM') } catch (_) {} }
  process.on('exit', cleanup); process.on('SIGINT', () => { cleanup(); process.exit(1) })
  try {
    await waitForServer()
    browser = await chromium.launch({ headless: true })
    const page = await openNotebook(browser)

    // 1) Whole-notebook overview.
    await fullShot(page, 'overview.png')

    // 2) The editor — tree-based Julia syntax highlighting (code cells show an always-on editor).
    await cellShot(page, 'highlight', 'editor-highlighting.png')

    // 3) Widget + reactive ECharts chart.
    await cellShot(page, 'slider', 'widget.png')
    await cellShot(page, 'chart', 'chart.png')

    // 4) Interactive table.
    await cellShot(page, 'table', 'table.png')

    // 5) Error UX — offending line highlighted + clickable message.
    await cellShot(page, 'boom', 'error.png')

    // 6) Completion popup + doc-preview card. The popup is positioned OUTSIDE the cell element, so
    //    scroll the cell near the top and grab the viewport (cell + popup together).
    try {
      await page.locator('.cell[data-cid="chart"]').scrollIntoViewIfNeeded()
      await page.evaluate(() => window.scrollBy(0, -120))       // leave room below for the popup
      await page.evaluate(() => {
        const v = window.editors['chart']; v.focus()
        const end = v.state.doc.length
        v.dispatch({ changes: { from: end, insert: '\nround' }, selection: { anchor: end + 6 } })
        window.CM6 && window.CM6.startCompletion && window.CM6.startCompletion(v)
      })
      await page.waitForSelector('.cm-tooltip-autocomplete', { timeout: 5000 })
      await sleep(800)                                          // let the doc-preview card load
      await page.screenshot({ path: join(OUT, 'completion.png') })   // viewport (cell + popup)
      log('✓ completion.png')
    } catch (e) { log('! completion shot skipped:', e.message) }

    log('done — assets in', OUT)
  } finally {
    cleanup()
  }
}

main().catch((e) => { console.error(e); process.exit(1) })
