// Asserts that every `openSettings(scope, section)` call names a section that EXISTS.
//
// A panel can carry its own settings button and open the dialog straight onto its group — the Agent
// panel's ⚙ does, because the model and permissions it runs under are read from there. The link is a
// plain string matched against the group HEADINGS, which is what lets the section list be derived
// from the markup with no list to maintain (settings.js `slateSectionNav`). The cost of that is this:
// rename a heading and the button silently opens on the wrong section, because an unknown name falls
// back to the first rather than failing. Nothing else would notice.
//
//   node test/js/settings_section_links.mjs   # exit 0 = pass, 1 = a link names no section, 2 = harness
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const html = readFileSync(join(root, 'src', 'assets', 'notebook.html'), 'utf8');

// The global panel's groups. Read from `#setbody` only: the publishing modal reuses `.setsec` for
// its own headings and those are not settings sections.
const body = /<div class="setbody" id="setbody">([\s\S]*?)<div class="setempty"/.exec(html)
  || /id="setbody"[^>]*>([\s\S]*)<div class="setempty"/.exec(html);
if (!body) { console.error('settings_section_links: could not find #setbody'); process.exit(2); }
// A heading's name is its text with tags stripped, matching `node.textContent.trim()` in settings.js.
const sections = [...body[1].matchAll(/<div class="setsec">([\s\S]*?)<\/div>/g)]
  .map(m => m[1].replace(/<[^>]*>/g, '').trim());
if (!sections.length) { console.error('settings_section_links: found no .setsec headings'); process.exit(2); }

// Every call that asks for a section. Two arguments — one argument is a scope, which is not this.
const calls = [...html.matchAll(/openSettings\(\s*'([^']*)'\s*,\s*'([^']*)'\s*\)/g)]
  .map(m => ({ scope: m[1], section: m[2] }));

const fails = [];
for (const c of calls) {
  if (!sections.includes(c.section)) {
    fails.push(`openSettings('${c.scope}', '${c.section}') — no such section. Have: ${sections.join(' | ')}`);
  }
  // A section link is for the GLOBAL panel's static headings; the notebook scope builds its groups
  // from /api/config at runtime, so a name checked against this file would prove nothing.
  if (c.scope === 'notebook') {
    fails.push(`openSettings('notebook', '${c.section}') — notebook groups are built at runtime, not from this file`);
  }
}
// The Agent panel is the reason this exists; if its button loses its section the check goes quiet.
if (!calls.some(c => c.section === 'Agent')) {
  fails.push("expected the Agent panel's settings button to open the 'Agent' section");
}

if (fails.length) {
  console.error('settings_section_links FAIL:\n  ' + fails.join('\n  '));
  process.exit(1);
}
console.log(`settings_section_links: ok (${calls.length} link(s), ${sections.length} sections)`);
