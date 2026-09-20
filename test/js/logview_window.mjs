// Asserts src/assets/js/logview.js — the addressing the log viewer is built on.
//
// The viewer never holds a file, only a window onto one, and every position in it is a BYTE offset
// because that is what `log_search` reports and what `log_slice` seeks to. An off-by-one here does
// not look like an off-by-one: it looks like the highlight landing on the neighbouring line, or a
// page that overlaps the one before it by a character. So the arithmetic is pinned directly.
//
//   node test/js/logview_window.mjs      # exit 0 = pass, 1 = mismatch, 2 = load failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { loadEscHtml } from './_esc_src.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'logview.js'), 'utf8');

globalThis.window = globalThis;
globalThis.document = { createElement: () => ({ style: {} }), body: { appendChild() {} },
                        addEventListener() {} };
// The page's shared escaper, loaded rather than re-implemented: `esc_html.mjs` exists to keep
// exactly one definition of it in the tree, and a second one here would be the thing it forbids, in
// the file that is meant to know better.
globalThis.slateEscHtml = loadEscHtml();
// The REAL ansi.js, not a stand-in: a job's output arrives coloured, and what has to hold is that
// the viewer's classifier reads through the escape codes while its renderer keeps them.
(0, eval)(readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'ansi.js'), 'utf8'));
let LV;
try { (0, eval)(src); LV = globalThis.slateLogs; } catch (e) {
  console.error('logview: could not evaluate logview.js —', e.message); process.exit(2);
}
if (!LV || !LV._test) { console.error('logview: logview.js exposed no test surface'); process.exit(2); }

const { S, cut, visible, sevOf, setSev, paintLine, recordHtml, hitLines, fileStatus,
        levelPattern } = LV._test;
const fails = [];
const ok = (cond, what) => { if (!cond) fails.push(what); };
const eq = (got, want, what) => {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) fails.push(`${what}: got ${a}, want ${b}`);
};

// The severity vocabulary is SERVED (Julia's `_LOG_BAD_SRC` and friends), so the viewer classifies
// nothing until it arrives — a second vocabulary written here is the drift this avoids. These are
// the sources Julia sends.
// An escape sequence is accepted wherever a word boundary is, because the chip counts run in
// ripgrep over the raw file where `\e[1mWarning` has no boundary before the `W`.
const SGR = '\\x1b\\[[0-9;]*m', B = '(?:' + SGR + '|\\b)';
setSev({
  declared: '^(?:' + SGR + '|\\s)*[┌\\[](?:' + SGR + '|\\s)*(Error|Warning|Info|Debug)\\b',
  error: [B + '(error|fatal|traceback|exception|segmentation fault|killed|oom|out of memory|exceeded|abort(ed)?)\\b',
          B + '[1-9][0-9]*\\s+(failed|failures?|errors?)\\b'],
  warn: [B + '(warn|warning|deprecat)'],
  // Per level, for counting a whole file: the word lists are the fallback for output
  // that declares nothing, and over a file they count every line that merely says `warn`.
  dwarn: '^(?:' + SGR + '|\\s)*[┌\\[](?:' + SGR + '|\\s)*Warning\\b',
  derror: '^(?:' + SGR + '|\\s)*[┌\\[](?:' + SGR + '|\\s)*Error\\b',
});

eq(sevOf('ERROR: LoadError'), 'error', 'an error line');
eq(sevOf('slurmstepd: error: Exceeded job memory limit'), 'error', 'a scheduler kill');
eq(sevOf('chunk c1: 1 ran, 0 skipped, 3 failed of 4'), 'error', 'a non-zero failure count');
// The runner's own success line is the most common line in a healthy log; colouring it red makes
// every good run look like the thing you are hunting for.
eq(sevOf('chunk c1: 4 ran, 0 skipped, 0 failed of 4'), 'info', 'a zero failure count');
eq(sevOf('Warning: assignment in soft scope'), 'warn', 'a warning');
eq(sevOf('Precompiling MyPkg'), 'info', 'an ordinary line');

// ── Byte offsets, not character counts ──────────────────────────────────────────────────────
// A page starts at the byte `log_slice` said it did, and each line after it is offset by the BYTES
// of what preceded — so a log that says anything non-ASCII does not shift every subsequent line.
const ascii = cut('alpha\nbeta\ngamma', 1000);
eq(ascii.map(l => l.o), [1000, 1006, 1011], 'ascii line offsets');

// 'é' is two bytes in UTF-8 and one JavaScript character. Counting characters would report the
// next line one byte early, and the search highlight would land on the wrong one.
const wide = cut('café\nnext', 0);
eq(wide.map(l => l.o), [0, 6], 'offsets past a multi-byte character');
eq(wide.map(l => l.t), ['café', 'next'], 'the text itself is unchanged');

// ── Which end is the top ────────────────────────────────────────────────────────────────────
// Pages are held ascending by `from` whichever way they are read, so paging never has to know
// which direction the reader is going. Only the paint order flips.
S.pages = [{ from: 0, to: 11, lines: cut('one\ntwo', 0) },
           { from: 12, to: 23, lines: cut('three\nfour', 12) }];
S.filter = 'all';

S.order = 'old';
eq(visible().map(l => l.t), ['one', 'two', 'three', 'four'], 'oldest first');
S.order = 'new';
eq(visible().map(l => l.t), ['four', 'three', 'two', 'one'], 'newest first');
// …and the offsets travel with the lines rather than being re-derived from their new position.
eq(visible().map(l => l.o), [18, 12, 4, 0], 'offsets survive the reversal');

// A Julia log record is several lines and reads in one direction only. Newest-first puts the
// newest RECORD at the top with its own lines still in order; reversing line by line used to put
// the `└` suffix above the `│` fields and the fields backwards.
const recs = '┌ Info: one\n│   a = 1\n│   b = 2\n└ @ Mod f:1\n┌ Info: two\n│   c = 3\n└ @ Mod f:2';
S.pages = [{ from: 0, to: 200, lines: cut(recs, 0) }];
S.filter = 'all';
S.order = 'new';
eq(visible().map(l => l.t),
   ['┌ Info: two', '│   c = 3', '└ @ Mod f:2',
    '┌ Info: one', '│   a = 1', '│   b = 2', '└ @ Mod f:1'],
   'newest record first, each record still in reading order');
S.order = 'old';
eq(visible().map(l => l.t), recs.split('\n'), 'oldest first is the file as written');
// The head flag is what the renderer spaces on, so only a record's first line carries it.
eq(cut(recs, 0).map(l => l.head), [true, false, false, false, true, false, false],
   'only a record head is a head');

// ── A record rendered as a record ───────────────────────────────────────────────────────────
// The grammar is SERVED too (Julia's `_LOG_HEAD_SRC` and friends), for the same reason the severity
// vocabulary is: one definition of what a record is. These are the sources Julia sends.
setSev({
  declared: '^(?:' + SGR + '|\\s)*[┌\\[](?:' + SGR + '|\\s)*(Error|Warning|Info|Debug)\\b',
  error: [B + '(error|fatal)\\b'], warn: [B + '(warn|warning|deprecat)'],
  dwarn: '^(?:' + SGR + '|\\s)*[┌\\[](?:' + SGR + '|\\s)*Warning\\b',
  derror: '^(?:' + SGR + '|\\s)*[┌\\[](?:' + SGR + '|\\s)*Error\\b',
  head: '^[┌\\[] (Error|Warning|Info|Debug)(?: ([0-9:.]+))?: ?(.*)$',
  field: '^│ {3}([^ =][^=]*?) = ?(.*)$',
  fcont: '^│ {4,}(.*)$',
  mcont: '^│ ([^ ].*)$',
  tail: '^└ @ (.*)$',
});

const one = cut(['┌ Info 18:19:12.865: iterating',
                 '│   residual = 0.003521',
                 '│   iteration = 284',
                 '└ @ Main.SlateShard none:10'].join('\n'), 0);
eq(one.map(l => l.r && l.r.role), ['head', 'field', 'field', 'tail'], 'the parts of a record');
eq(one.map(l => l.head), [true, false, false, false], 'only the head starts one');
eq(one[0].r.lvl + '|' + one[0].r.ts + '|' + one[0].r.msg, 'Info|18:19:12.865|iterating',
   'level, clock and message come apart');

const warnRec = cut('\u250c Warning 1:2:3.4: slow\n\u2514 @ M f:1', 0);
const exc0 = cut('\u250c Error 1:2:3.4: died\n\u2514 @ M f:1', 0);
ok(recordHtml(warnRec, '', -1).includes('>WARN<'), 'Warning is WARN, not WARNI');
const html = recordHtml(one, '', -1);
// The source location is the same for every record a sweep body writes, so it moves to the hover
// rather than taking a line each time.
// As an element, not a `title`: the browser draws that as a box over whatever you were reading.
ok(html.includes('<span class="logv-at">Main.SlateShard none:10</span>'), 'the location is shown on hover');
ok(!html.includes('title='), 'and never as a native tooltip');
// `Warning` cut to a fixed width read as `WARNI`.
ok(recordHtml(exc0, '', -1).includes('>ERROR<'), 'the level is spelled, not sliced');
ok(!html.includes('┌') && !html.includes('│') && !html.includes('└'), 'the box glyphs are gone');
ok(html.includes('<b class="logv-lvl">INFO</b>'), 'the level is its own chip');
// Every source line keeps its byte offset, because that is what a search hit is reported at and
// what the viewer seeks to. Grouping is presentation laid over those, never a replacement.
for (const l of one.slice(0, 3)) ok(html.includes(`data-o="${l.o}"`), `offset ${l.o} survives`);

// A short value flows inline with its neighbours; one that runs long, or that carries continuation
// lines under it, takes a block of its own — a stacktrace laid out in a run is unreadable.
const exc = cut(['┌ Error 1:2:3.4: it died', '│   exception =', '│    boom', '│    Stacktrace:',
                 '└ @ Main none:11'].join('\n'), 0);
eq(exc.map(l => l.r && l.r.role), ['head', 'field', 'fcont', 'fcont', 'tail'],
   'a value may run on under its key');
ok(recordHtml(exc, '', -1).includes('logv-f wide'), 'a value with continuations gets a block');
ok(!recordHtml(one, '', -1).includes('wide'), 'short fields do not');

// A second line of the MESSAGE is not a field: ConsoleLogger indents fields and does not indent
// message continuations, which is the only thing telling them apart.
const multi = cut('┌ Info: first\n│ second\n│   k = 1\n└ @ M f:1', 0);
eq(multi.map(l => l.r && l.r.role), ['head', 'mcont', 'field', 'tail'], 'message runs on, then fields');

// Output that is not a record at all still renders as the plain text of the file.
eq(cut('plain println\nslurmstepd: error: killed', 0).map(l => l.r), [null, null], 'no record, no parse');

// ── A log line cannot introduce markup ──────────────────────────────────────────────────────
// The record renderer builds HTML by concatenation, which is the arrangement that gets this wrong.
// Job output is not trusted input: it carries whatever a library, a C extension or a scheduler
// decided to print, and it is rendered in the author's own page.
{
  const nasty = '</span><img src=x onerror=alert(1)>';
  const shapes = {
    message:    ['┌ Info 1:2:3.4: ' + nasty, '└ @ M f:1'],
    fieldValue: ['┌ Info 1:2:3.4: x', '│   k = ' + nasty, '└ @ M f:1'],
    stacktrace: ['┌ Error 1:2:3.4: x', '│   exception =', '│    ' + nasty, '└ @ M f:1'],
    location:   ['┌ Info 1:2:3.4: x', '└ @ ' + nasty],
    coloured:   ['\x1b[36m┌ \x1b[39mInfo 1:2:3.4: \x1b[39m' + nasty, '└ @ M f:1'],
  };
  for (const [what, lines] of Object.entries(shapes)) {
    // Entities first, so the renderer's own spans are not mistaken for a leak.
    const flat = recordHtml(cut(lines.join('\n'), 0), '', -1)
      .replace(/&lt;|&gt;|&amp;|&quot;|&#39;/g, '~');
    ok(!/<img|<script|<svg|onerror\s*=[^a-z]/i.test(flat), `${what} escapes its content`);
  }
}

// ── A level chip reaches the whole file ─────────────────────────────────────────────────────
// A window is 64 KB of a file that may be megabytes, so filtering it can only hide what is already
// loaded: a chip reading `warn 122` sat above two visible warnings, and nothing said why. Picking a
// level now searches, using the SAME pattern the count uses — so the number and the hit list are
// one question asked once, and cannot disagree.
eq(levelPattern('warn'), '^(?:' + SGR + '|\\s)*[┌\\[](?:' + SGR + '|\\s)*Warning\\b',
   'warn searches for declared warnings');
eq(levelPattern('error'), '^(?:' + SGR + '|\\s)*[┌\\[](?:' + SGR + '|\\s)*Error\\b',
   'error likewise');
eq(levelPattern('all'), '', 'all is not a search');
eq(levelPattern('info'), '', 'neither is info — it is what is left over, not a thing to match');

// ── How a chunk ended ───────────────────────────────────────────────────────────────────────
// Worst first, because a run of hundreds of tasks is read by looking for the ones that went wrong,
// and that is also the order the column sorts in.
const st = f => fileStatus(Object.assign({ failed: 0, done: 0, total: 0, running: false }, f));
eq(st({ failed: 2, done: 4, total: 4 }).txt, '2 failed', 'a reported failure');
eq(st({ done: 4, total: 4 }).txt, 'ok', 'every unit landed');
eq(st({ done: 2, total: 4, running: true }).txt, '2/4', 'still going');
eq(st({ running: true }).txt, 'running', 'started, nothing reported yet');
eq(st({}).txt, '—', 'nothing to say');
// The state a status file cannot express on its own. A killed process leaves its counts
// part-written, which reads the same as progress until you ask whether the job is still there.
eq(st({ done: 2, total: 4 }).txt, '2/4 stopped', 'counts stopped and the job is gone');
eq(st({ done: 2, total: 4 }).cls, 'stop', '…and it is not styled as progress');
const ords = [st({ failed: 1 }), st({ done: 2, total: 4 }), st({ done: 2, total: 4, running: true }),
              st({ done: 4, total: 4 }), st({})].map(x => x.ord);
eq(ords, [4, 3, 2, 1, 0], 'worst first');

// ── The level filter ────────────────────────────────────────────────────────────────────────
S.pages = [{ from: 0, to: 99, lines: cut('starting up\nWarning: slow\nERROR: died\nbye', 0) }];
S.order = 'old';
S.filter = 'all';
eq(visible().length, 4, 'all shows everything');
S.filter = 'error';
eq(visible().map(l => l.t), ['ERROR: died'], 'error shows only errors');
S.filter = 'warn';
eq(visible().map(l => l.t), ['Warning: slow'], 'warn shows only warnings');
S.filter = 'info';
eq(visible().map(l => l.t), ['starting up', 'bye'], 'info is what is left');

// ── Severity runs in sections ───────────────────────────────────────────────────────────────
// The sentence that says a job died is one line; the reason is the indented frames under it. If
// those classify on their own words they become ordinary output, and the error filter then shows
// the headline of every problem and the detail of none.
const trace = cut([
  'Precompiling MyPkg',
  'ERROR: LoadError: UndefVarError: `trial` not defined',
  'Stacktrace:',
  ' [1] top-level scope',
  '   @ /home/u/run.jl:12',
  '',
  'done',
].join('\n'), 0);
eq(trace.map(l => l.sev),
   ['info', 'error', 'error', 'error', 'error', 'error', 'info'],
   'a traceback is one error section');

// …and a warning section closes when ordinary output resumes, rather than staining the rest.
const warns = cut('Warning: slow\n  retrying\nall fine\nmore', 0);
eq(warns.map(l => l.sev), ['warn', 'warn', 'info', 'info'], 'a section ends at the next entry');

// A continuation that names something worse than its section keeps its own level: an indented
// line reading ERROR is an error wherever it sits.
const worse = cut('Warning: slow\n  ERROR: and then it died', 0);
eq(worse.map(l => l.sev), ['warn', 'error'], 'a continuation may name a worse level');

// ── A record that names its own level ───────────────────────────────────────────────────────
// Julia's logger STATES the level, and that beats reading the sentence: the message of an @info is
// free to mention an error without being one, and the sniffing patterns cannot tell the difference.
eq(sevOf('┌ Info 14:22:31.004: 0 errors so far'), 'info', 'a declared Info that says "errors"');
eq(sevOf('┌ Error 14:22:31.004: the solver gave up'), 'error', 'a declared Error');
eq(sevOf('┌ Warning 14:22:31.004: slow'), 'warn', 'a declared Warning');
eq(sevOf('[ Info 14:22:31.004: single-line form'), 'info', 'the single-line form');
// The logger COLOURS its box characters, so the escape codes arrive before the `┌`. Stripping
// first is what lets the level be seen at all — and note the fallback cannot rescue it either,
// because in `\e[1mError` the `m` of the escape code is a word character, so `\berror\b` fails too.
eq(sevOf('\x1b[31m\x1b[1m┌ \x1b[22m\x1b[39m\x1b[31m\x1b[1mError 14:22:31.004: \x1b[22m\x1b[39mit died'),
   'error', 'a coloured logger record still names its level');
eq(sevOf('\x1b[36m\x1b[1m┌ \x1b[22m\x1b[39m\x1b[36m\x1b[1mInfo 14:22:31.004: \x1b[22m\x1b[39m0 errors so far'),
   'info', 'a coloured Info that says "errors"');

// …and the sniffing patterns still cover everything that declares nothing.
eq(sevOf('slurmstepd: error: Exceeded job memory limit'), 'error', 'undeclared output still sniffs');

// A record's continuation lines are its keyword values and its source location, which are the part
// you actually wanted when you filtered to that level.
const rec = cut([
  '┌ Warning 14:22:31.004: batch is running hot',
  '│   margin = 0.02',
  '│   batch = 3',
  '└ @ Main run.jl:12',
  '[ Info 14:22:31.010: back to nominal',
].join('\n'), 0);
eq(rec.map(l => l.sev), ['warn', 'warn', 'warn', 'warn', 'info'],
   'a logger record is one section');

// ── Output that coloured itself ─────────────────────────────────────────────────────────────
// A job prints through Julia's own colour machinery, so the level word arrives wrapped in escape
// codes. Classifying the raw string would read `\e[31mERROR` and find no word boundary before it.
const red = '\x1b[31mERROR: it died\x1b[0m';
eq(sevOf(red), 'error', 'a coloured error line is still an error');
eq(sevOf('\x1b[33mWarning: slow\x1b[0m'), 'warn', 'a coloured warning is still a warning');

// …and the colour is KEPT when it is rendered, rather than escaped into visible junk.
const painted = paintLine(red, '');
if (!/ansi-fg-1/.test(painted)) fails.push('paintLine dropped the line\'s own colour');
if (painted.indexOf('\x1b') >= 0) fails.push('paintLine left a raw escape code in the markup');

// Byte offsets count the escape codes, because the file contains them: a search hit's offset comes
// from ripgrep, which reads the bytes on disk and knows nothing about what renders.
const coloured = cut(red + '\nnext', 0);
eq(coloured.map(l => l.o), [0, red.length + 1], 'offsets span the escape codes');

// ── A hit is a record, not a line ───────────────────────────────────────────────────────────
// The search matches one line, and the match is the head of a record whose fields say what actually
// happened. So a hit arrives with the lines after it and the trim happens here: keep what continues
// the record, drop what starts the next one, and leave the offsets alone so the row still seeks.
const withCtx = [
  '\u250c Error: chunk finished with failures',
  '\u2502   chunk = "sw65da"',
  '\u2502   ran = 2',
  '\u2514 @ Slate batch.jl:12',
  '\u250c Info: next chunk',
  '\u2514 @ Slate batch.jl:20',
].join('\n');
const hl = hitLines({ offset: 40, line: 9, text: withCtx });
eq(hl.length, 4, 'a hit keeps its record and stops at the next one');
eq(hl.map(l => l.o), [40, 80, 103, 117], 'carried lines keep their own offsets');
ok(hl.every(l => l.sev === 'error'), 'the fields inherit the record\'s level');

// A match on a plain line keeps what is indented under it — a stacktrace is the answer, not noise —
// and stops at the next line that stands on its own.
const plain = hitLines({ offset: 0, line: 1,
                         text: 'ERROR: LoadError: it died\nStacktrace:\n [1] top\nnext thing' });
eq(plain.length, 3, 'a bare error keeps its stacktrace');

if (fails.length) { fails.forEach(f => console.error('logview:', f)); process.exit(1); }
console.log('logview: ok');
