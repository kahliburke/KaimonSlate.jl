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
const EXTRA = ['widgets', 'charts']                          // opened over /api/open

mkdirSync(OUT, { recursive: true })
const VIDTMP = mkdtempSync(join(tmpdir(), 'slate-vid-'))

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const log = (...a) => console.log('[assets]', ...a)

// Static per-cell screenshots: { notebookId: { cellId: filename } }.
const CELL_SHOTS = {
  demo: { highlight: 'editor-highlighting.png', chart: 'chart.png', table: 'table.png',
          boom: 'error.png', mdinterp: 'markdown.png' },
  widgets: Object.fromEntries(['slider', 'numberfield', 'checkbox', 'toggle', 'textfield', 'textarea',
    'select', 'radio', 'multiselect', 'multicheckbox', 'colorpicker', 'datefield', 'timefield', 'button']
    .map((w) => [w, `widget-${w}.png`])),
  charts: Object.fromEntries(['line', 'bar', 'area', 'scatter', 'pie', 'heatmap', 'candlestick',
    'radar', 'boxplot', 'composable'].map((c) => [c, `chart-${c}.png`])),
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
    try { if ((await fetch(`${BASE}/n/${FIRST}`)).ok) { log('server up'); return } } catch (_) {}
    await sleep(1000)
  }
  throw new Error('server did not come up')
}
async function openExtra() {
  for (const id of EXTRA) {
    await fetch(`${BASE}/api/open`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path: join(SHOTDIR, id + '.jl') }) })
    log(`opened ${id}`)
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

async function main() {
  const server = startServer()
  let browser
  const cleanup = () => { try { browser?.close() } catch (_) {} ; try { server.kill('SIGTERM') } catch (_) {} }
  process.on('exit', cleanup); process.on('SIGINT', () => { cleanup(); process.exit(1) })
  try {
    await waitForServer()
    await openExtra()
    browser = await chromium.launch({ headless: true })

    // ── per-notebook static cell screenshots ────────────────────────────────────────────────
    for (const [id, shots] of Object.entries(CELL_SHOTS)) {
      const page = await (await newContext(browser)).newPage()
      await runNotebook(page, id)
      if (id === 'demo') { await page.evaluate(() => window.scrollTo(0, 0)); await page.screenshot({ path: join(OUT, 'overview.png') }); log('✓ overview.png') }   // viewport, not the giant full page
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

        // history / time-machine panel
        try {
          await page.evaluate(() => window.toggleHistory && window.toggleHistory())
          await page.waitForSelector('#histpanel.open .hrow', { timeout: 6000 })
          await sleep(500)
          await elShot(page, '#histpanel', 'history-panel.png')
          await page.evaluate(() => window.toggleHistory && window.toggleHistory())
        } catch (e) { log('! history-panel skipped:', e.message.split('\n')[0]) }

        // settings modal
        try {
          await page.evaluate(() => window.openSettings && window.openSettings())
          await elShot(page, '.setmodal', 'settings.png')
          await page.evaluate(() => window.closeSettings && window.closeSettings())
        } catch (e) { log('! settings skipped:', e.message.split('\n')[0]) }
      }

      if (id === 'widgets') {
        // controls palette — every @bind across the notebook
        try {
          await page.evaluate(() => window.togglePalette && window.togglePalette())
          await sleep(600)
          await elShot(page, '.palette', 'controls-palette.png')
        } catch (e) { log('! controls-palette skipped:', e.message.split('\n')[0]) }
      }
      await page.context().close()
    }

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
