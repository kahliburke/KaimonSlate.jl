// Exercise the real settings helpers with a DOM and a served ACP catalogue. Default model ids
// have no trailing colon, render with a useful label, and also work in the specialist selector.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { makeDocument } from './minidom.mjs';

const source = readFileSync(new URL('../../src/assets/js/settings.js', import.meta.url), 'utf8');
function sliceFn(name) {
  let start = source.indexOf('function ' + name + '(');
  assert.ok(start >= 0, 'missing settings function ' + name);
  if (source.slice(start - 6, start) === 'async ') start -= 6;
  let depth = 0;
  for (let i = source.indexOf('{', start); i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error('unbalanced settings function ' + name);
}

const document = makeDocument('<select><option value="">Sonnet (default)</option>' +
                              '<option value="__custom__">Custom…</option>' +
                              '<option value="acp:old:model">Old model</option></select>');
const models = ['acp:codex', 'acp:other:provider/model:variant'];
let requests = 0;
const api = async (method, path) => {
  assert.equal(method, 'GET');
  assert.equal(path, '/api/acp-models');
  requests++;
  return { models };
};
const helpers = new Function('document', 'api', `
  let _roleModelCache = null;
  ${sliceFn('_acpModelLabel')}
  ${sliceFn('_setAcpModelOptions')}
  ${sliceFn('_roleModelOptions')}
  return { setOptions: _setAcpModelOptions, roleOptions: _roleModelOptions };
`)(document, api);

const select = document.querySelector('select');
helpers.setOptions(select, models);
const options = () => select.options.map(option => [option.value, option.textContent]);
assert.deepEqual(options(), [
  ['', 'Sonnet (default)'],
  ['acp:codex', 'Codex'],
  ['acp:other:provider/model:variant', 'other · provider/model:variant'],
  ['__custom__', 'Custom…'],
]);
select.value = 'acp:codex';
assert.equal(select.value, 'acp:codex', 'the selected value reaches the backend unchanged');
helpers.setOptions(select, models);
assert.equal(select.options.filter(option => option.value === 'acp:codex').length, 1,
             'reopening Settings does not duplicate Codex');

const roles = await helpers.roleOptions();
assert.deepEqual(roles.find(option => option.v === 'acp:codex'),
                 { v: 'acp:codex', label: 'Codex' });
assert.equal((await helpers.roleOptions()).length, roles.length);
assert.equal(requests, 1, 'specialist model options share the served catalogue and cache');
helpers.setOptions(select, []);
assert.deepEqual(options(), [['', 'Sonnet (default)'], ['__custom__', 'Custom…']]);

console.log('agent_models: ok');
