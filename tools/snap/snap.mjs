// Headless snapshot of a live Slate notebook — a window into the FRONTEND.
//
// The worker's canonical output is visible via slate_read / slate_view; this instead shows what
// the browser's Preact actually renders, which is where frontend bugs live. It captures, for a
// notebook URL: the console log + page errors, the rendered #nb HTML, a frontend state dump
// (store cells, mounted editors, selection), and a full-page PNG. Uses the installed Chrome via
// playwright-core, so there is no browser download.
//
//   node snap.mjs [notebook-id-or-url] [outDir=/tmp/slate-snap]
//
// Outputs to <outDir>: nb.html, console.txt, state.json, page.png — and prints state + console.
import { chromium } from 'playwright-core';
import { mkdirSync, writeFileSync } from 'node:fs';

const arg = process.argv[2] || 'preact_test';
const url = arg.startsWith('http') ? arg : `http://127.0.0.1:8765/n/${arg}`;
const outDir = process.argv[3] || '/tmp/slate-snap';
mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 1280, height: 1600 } });
const logs = [];
page.on('console', m => logs.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', e => logs.push(`[pageerror] ${e.message}\n${e.stack || ''}`));
page.on('requestfailed', r => logs.push(`[requestfailed] ${r.url()} — ${r.failure()?.errorText || ''}`));
page.on('response', r => { if (r.status() >= 400) logs.push(`[http ${r.status()}] ${r.url()}`); });

try {
  // The notebook holds a live update connection, so the network never goes idle — wait on the
  // DOM + the first rendered cell instead.
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 20000 });
  await page.waitForSelector('#nb .cell', { timeout: 12000 }).catch(() => {});
  await page.waitForTimeout(1500);   // let charts / KaTeX / figures settle

  const html = await page.$eval('#nb', el => el.outerHTML).catch(() => '(#nb not found)');
  const state = await page.evaluate(() => {
    const s = window.slateStore || {};
    const cells = (s.nbState && s.nbState.value && s.nbState.value.cells) || [];
    const per = cells.map(c => {
      const el = document.getElementById('cell-' + c.id);
      const out = el && el.querySelector('.output');
      const md = el && el.querySelector('.md');
      const txt = (out || md);
      return {
        id: c.id, kind: c.kind, state: c.state, bind: !!(c.binds && c.binds.length),
        cls: el ? el.className : null, dom: !!el,
        hasCM: el ? !!el.querySelector('.CodeMirror') : null,
        // rendered text of the output (or markdown), trimmed — surfaces errors without the
        // huge base64 of figure cells.
        text: txt ? txt.textContent.replace(/\s+/g, ' ').trim().slice(0, 500) : null,
      };
    });
    return {
      url: location.href,
      nbChildren: (document.getElementById('nb') || {}).childElementCount,
      storeCellCount: s.cells && s.cells.value && s.cells.value.length,
      editors: Object.keys(window.editors || {}),
      selected: s.selected && s.selected.value,
      cells: per,
    };
  }).catch(e => ({ error: String(e) }));

  writeFileSync(`${outDir}/nb.html`, html);
  writeFileSync(`${outDir}/console.txt`, logs.join('\n') || '(none)');
  writeFileSync(`${outDir}/state.json`, JSON.stringify(state, null, 2));
  await page.screenshot({ path: `${outDir}/page.png`, fullPage: true });

  console.log('=== STATE ===\n' + JSON.stringify(state, null, 2));
  console.log(`\n=== CONSOLE (${logs.length}) ===\n` + (logs.join('\n') || '(none)'));
  console.log(`\n=== FILES ===\n${outDir}/{nb.html, console.txt, state.json, page.png}`);
} finally {
  await browser.close();
}
