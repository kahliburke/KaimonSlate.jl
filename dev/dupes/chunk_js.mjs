// One chunk per JS function, for dev/dupes/dupes.jl: a JSON line per function with its file,
// lines, name, its code without comments, and its tokens with names and literals replaced, which
// is what the copy-paste score compares. Reads the file paths from argv.
import { readFileSync } from 'node:fs';
import { parse } from '@babel/parser';

const FN = new Set(['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression',
                    'ObjectMethod', 'ClassMethod', 'ClassPrivateMethod']);

function nameOf(node, parent) {
  if (node.id && node.id.name) return node.id.name;
  if (node.key) return node.key.name || node.key.value || '<method>';
  if (parent && parent.type === 'VariableDeclarator' && parent.id && parent.id.name) return parent.id.name;
  if (parent && parent.type === 'AssignmentExpression') {
    const l = parent.left;
    if (l && l.type === 'MemberExpression' && l.property) return l.property.name || '<assign>';
    if (l && l.name) return l.name;
  }
  if (parent && parent.type === 'ObjectProperty' && parent.key) return parent.key.name || parent.key.value || '<prop>';
  return '<anon>';
}

// The source between `start` and `end` with every comment inside it removed.
function stripComments(src, start, end, comments) {
  let out = '', at = start;
  for (const c of comments) {
    if (c.end <= start || c.start >= end) continue;
    out += src.slice(at, Math.max(at, c.start));
    at = Math.min(end, c.end);
  }
  return out + src.slice(at, end);
}

function normTokens(tokens, start, end) {
  const out = [];
  for (const t of tokens) {
    if (t.start < start || t.end > end || t.type === 'CommentLine' || t.type === 'CommentBlock') continue;
    const label = t.type && t.type.label;
    if (label === 'name' || label === 'privateName' || label === 'jsxName') out.push('ID');
    else if (label === 'num' || label === 'bigint' || label === 'decimal') out.push('NUM');
    else if (label === 'string' || label === 'template') out.push('STR');
    else out.push(label || String(t.value));
  }
  return out.join(' ');
}

for (const file of process.argv.slice(2)) {
  const src = readFileSync(file, 'utf8');
  let ast;
  try {
    ast = parse(src, { sourceType: 'unambiguous', tokens: true, errorRecovery: true, allowReturnOutsideFunction: true });
  } catch (e) {
    process.stderr.write(`chunk_js: cannot parse ${file}: ${e.message}\n`);
    continue;
  }
  const comments = ast.comments || [], tokens = ast.tokens || [];
  const walk = (node, parent) => {
    if (!node || typeof node.type !== 'string') return;
    if (FN.has(node.type)) {
      const code = stripComments(src, node.start, node.end, comments);
      process.stdout.write(JSON.stringify({
        file, start: node.loc.start.line, end: node.loc.end.line, name: nameOf(node, parent),
        lang: 'js', code, norm: normTokens(tokens, node.start, node.end),
      }) + '\n');
    }
    for (const k of Object.keys(node)) {
      if (k === 'loc' || k === 'leadingComments' || k === 'trailingComments' || k === 'innerComments') continue;
      const v = node[k];
      if (Array.isArray(v)) v.forEach(x => walk(x, node));
      else if (v && typeof v.type === 'string') walk(v, node);
    }
  };
  walk(ast.program, null);
}
