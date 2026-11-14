// The board over the Beads ticket adapter, driven in a headless Chromium of its own at exact device metrics (390 px with mobile emulation, 1280 px).
// Usage: node journey.mjs <sign-off dir (built)> <adapter> <expected.json> <evidence folder> <light|dark> <390|1280>
// <expected.json> is what `bd` itself lists: [{id, title, status, assignee, parent}] for the open tickets, and {closed: [ids]}.
// It starts the board with SIGN_OFF_TICKETS_ADAPTER set, reads the list through the board's own API and its own page, and compares both with bd's rows.
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import assert from 'node:assert/strict';
const [repoArg, adapter, expectedFile, outArg, theme, widthArg] = process.argv.slice(2);
const repo = resolve(repoArg), out = resolve(outArg), width = +widthArg, phone = width < 1024, wait = (ms) => new Promise((ok) => setTimeout(ok, ms));
const expected = JSON.parse(readFileSync(expectedFile, 'utf8'));
mkdirSync(out, { recursive: true });
const dir = mkdtempSync(join(tmpdir(), 'jg-board-beads-')), board = join(dir, 'board.json'), prof = join(dir, 'chrome');
// The board gets a throwaway home and the adapter; the Beads variables stay, so the adapter reaches the throwaway store.
const env = { ...process.env, PATH: `${dirname(process.execPath)}:${process.env.PATH}`, HOME: dir, XDG_CONFIG_HOME: dir, XDG_DATA_HOME: dir, XDG_STATE_HOME: dir, XDG_CACHE_HOME: dir, SIGN_OFF_HOME: dir, SIGN_OFF_TICKETS_ADAPTER: resolve(adapter) };
const chromium = ['/usr/lib/chromium/chromium', '/usr/bin/chromium', '/usr/bin/google-chrome'].find(existsSync);
assert.ok(chromium, 'a Chromium is installed');
const chrome = spawn(chromium, ['--headless=new', '--no-sandbox', `--user-data-dir=${prof}`, '--remote-debugging-port=0', 'about:blank'], { stdio: 'ignore' });
// A board needs one card to exist; the card names the first open ticket, as a worker's card does.
execFileSync(process.execPath, [join(repo, 'dist/cli.js'), 'raise', board, '--title', 'Ship the page on Friday?', '--why', 'The page is ready.', '--outcome', 'yes=It ships.', '--outcome', 'no=It waits.', '--recommend', 'yes', '--recommend-reason', 'Every check passed.', '--default', 'no', '--ask-ref', 'journey', '--ticket', expected.open[0].id], { env });
const log = openSync(join(dir, 'serve.out'), 'w');
const server = spawn(process.execPath, [join(repo, 'dist/cli.js'), 'serve', board, '--bind', '127.0.0.1', '--port', '0'], { env, stdio: ['ignore', log, log] });
let ws; const errors = [];
try {
  let base;
  for (let i = 0; i < 80 && !base; i++) { await wait(250); base = /url: "(http:\/\/[^"]+)"/.exec(readFileSync(join(dir, 'serve.out'), 'utf8'))?.[1]; }
  assert.ok(base, 'the board is served');
  // 1. The board's own API lists the same open tickets as bd, with bd's own words, no board-only key, and no closed ticket.
  const api = await (await fetch(new URL("api/tickets", base))).json();
  const rows = api.tickets ?? api;
  assert.ok(Array.isArray(rows), `the API answers a list: ${JSON.stringify(api).slice(0, 200)}`);
  const want = expected.open, byId = (a) => [...a].sort((x, y) => x.id.localeCompare(y.id));
  assert.deepEqual(byId(rows).map((t) => t.id), byId(want).map((t) => t.id), 'the board lists exactly the open tickets bd lists');
  for (const w of want) {
    const t = rows.find((r) => r.id === w.id);
    assert.deepEqual({ id: t.id, title: t.title, status: t.status, assignee: t.assignee ?? null, parent: t.parent ?? null }, { id: w.id, title: w.title, status: w.status, assignee: w.assignee ?? null, parent: w.parent ?? null }, `${w.id}: id, title, status, assignee and parent as bd shows them`);
    for (const k of Object.keys(t)) assert.ok(['id', 'rev', 'title', 'body', 'kind', 'status', 'assignee', 'labels', 'parent', 'links', 'created_at', 'updated_at', 'extra', 'cards'].includes(k), `${w.id}: no board-only key (${k})`);
    assert.ok(!('stage' in t) && !('stage' in (t.extra ?? {})), `${w.id}: no invented stage`);
  }
  for (const c of expected.closed) assert.ok(!rows.some((r) => r.id === c), `closed ${c} is left out of the list`);
  writeFileSync(join(out, `api-tickets.${theme}.${width}.json`), JSON.stringify(rows, null, 2) + '\n');
  // 2. The board's own page, at an exact device size.
  let port; for (let i = 0; i < 100 && !port; i++) { await wait(100); const f = join(prof, 'DevToolsActivePort'); if (existsSync(f)) port = readFileSync(f, 'utf8').split('\n')[0]; }
  assert.ok(port, 'Chromium opened its DevTools port');
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((ok, no) => { ws.onopen = ok; ws.onerror = no; });
  let id = 0; const pending = new Map();
  ws.onmessage = (m) => { const x = JSON.parse(m.data); if (x.id && pending.has(x.id)) { pending.get(x.id)(x); pending.delete(x.id); }
    if (x.method === 'Runtime.exceptionThrown') errors.push(x.params.exceptionDetails.exception?.description?.split('\n')[0] ?? 'exception'); };
  const cdp = (method, params = {}) => new Promise((ok, no) => { const n = ++id; pending.set(n, (x) => (x.error ? no(new Error(`${method}: ${x.error.message}`)) : ok(x.result))); ws.send(JSON.stringify({ id: n, method, params })); });
  const js = async (expression) => { const r = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }); assert.ok(!r.exceptionDetails, `${expression.slice(0, 80)}: ${r.exceptionDetails?.exception?.description}`); return r.result.value; };
  const until = async (expression, what) => { for (let i = 0; i < 300; i++) { if (await js(expression)) return; await wait(100); } assert.fail(`timed out: ${what}${errors.length ? `; page errors: ${errors.join(' | ')}` : ''}`); };
  await cdp('Page.enable'); await cdp('Runtime.enable');
  await cdp('Emulation.setDeviceMetricsOverride', phone ? { width, height: 844, deviceScaleFactor: 2, mobile: true } : { width, height: 800, deviceScaleFactor: 2, mobile: false });
  await cdp('Emulation.setTouchEmulationEnabled', phone ? { enabled: true, maxTouchPoints: 5 } : { enabled: false });
  await cdp('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  const png = async (name) => { await wait(400); writeFileSync(join(out, `${name}.${theme}.${width}.png`), Buffer.from((await cdp('Page.captureScreenshot', { format: 'png' })).data, 'base64')); };
  await cdp('Page.navigate', { url: `${base}#tickets` });
  await until(`document.querySelectorAll('.tk-row').length === ${want.length}`, 'one row per open ticket');
  const page = await js(`({ width: innerWidth, overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth, rows: [...document.querySelectorAll('.tk-row')].map((r) => r.innerText.replace(/\\s+/g, ' ').trim()), groups: [...new Set([...document.querySelectorAll('.tk-row')].map((r) => r.closest('section')?.querySelector('h2')?.textContent))], text: document.body?.innerText })`);
  assert.equal(page.width, width), assert.equal(page.overflow, false, 'no sideways overflow');
  for (const w of want) assert.ok(page.rows.some((r) => r.includes(w.title)), `the page lists ${w.title}`);
  for (const c of expected.closedTitles) assert.ok(!page.text.includes(c), `the page does not list the closed ticket ${c}`);
  const statuses = new Set(want.map((w) => w.status));
  for (const g of page.groups) assert.ok([...statuses].some((s) => g.startsWith(s)), `group ${g} is a status bd gave`);
  writeFileSync(join(out, `list-facts.${theme}.${width}.json`), JSON.stringify(page, null, 2) + '\n');
  await png('list');
  // Each open ticket's own page shows its id, status, assignee and parent as bd gives them; the first one that has a parent is captured.
  let shot = false;
  for (const w of want) {
    await cdp('Page.navigate', { url: 'about:blank' }); await wait(150);
    await cdp('Page.navigate', { url: `${base}#ticket/${w.id}` });
    await until(`document.body?.innerText.includes('History') && !document.body?.innerText.includes('Loading history') && document.body?.innerText.includes(${JSON.stringify(w.id)})`, `the page of ${w.id}`);
    const t = await js(`({ overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth, text: document.body?.innerText })`);
    const sheet = t.text.slice(t.text.indexOf(`\n${w.id}\n`)); // the sheet's own fields follow its id line
    const field = (name) => new RegExp(`\\n${name}\\n([^\\n]*)\\n`).exec(sheet)?.[1];
    assert.equal(t.overflow, false, `no sideways overflow on ${w.id}`);
    assert.equal(field('Status'), w.status, `${w.id}: status as bd shows it`);
    assert.equal(field('Assignee'), w.assignee ?? 'Unassigned', `${w.id}: assignee as bd shows it`);
    const parent = want.find((x) => x.id === w.parent);
    assert.equal(field('Part of'), parent ? parent.title : undefined, `${w.id}: parent as bd shows it`);
    if (parent && !shot) { await png('ticket'); shot = true; }
  }
  assert.deepEqual(errors, [], 'no page error');
  console.log(`ok ${theme} ${width}: ${want.length} open tickets match bd, closed ${expected.closed.length} left out`);
} finally {
  try { ws?.close(); } catch {}
  try { chrome.kill(); } catch {}
  try { server.kill(); } catch {}
  await wait(300);
  rmSync(dir, { recursive: true, force: true });
}
