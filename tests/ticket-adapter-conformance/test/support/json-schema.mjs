// Minimal JSON Schema 2020-12 subset validator, enough for the ticket adapter schemas (no ajv is installed on this host). Written here because the interface's own support file is not part of the shipped script and no JSON Schema library is installed; it checks the schemas' keywords only.
import { readdirSync, readFileSync } from 'node:fs';
export function loadSchemas(dir) {
  const byName = {};
  for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) byName[f] = JSON.parse(readFileSync(`${dir}/${f}`, 'utf8'));
  return byName;
}
const ty = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array' : Number.isInteger(v) ? 'integer' : typeof v);
const isType = (v, t) => (t === 'number' ? typeof v === 'number' : t === 'integer' ? Number.isInteger(v) : ty(v) === t);
function resolve(schemas, base, ref) {
  const [file, frag] = ref.split('#'); const name = file ? file.split('/').pop() : base;
  let node = schemas[name]; if (!node) throw new Error(`no schema ${ref}`);
  if (frag) for (const p of frag.split('/').filter(Boolean)) node = node[p];
  return { node, name };
}
function check(schemas, name, s, v, path, out) {
  if (s.$ref) { const r = resolve(schemas, name, s.$ref); return check(schemas, r.name, r.node, v, path, out); }
  if (s.type) { const ts = [].concat(s.type); if (!ts.some((t) => isType(v, t))) { out.push(`${path}: expected ${ts.join('|')}, got ${ty(v)}`); return; } }
  if ('const' in s && JSON.stringify(s.const) !== JSON.stringify(v)) out.push(`${path}: expected ${JSON.stringify(s.const)}`);
  if (s.enum && !s.enum.some((e) => JSON.stringify(e) === JSON.stringify(v))) out.push(`${path}: not one of ${JSON.stringify(s.enum)}`);
  if (s.anyOf && !s.anyOf.some((a) => { const o = []; check(schemas, name, a, v, path, o); return !o.length; })) out.push(`${path}: matches none of anyOf`);
  if (s.oneOf) { const n = s.oneOf.filter((a) => { const o = []; check(schemas, name, a, v, path, o); return !o.length; }).length; if (n !== 1) out.push(`${path}: matches ${n} of oneOf`); }
  if (typeof v === 'string') {
    if (s.minLength != null && v.length < s.minLength) out.push(`${path}: shorter than ${s.minLength}`);
    if (s.maxLength != null && v.length > s.maxLength) out.push(`${path}: longer than ${s.maxLength}`);
    if (s.format === 'date-time' && !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)$/.test(v)) out.push(`${path}: not an RFC 3339 time`);
  }
  if (Array.isArray(v)) {
    if (s.minItems != null && v.length < s.minItems) out.push(`${path}: fewer than ${s.minItems} items`);
    if (s.uniqueItems && new Set(v.map((x) => JSON.stringify(x))).size !== v.length) out.push(`${path}: items repeat`);
    if (s.items) v.forEach((x, i) => check(schemas, name, s.items, x, `${path}[${i}]`, out));
  }
  if (ty(v) === 'object') {
    for (const k of s.required ?? []) if (!(k in v)) out.push(`${path}: missing ${k}`);
    if (s.minProperties != null && Object.keys(v).length < s.minProperties) out.push(`${path}: fewer than ${s.minProperties} properties`);
    for (const [k, sub] of Object.entries(s.properties ?? {})) if (k in v) check(schemas, name, sub, v[k], `${path}.${k}`, out);
    if (s.additionalProperties === false) for (const k of Object.keys(v)) if (!(k in (s.properties ?? {}))) out.push(`${path}: unexpected key ${k}`);
  }
}
export function validate(schemas, name, value) {
  const out = []; check(schemas, name, schemas[name], value, '$', out);
  const top = schemas[name]; for (const a of top.allOf ?? []) check(schemas, name, a, value, '$', out);
  return out;
}
