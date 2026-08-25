// Extension asset generator — a screenshot of an extension's canonical demo notebook.
//
// The sibling of generate_assets.mjs, which captures Slate's own UI. This one exists so that an
// extension gets SOME card imagery in the Extensions gallery for free: it builds a throwaway project
// with KaimonSlate plus the extension, serves the extension's demo notebook, runs it, and photographs
// the page.
//
// Deliberately unclever. It does not drive controls, pick a hero cell, or try to compose an
// attractive shot — an author who wants good imagery should make it and point `screenshots` at it in
// SlateExtension.toml. This is the floor, not the ceiling: a picture of the extension's own notebook,
// generated from a file the author already maintains, so it can't drift from the code.
//
// The output lands OUTSIDE the package by default, because the intended workflow is to HOST the
// image and reference it by URL, not to commit it. Screenshots get regenerated often, and a package
// repository is a bad place to accumulate them; the catalog build mirrors whatever URL you give it
// into the published artifact anyway, so your host only has to be reachable at build time.
//
//   node docs/generate_extension_assets.mjs --path examples/extensions/StarRating
//
// Options (only --path is required):
//   --path <dir>       the extension package (must contain Project.toml)
//   --notebook <file>  demo notebook; default: the `example` key of SlateExtension.toml
//   --out <dir>        output directory; default: a scratch dir under the system temp dir
//   --cell <id>        frame this cell; default: the first one that rendered a visual output
//   --full             capture the whole scrolling page instead of one screenful
//   --port <n>         port for the throwaway hub (default 8797)
//
// Requires `npx playwright install chromium` once, and `julia` on PATH.

import { chromium } from 'playwright'
import { spawn, spawnSync } from 'node:child_process'
import { mkdirSync, existsSync, readFileSync } from 'node:fs'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve, basename } from 'node:path'
import { fileURLToPath } from 'node:url'

const DOCS = dirname(fileURLToPath(import.meta.url))
const REPO = dirname(DOCS)

// ── args ──────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2)
const arg = (name, dflt = null) => {
  const i = argv.indexOf('--' + name)
  return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[i + 1] : dflt
}
const flag = (name) => argv.includes('--' + name)

const PKGDIR = resolve(arg('path') || '')
if (!PKGDIR || !existsSync(join(PKGDIR, 'Project.toml'))) {
  console.error('need --path <extension dir containing Project.toml>')
  process.exit(2)
}
const PKGNAME = (readFileSync(join(PKGDIR, 'Project.toml'), 'utf8').match(/^name\s*=\s*"([^"]+)"/m) || [, basename(PKGDIR)])[1]

// The demo notebook: an explicit --notebook, else the `example` key the author already declared for
// the gallery. Reusing that key keeps "the notebook the catalog links to" and "the notebook the
// picture comes from" from drifting apart.
function exampleFromToml() {
  const f = join(PKGDIR, 'SlateExtension.toml')
  if (!existsSync(f)) return null
  const m = readFileSync(f, 'utf8').match(/^\s*example\s*=\s*"([^"]+)"/m)
  return m ? m[1] : null
}
const NOTEBOOK = resolve(arg('notebook') || join(PKGDIR, exampleFromToml() || ''))
if (!existsSync(NOTEBOOK)) {
  console.error(`no demo notebook — pass --notebook, or set \`example\` in ${PKGNAME}'s SlateExtension.toml`)
  process.exit(2)
}
// Scratch by default — see the header. `--out` into the repo is still allowed if you really want it.
const OUT = resolve(arg('out') || join(tmpdir(), 'slate-ext-assets'))
const PORT = Number(arg('port', '8797'))
const BASE = `http://127.0.0.1:${PORT}`
// `serve_notebook` mounts the notebook at /n/<stem>; BASE alone is the notebook CHOOSER, which has
// no cells and would just time out waiting for one.
const NB_ID = basename(NOTEBOOK).replace(/\.jl$/, '')
const NBURL = `${BASE}/n/${NB_ID}`
const FEATURE = arg('cell', '')     // '' = pick the first cell that rendered a visual output
const SHOT = join(OUT, `${PKGNAME}-notebook.png`)

mkdirSync(OUT, { recursive: true })
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const log = (...a) => console.log('[ext-assets]', ...a)

// ── a throwaway project with KaimonSlate + the extension ──────────────────────
// Built fresh rather than reusing the extension's own env: an extension depends on the SDK, not on
// KaimonSlate, so its own project can't serve a notebook.
/**
 * Every package the demo notebook imports, beyond the ones we already develop.
 *
 * A notebook's `using X` needs X as a DIRECT dependency of the environment it runs in. Depending on
 * X transitively is not enough — GiacSlate depends on Giac, and its notebook still failed with
 * "Package Giac not found", because a package's own deps aren't visible at top level. So the
 * notebook's imports are its real dependency list, and this reads them off the source.
 *
 * `using Giac.Commands: …` counts as `Giac`; `using A, B` counts as both.
 */
function notebookImports() {
  const src = readFileSync(NOTEBOOK, 'utf8')
  const names = new Set()
  for (const m of src.matchAll(/^\s*(?:using|import)\s+([A-Z][\w.,\s]*)/gm)) {
    for (const part of m[1].split(',')) {
      const base = part.trim().split(/[.:\s]/)[0]
      if (/^[A-Z]\w*$/.test(base)) names.add(base)
    }
  }
  // Already developed from source, so adding them from a registry would fight the path entries.
  for (const own of [PKGNAME, 'KaimonSlate', 'SlateExtensionsBase']) names.delete(own)
  return [...names]
}

function buildEnv() {
  const env = mkdtempSync(join(tmpdir(), 'slate-extenv-'))
  const extra = notebookImports()
  log(`resolving a project for ${PKGNAME}${extra.length ? ` (+ ${extra.join(', ')})` : ''} (this precompiles once)`)
  // Extras are added one at a time and failures swallowed: a notebook may import something
  // unregistered or unresolvable, and that should cost the run one missing package rather than the
  // whole screenshot. Anything that fails simply errors in its own cell, visibly.
  const addExtra = extra.map((n) =>
    `try; Pkg.add(${JSON.stringify(n)}); catch e; @warn "skipping ${n}" e; end`).join('\n    ')
  const code = `
    using Pkg
    Pkg.activate(raw"${env}")
    Pkg.develop([PackageSpec(path=raw"${REPO}"), PackageSpec(path=raw"${join(REPO, 'lib', 'SlateExtensionsBase')}"), PackageSpec(path=raw"${PKGDIR}")])
    ${addExtra}
    Pkg.precompile()
  `
  const r = spawnSync('julia', ['--startup-file=no', '--color=no', '-e', code], { stdio: 'inherit' })
  if (r.status !== 0) { console.error('could not build the project'); process.exit(1) }
  return env
}

function startServer(env) {
  log(`serving ${basename(NOTEBOOK)} on :${PORT}`)
  const jl = `using KaimonSlate; KaimonSlate.serve_notebook(raw"${NOTEBOOK}"; port=${PORT})`
  const proc = spawn('julia', [`--project=${env}`, '--color=no', '-e', jl],
    { cwd: REPO, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, KAIMONSLATE_NO_OPEN: '1' } })
  proc.stdout.on('data', (d) => process.stdout.write(`[server] ${d}`))
  proc.stderr.on('data', (d) => process.stderr.write(`[server] ${d}`))
  return proc
}

async function waitForServer(timeoutMs = 300_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try { if ((await fetch(NBURL, { headers: { Connection: 'close' } })).ok) { log('server up'); return } } catch (_) {}
    await sleep(1000)
  }
  throw new Error('server did not come up')
}

/**
 * Wait until the notebook is genuinely idle: not hydrating (worker boot / env reconstruction), and
 * no cell running or stale.
 *
 * Held across CONSECUTIVE samples rather than checked once — a run passes through brief idle-looking
 * moments between cells, and reconstruction can restart the whole run after it appears to finish.
 * A single check catches one of those gaps and photographs a half-computed notebook.
 */
async function settle(page, timeoutMs, stableSamples = 4, everyMs = 700) {
  const deadline = Date.now() + timeoutMs
  let stable = 0
  while (Date.now() < deadline) {
    const idle = await page.evaluate(() => {
      const s = window.__slateState || {}
      if (s.hydrating) return false
      const cs = s.cells || []
      return cs.length > 0 && cs.every((c) => c.state !== 'running' && c.state !== 'stale')
    }).catch(() => false)
    stable = idle ? stable + 1 : 0
    if (stable >= stableSamples) return true
    await sleep(everyMs)
  }
  log('! notebook did not settle — capturing anyway')
  return false
}

async function main() {
  const env = buildEnv()
  const server = startServer(env)
  let browser
  const cleanup = () => { try { browser?.close() } catch (_) {}; try { server.kill('SIGTERM') } catch (_) {} }
  process.on('exit', cleanup)
  process.on('SIGINT', () => { cleanup(); process.exit(1) })
  try {
    await waitForServer()
    // No WebGL flags needed: Playwright's headless Chromium already reports
    // "ANGLE (SwiftShader)" and passes a webgl2 context, so a blank 3-D canvas is an asset-loading
    // or timing problem rather than a missing GPU. Verified rather than assumed.
    browser = await chromium.launch({ headless: true })
    const ctx = await browser.newContext({ viewport: { width: 1100, height: 860 }, deviceScaleFactor: 2, colorScheme: 'dark' })
    await ctx.addInitScript(() => { try { localStorage.setItem('slateTheme', 'dark'); localStorage.setItem('slateSyntaxTheme', 'dark-plus') } catch (_) {} })
    const page = await ctx.newPage()

    await page.goto(NBURL, { waitUntil: 'domcontentloaded' })
    await page.waitForSelector('.cell', { timeout: 60_000 })

    // Wait for the worker and its environment BEFORE asking for a run. `state.hydrating` covers
    // worker boot and env reconstruction; skipping it photographs a "Reconstructing environment…"
    // banner over half-computed cells.
    log('waiting for the worker and environment')
    await settle(page, 600_000)

    // The id comes from OUR side, not the page. `NB_ID` is a top-level `const` in a classic script,
    // so it lives in script scope and `window.NB_ID` is undefined — every re-run request was going to
    // `/api/undefined/rerun-all` and silently 404ing, leaving the notebook on whatever its initial
    // autorun produced. (docs/generate_assets.mjs reads it the same way and has the same bug.)
    await page.evaluate(async (id) => {
      try { await fetch(`/api/${id}/rerun-all`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }) } catch (_) {}
    }, NB_ID)
    log('running the notebook')
    await settle(page, 600_000)

    // Hide Slate's own transient chrome — the standalone world-age warning, the docs launcher, and
    // the run pill / progress toast, which are about Slate rather than about the extension.
    await page.addStyleTag({ content: '.warn,#doclauncher,#runpill{display:none!important}' })
    await sleep(1400)

    // Frame the first cell that actually DREW something, not the top of the document. A good demo
    // notebook opens with prose explaining itself, so capturing from the top reliably photographs
    // the introduction and leaves the chart the extension exists to produce below the fold.
    //
    // "Drew something" is decided by the rendered output containing a canvas/svg/image — the shapes
    // every visual output takes — rather than by guessing at cell ids or the extension's semantics.
    const framed = await page.evaluate((wanted) => {
      const cells = [...document.querySelectorAll('.cell')]
      const target = wanted
        ? cells.find((c) => c.dataset.cid === wanted)
        : cells.find((c) => c.querySelector('.output canvas, .output svg, .output img, .echart canvas, .echart svg'))
      if (!target) return null
      target.scrollIntoView({ block: 'start' })
      window.scrollBy(0, -12)                       // a sliver of the cell above, so it doesn't read as cropped
      return target.dataset.cid || ''
    }, FEATURE)
    log(framed === null ? 'no rendered output found — framing the top of the notebook' : `framing cell ${framed}`)
    await sleep(600)
    await page.screenshot({ path: SHOT, fullPage: flag('full') })

    log(`✓ ${SHOT}`)
    log('upload it somewhere you host — Pages, a release asset, a CDN — then reference the URL:')
    log(`  screenshots = ["https://<your host>/${basename(SHOT)}"]`)
    log('(the catalog build mirrors it into the published artifact, so committing it is unnecessary)')
  } finally {
    cleanup()
  }
}

main().catch((e) => { console.error(e); process.exit(1) })
