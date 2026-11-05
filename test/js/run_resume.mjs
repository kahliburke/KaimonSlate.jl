// runstatus.js picking a run up from a full state: a page that loads mid-run gets no `cellrun:` for the
// cells already running, so it learns of them, their start and their bars from /api/state. Also pins
// that bars are kept per cell, and that a state older than the run's start doesn't end it.
//
// The real file is evaluated against a stub DOM, never restated.
//
//   node test/js/run_resume.mjs      # exit 0 = pass, 1 = mismatch, 2 = load failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const SRC = join(here, '..', '..', 'src', 'assets', 'js', 'runstatus.js');

let bad = 0;
const ok = (cond, m) => { if (!cond) { console.error('run_resume: ' + m); bad++; } };

// Just enough DOM for the cell bars and the elapsed-time slot.
const cells = {};
function cell(id) {
  const el = {
    kids: [], cdur: { textContent: '' },
    querySelector(sel) {
      if (sel === ':scope > .cellprog') return this.kids.find(k => k.className === 'cellprog') || null;
      return null;
    },
    insertBefore(n) { this.kids.unshift(n); n.remove = () => { this.kids = this.kids.filter(k => k !== n); }; },
    firstChild: null,
  };
  cells[id] = el;
  return el;
}
['a', 'b', 'c'].forEach(cell);
const document = {
  getElementById: () => null,
  querySelectorAll: () => [],
  createElement: () => ({ className: '', innerHTML: '', style: {} }),
  querySelector(sel) {
    const m = sel.match(/^\.cell\[data-cid="([^"]+)"\]( \.cdur)?$/);
    if (!m || !cells[m[1]]) return null;
    return m[2] ? cells[m[1]].cdur : cells[m[1]];
  },
};
const live = {};
const window = {
  slateDuration: ms => String(Math.round(ms / 1000)),
  slateEscHtml: s => s,
  slateStore: { setLiveState: (id, s) => { live[id] = s; } },
};

try {
  new Function('window', 'document', readFileSync(SRC, 'utf8'))(window, document);
} catch (e) {
  console.error('run_resume: could not evaluate runstatus.js — ' + e.message);
  process.exit(2);
}
const bar = id => { const b = cells[id].querySelector(':scope > .cellprog'); return b ? b.innerHTML : ''; };

// A page loads while `a` has been running for 10 s with one bar up.
window.onRunState({ now: 100, cells: [
  { id: 'a', state: 'running', rev: 5, runStartedAt: 90, progress: [{ id: 'p', frac: 0.5, msg: 'half' }] },
  { id: 'b', state: 'fresh', rev: 3 },
] });
ok(live.a === 'running', 'adopted cell is not marked running');
ok(bar('a').includes('half') && bar('a').includes('50%'), 'adopted bar not drawn: ' + bar('a'));
ok(cells.a.cdur.textContent === '10', 'elapsed time not taken from the hub start: ' + cells.a.cdur.textContent);

// Later progress reaches it, which before this fix found no running cell and drew nothing.
window.onCellProgress({ cid: 'a', id: 'p', frac: 0.75, msg: 'more' });
ok(bar('a').includes('more') && bar('a').includes('75%'), 'progress after adoption not drawn: ' + bar('a'));

// Progress for a cell that isn't running draws nothing.
window.onCellProgress({ cid: 'b', id: 'p', frac: 0.2, msg: 'stray' });
ok(bar('b') === '', 'progress drawn on a cell that is not running');

// A second cell running alongside keeps its own bars.
window.onCellRun({ id: 'c', rev: 7 });
window.onCellProgress({ cid: 'c', id: 'q', frac: 0.1, msg: 'other' });
ok(bar('c').includes('other') && !bar('c').includes('more'), 'parallel cell shares bars: ' + bar('c'));
ok(bar('a').includes('more') && !bar('a').includes('other'), 'parallel progress leaked onto a: ' + bar('a'));

// A state answered before `a` started (rev below its start) must not end it.
window.onRunState({ now: 101, cells: [{ id: 'a', state: 'fresh', rev: 4 }, { id: 'c', state: 'running', rev: 7 }] });
ok(bar('a').includes('more'), 'an older state ended the run');

// A newer one does.
window.onRunState({ now: 102, cells: [{ id: 'a', state: 'fresh', rev: 6 }, { id: 'c', state: 'running', rev: 7 }] });
ok(live.a === 'fresh' && bar('a') === '', 'a newer state did not end the run');
ok(bar('c').includes('other'), 'ending one run touched another');

process.exit(bad ? 1 : 0);
