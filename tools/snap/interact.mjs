// Scripted interaction test for the Preact notebook — verifies the two core payoffs of the
// migration against the LIVE page: (1) live reactivity (moving a @bind slider updates a
// dependent markdown cell WITHOUT a reload), and (2) editor preservation (a CodeMirror
// instance survives a structural op — adding a cell — instead of being recreated).
// Cleans up after itself (deletes the added cell). Uses the installed Chrome via channel.
//
//   node interact.mjs [notebook-id-or-url]
import { chromium } from 'playwright-core';

const arg = process.argv[2] || 'preact_test';
const url = arg.startsWith('http') ? arg : `http://127.0.0.1:8765/n/${arg}`;

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 1600 } });
const errs = [];
page.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
page.on('pageerror', e => errs.push('pageerror: ' + e.message));

const out = {};
try {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 20000 });
  await page.waitForSelector('#nb .cell', { timeout: 12000 });
  await page.waitForTimeout(1500);

  // ── 1 · live reactivity ─────────────────────────────────────────────────────
  const ampOf = () => page.$eval('#cell-t-md .md', el => (el.textContent.match(/amplitude is (\d+)/) || [])[1]);
  const before = await ampOf();
  await page.$$eval('#cell-controls input[type=range]', els => {
    const amp = els[0]; amp.value = '8';
    amp.dispatchEvent(new Event('input', { bubbles: true }));
    amp.dispatchEvent(new Event('change', { bubbles: true }));
  });
  await page.waitForTimeout(1500);   // bind POST → recompute → state → Preact re-render
  const after = await ampOf();
  out.reactivity = { before, after, pass: after === '8' && before !== after };

  // ── 2 · editor preservation across a structural op (add a cell) ──────────────
  const stamp = await page.evaluate(() => {
    const cm = window.editors['t-value']; if (!cm) return null;
    cm.__pid = 'preserve-probe';                 // stamp the live instance
    cm.setCursor({ line: 0, ch: 5 }); cm.focus();
    return { pid: cm.__pid, cur: cm.getCursor() };
  });
  const beforeIds = await page.evaluate(() => Object.keys(window.editors));
  const added = await page.evaluate(async () => {
    const before = new Set(window.slateStore.nbState.value.cells.map(c => c.id));
    await window.addCell('', 'code');            // structural op — old code wiped ALL editors here
    await new Promise(r => setTimeout(r, 600));
    const now = window.slateStore.nbState.value.cells.map(c => c.id);
    return now.find(id => !before.has(id)) || null;
  });
  await page.waitForTimeout(600);
  const post = await page.evaluate(() => {
    const cm = window.editors['t-value']; if (!cm) return null;
    return { pid: cm.__pid, cur: cm.getCursor() };
  });
  out.editorPreserved = {
    stampedPid: stamp && stamp.pid, survivingPid: post && post.pid, cursor: post && post.cur,
    pass: !!(post && post.pid === 'preserve-probe' && post.cur && post.cur.ch === 5),
  };

  // cleanup: delete the added cell so the notebook is left as it was
  if (added) await page.evaluate(id => window.delCell(id), added).catch(() => {});
  await page.waitForTimeout(400);

  // ── 3 · slider element survives a value echo (drag-safe — not recreated) ─────
  await page.$$eval('#cell-controls input[type=range]', els => { els[0].__probe = 'amp-elt'; });
  await page.$$eval('#cell-controls input[type=range]', els => {
    els[0].value = '6'; els[0].dispatchEvent(new Event('input', { bubbles: true })); els[0].dispatchEvent(new Event('change', { bubbles: true }));
  });
  await page.waitForTimeout(1500);
  out.sliderElementSurvives = await page.$$eval('#cell-controls input[type=range]', els => els[0] && els[0].__probe === 'amp-elt');

  // ── 4 · collapsed editor renders code once expanded (refresh-on-visible) ─────
  const renderedLen = () => page.evaluate(() => (document.querySelector('#cell-setup .CodeMirror-code') || {}).textContent?.length || 0);
  const collapsedLen = await renderedLen();              // collapsed → host hidden, may be 0
  await page.evaluate(() => window.toggleCollapse('setup'));
  await page.waitForTimeout(700);
  const expandedLen = await renderedLen();               // should now show the source
  const hasUsing = await page.evaluate(() => ((document.querySelector('#cell-setup .CodeMirror-code') || {}).textContent || '').includes('using'));
  await page.evaluate(() => window.toggleCollapse('setup')).catch(() => {});   // restore
  out.collapsedEditor = { collapsedLen, expandedLen, hasUsing, pass: hasUsing && expandedLen > 0 };

  out.consoleErrors = errs.filter(e => !/favicon/.test(e));
  console.log(JSON.stringify(out, null, 2));
} finally {
  await browser.close();
}
