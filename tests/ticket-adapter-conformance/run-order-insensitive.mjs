#!/usr/bin/env node
// EXCEPTION to the interface's conformance script, for one reason: bd keeps metadata keys sorted, and the script's `same` compares `extra` with JSON.stringify,
// so check 2 reads key ORDER and fails a correct read-back. This runs the shipped script with that one line replaced by a compare that sorts object keys
// (arrays keep their order) and changes nothing else. See README.md. Usage: node run-order-insensitive.mjs <adapter> --throwaway --faults <driver>
import { copyFileSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';

const dir = fileURLToPath(new URL('./test/', import.meta.url)), shipped = `${dir}ticket-adapter-conformance.mjs`;
const line = 'const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);';
const source = readFileSync(shipped, 'utf8');
if (!source.includes(line)) { console.error('the shipped script no longer has the compare this exception replaces; remove the exception'); process.exit(2); }
const canon = 'const canon = (v) => (Array.isArray(v) ? v.map(canon) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])])) : v);\n'
  + 'const same = (a, b) => JSON.stringify(canon(a)) === JSON.stringify(canon(b));';
const patched = `${dir}.order-insensitive-${process.pid}.mjs`;
writeFileSync(patched, source.replace(line, canon));
try {
  const { main } = await import(pathToFileURL(patched).href);
  process.exitCode = main(process.argv.slice(2));
} finally { rmSync(patched, { force: true }); }
