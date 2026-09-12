// Record a short demo clip of an extension's notebook — the companion to
// `generate_extension_assets.mjs`, which only photographs.
//
// A screenshot cannot show the thing this extension is actually for: a control moving while the
// figure updates IN PLACE, rather than the whole cell being rebuilt. So this drives the controls
// and films the result.
//
// Unlike the screenshot generator it does NOT build a project — it attaches to a notebook you are
// already serving, so what gets filmed is the notebook you have been looking at.
//
//   node docs/record_extension_demo.mjs --url http://127.0.0.1:8912/n/bind_live --out /tmp/demo
//
// Options:
//   --url <url>       the served notebook (required)
//   --out <dir>       where the .webm lands (default: a temp dir, printed on exit)
//   --cell <id>       film ONE cell: scroll to it, rotate its canvas, drive only its controls
//   --seconds <n>     roughly how long to drive the controls for (default 14)
//   --width/--height  viewport (default 1280x900)
//   --mp4 <path>      also trim the load, speed up and transcode to mp4 (needs ffmpeg)
//   --speed <n>       playback speed for the mp4 (default 2.5) — see the transcode note below
//   --fps <n>         output frame rate (default 30)
//   --canvas-slider <yFrac>  also drag a Makie SliderGrid drawn inside the canvas, at this
//                     fraction of the canvas height (a row under the plot is ~0.95)
import { chromium } from 'playwright'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const arg = (k, d) => {
  const i = process.argv.indexOf(`--${k}`)
  return i === -1 ? d : process.argv[i + 1]
}

const URL = arg('url')
if (!URL) { console.error('need --url <served notebook url>'); process.exit(1) }
const OUT = arg('out', mkdtempSync(join(tmpdir(), 'slate-demo-')))
const SECONDS = Number(arg('seconds', 14))
const W = Number(arg('width', 1280)), H = Number(arg('height', 900))

const sleep = ms => new Promise(r => setTimeout(r, ms))

// Drag a range input with the REAL mouse, not by setting `.value` and dispatching `input`.
//
// Slate deliberately keys its widget handling on a genuine pointer, so it can tell a user's drag
// from the programmatic reflect it performs when a value arrives from elsewhere (see core.js). A
// synthetic `input` event has no pointer behind it and is correctly ignored — which films a slider
// sliding while the figure it supposedly drives never moves.
async function sweep(page, index, from, to, steps, dwell) {
  const box = await page.evaluate(({ index, sel }) => {
    const root = sel ? document.querySelector(sel) : document
    const el = root.querySelectorAll('input[type=range]')[index]
    if (!el) return null
    // Scroll ONLY if the control is off-screen, and then as little as possible. Centring on the
    // slider would frame the slider — which for a control above the figure pushes the figure
    // itself out of the bottom of the clip, so the clip films a knob moving and nothing else.
    const r0 = el.getBoundingClientRect()
    if (r0.top < 0 || r0.bottom > window.innerHeight) el.scrollIntoView({ block: 'nearest' })
    const r = el.getBoundingClientRect()
    return { x: r.x, y: r.y, w: r.width, h: r.height }
  }, { index, sel: SCOPE })
  if (!box || box.w < 20) return false

  const at = frac => ({ x: box.x + box.w * Math.min(Math.max(frac, 0.02), 0.98),
                        y: box.y + box.h / 2 })

  const start = at(from)
  await page.mouse.move(start.x, start.y)
  await page.mouse.down()
  for (let s = 1; s <= steps; s++) {
    const p = at(from + (to - from) * (s / steps))
    await page.mouse.move(p.x, p.y)
    await sleep(dwell)
  }
  await page.mouse.up()
  return true
}

// Drag across a figure's canvas to rotate it. `Axis3` has no client-side camera: WGLMakie sends the
// drag to Julia, which updates azimuth/elevation and pushes the new scene back — so this films the
// live channel working, not just a first paint.
//
// The drag starts in the UPPER part of the canvas on purpose. A Makie `SliderGrid` is drawn INSIDE
// the scene, usually along the bottom, and a drag that lands on it moves that slider instead of
// orbiting the camera.
async function rotate(page, cellSel, dx, dy, steps, dwell) {
  const box = await page.evaluate(sel => {
    const root = sel ? document.querySelector(sel) : document
    const c = root && root.querySelector('canvas')
    if (!c) return null
    const r = c.getBoundingClientRect()
    return { x: r.x, y: r.y, w: r.width, h: r.height }
  }, cellSel)
  if (!box || box.w < 50) return false

  const sx = box.x + box.w / 2, sy = box.y + box.h * 0.35
  await page.mouse.move(sx, sy)
  await page.mouse.down()
  for (let s = 1; s <= steps; s++) {
    await page.mouse.move(sx + (dx * s) / steps, sy + (dy * s) / steps)
    await sleep(dwell)
  }
  await page.mouse.up()
  return true
}

import { execFileSync } from 'node:child_process'
import { readdirSync } from 'node:fs'

const browser = await chromium.launch()
const context = await browser.newContext({
  viewport: { width: W, height: H },
  recordVideo: { dir: OUT, size: { width: W, height: H } },
  colorScheme: 'dark',
})
const page = await context.newPage()
const T0 = Date.now()          // recording starts with the context; everything before READY is trimmed

console.log(`[demo] opening ${URL}`)
// NOT `networkidle`: a live notebook holds an SSE stream open for as long as it is open, so the
// network never goes idle and the wait can only ever time out. The canvas-paint check below is the
// real readiness signal anyway.
await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 120_000 })

// Wait for the WebGL figures to actually paint — a canvas element exists well before it has drawn,
// so filming on element-presence catches an empty card.
const CELL0 = (() => { const i = process.argv.indexOf('--cell'); return i === -1 ? '' : process.argv[i+1] })()
await page.waitForFunction(sel => {
  const root = sel ? document.querySelector(sel) : document
  if (!root) return false
  return [...root.querySelectorAll('canvas')].some(c => c.width > 50 && c.height > 50)
}, CELL0 ? `#cell-${CELL0}` : '', { timeout: 240_000 })
await sleep(3000)

const CELL = arg('cell', '')
const SCOPE = CELL ? `#cell-${CELL}` : ''
if (CELL) {
  const found = await page.evaluate(sel => !!document.querySelector(sel), SCOPE)
  if (!found) { console.error(`[demo] no cell "${CELL}" on the page`); await browser.close(); process.exit(1) }
}

// When filming one cell, drive ONLY its own controls. A notebook-wide sweep otherwise spends the
// clip on sliders belonging to figures that are scrolled out of frame.
const sliders = await page.evaluate(sel => {
  const root = sel ? document.querySelector(sel) : document
  return root.querySelectorAll('input[type=range]').length
}, SCOPE)
console.log(`[demo] ${sliders} range control(s)${CELL ? ` in ${CELL}` : ' on the page'}`)

// Frame the CELL being filmed, not the top of the document — and align its top rather than its
// centre, so the controls (which sit above the figure) and the figure are both in the clip. A tall
// figure card is taller than the viewport; centring it loses whichever end is being driven.
const frame = () => page.evaluate(sel => {
  const cell = sel ? document.querySelector(sel) : document.body
  if (!cell) return
  const top = cell.getBoundingClientRect().top + window.scrollY
  window.scrollTo({ top: Math.max(0, top - 56), behavior: 'instant' })   // 56px clears the header
}, SCOPE)
await frame()
await sleep(1800)
const READY = (Date.now() - T0) / 1000   // load + first paint: dead air at the head of the clip

// Rotate first, so the clip opens by establishing that this is a live 3D scene.
await rotate(page, SCOPE, 85, 30, 24, 28)
await sleep(700)

await frame()                  // the rotate drag can nudge the page; put it back before the sweeps
await sleep(800)

// Drive a handful of controls in turn. Each sweep is a real press-move-release, so the figure it
// drives updates as it would under a hand.
const N = Math.min(sliders, 4)
const per = Math.max(400, Math.floor((SECONDS * 1000) / Math.max(1, N) / 2))
for (let i = 0; i < N; i++) {
  const ok = await sweep(page, i, 0.15, 0.85, 18, per / 18)
  if (!ok) { console.log(`[demo] slider ${i} not draggable — skipped`); continue }
  await sleep(400)
  await sweep(page, i, 0.85, 0.40, 12, per / 12)
  await sleep(600)
}

// A Makie `SliderGrid` is drawn INSIDE the canvas, so it is not an `input[type=range]` and the
// sweeps above cannot reach it — it has no DOM at all. Drag it by screen position instead:
// `--canvas-slider <yFrac>` is where across the canvas's height the row sits (a SliderGrid under a
// plot is near the bottom, so ~0.95). Worth filming, because a control drawn in the scene is the
// baseline the HTML-side controls are trying to feel like.
const CSY = arg('canvas-slider', '')
if (CSY) {
  await frame()
  const box = await page.evaluate(sel => {
    const c = (sel ? document.querySelector(sel) : document).querySelector('canvas')
    if (!c) return null
    const r = c.getBoundingClientRect()
    return { x: r.x, y: r.y, w: r.width, h: r.height }
  }, SCOPE)
  if (box) {
    const y = box.y + box.h * Number(CSY)
    await page.mouse.move(box.x + box.w * 0.06, y)
    await page.mouse.down()
    for (let s = 1; s <= 16; s++) {
      await page.mouse.move(box.x + box.w * (0.06 + 0.60 * s / 16), y)
      await sleep(60)
    }
    await page.mouse.up()
    await sleep(900)
  }
}

// Rotate once more at the end: the camera should still be where the controls left it, because
// nothing rebuilt the scene.
await rotate(page, SCOPE, -70, -22, 20, 28)
await sleep(1500)
await context.close()          // flushes the video file
await browser.close()
const webm = readdirSync(OUT).find(f => f.endsWith('.webm'))
console.log(`[demo] ✓ ${OUT}/${webm}`)

// Trim the head and transcode:
//
//   TRIM   the clip opens on the figure already framed, not on a notebook scrolling past and a
//          canvas that has not painted yet.
//   SPEED  the recording runs slower than the same interaction feels in a real browser, so
//          `--speed` compresses it back to something watchable.
//   SMOOTH frames also arrive unevenly, which reads as stutter. Resampling to a constant frame
//          rate with blended intermediates evens it out without inventing motion — motion-
//          compensated interpolation would, and it smears a rotating surface badly.
const MP4 = arg('mp4', '')
if (MP4 && webm) {
  const ss = Math.max(0, READY - 0.6).toFixed(2)   // a beat before the first gesture
  const speed = Number(arg('speed', 2.5))
  const fps = Number(arg('fps', 30))
  const vf = `setpts=PTS/${speed},minterpolate=fps=${fps}:mi_mode=blend`
  try {
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-ss', ss, '-i', join(OUT, webm),
      '-vf', vf, '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '23',
      '-fps_mode', 'cfr', '-r', String(fps), '-movflags', '+faststart', MP4], { stdio: 'inherit' })
    console.log(`[demo] ✓ ${MP4} (trimmed ${ss}s, ${speed}× , ${fps}fps)`)
  } catch (e) {
    console.log(`[demo] ffmpeg not available — the .webm is there: ${e.message}`)
  }
} else if (webm) {
  console.log('[demo] pass --mp4 <path> to trim the load and transcode')
}
