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
      await p2.evaluate(() => { const c = document.querySelector('#published .sitecard'); if (c) c.click() })
      await sleep(500)
      await shotCropped(p2, '#published', 'sites-strip.png', null, 6)
      await p2.evaluate(() => window.openPubDash && window.openPubDash())
      await sleep(1000)
      await elShot(p2, '#pubdashbg .pubdash', 'publishing-manager.png')
      await p2.context().close()
    } catch (e) { log('! publishing shots skipped:', e.message.split('\n')[0]) }

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
