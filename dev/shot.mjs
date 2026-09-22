// Screenshot a served Slate notebook, so a UI change can be LOOKED at rather than inferred from
// the DOM. `eval_js` can read state and geometry but cannot show layout, weight or overlap — the
// things a UI is actually judged on.
//
//   node dev/shot.mjs <url> <out.png> [--js "<snippet>"] [--wait ms] [--size WxH] [--sel ".x"]
//
// `--js` runs in the page before the shot (open a panel, start a session); `--sel` shoots one
// element instead of the viewport.
import { chromium } from 'playwright';

const args = process.argv.slice(2);
const [url, out] = args;
if (!url || !out) {
  console.error('usage: node dev/shot.mjs <url> <out.png> [--js "…"] [--wait ms] [--size WxH] [--sel ".x"]');
  process.exit(1);
}
const flag = (name, dflt) => {
  const i = args.indexOf('--' + name);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};
const [w, h] = flag('size', '1600x1000').split('x').map(Number);

// Use whatever Chromium is already in the Playwright cache rather than insisting on the exact
// revision this playwright release pins — the download needs network, the browser is right here,
// and a screenshot does not care about a few revisions.
import { existsSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
function installedChromium() {
  const root = join(homedir(), 'Library', 'Caches', 'ms-playwright');
  if (!existsSync(root)) return undefined;
  const dirs = readdirSync(root).filter(d => /^chromium-\d+$/.test(d))
    .sort((a, b) => Number(b.split('-')[1]) - Number(a.split('-')[1]));
  for (const d of dirs) {
    for (const rel of ['chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing',
                       'chrome-mac/Chromium.app/Contents/MacOS/Chromium']) {
      const p = join(root, d, rel);
      if (existsSync(p)) return p;
    }
  }
  return undefined;
}

const browser = await chromium.launch({ executablePath: installedChromium() });
const page = await browser.newPage({ viewportSize: { width: w, height: h }, deviceScaleFactor: 2 });
// Console errors are the usual reason a pane renders empty; surface them rather than shooting a
// blank box and wondering.
page.on('pageerror', e => console.error('PAGE ERROR:', e.message));
page.on('console', m => { if (m.type() === 'error') console.error('CONSOLE:', m.text()); });

await page.goto(url, { waitUntil: 'networkidle' });
await page.waitForTimeout(Number(flag('wait', 1500)));

const js = flag('js', '');
if (js) {
  try { await page.evaluate(js); } catch (e) { console.error('EVAL ERROR:', e.message); }
  await page.waitForTimeout(Number(flag('wait', 1500)));
}

const sel = flag('sel', '');
if (sel) {
  const el = await page.$(sel);
  if (!el) { console.error('no element matches ' + sel); await browser.close(); process.exit(2); }
  await el.screenshot({ path: out });
} else {
  await page.screenshot({ path: out });
}
console.log('wrote ' + out);
await browser.close();
