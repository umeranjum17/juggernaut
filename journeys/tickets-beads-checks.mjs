import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
const repo = fs.realpathSync(process.cwd());
assert(process.env.TMPDIR, 'The registered task TMPDIR is required');
assert(process.env.DONE_DONE_EVIDENCE_ROOT, 'DONE_DONE_EVIDENCE_ROOT is required');
const tmp = fs.realpathSync(process.env.TMPDIR), evidence = path.resolve(process.env.DONE_DONE_EVIDENCE_ROOT);
for (let p = tmp;; p = path.dirname(p)) { assert(!fs.existsSync(path.join(p, '.git')), 'TMPDIR must be outside every git tree'); if (p === path.dirname(p)) break; }
fs.mkdirSync(evidence, { recursive: true });
const work = fs.mkdtempSync(path.join(tmp, 'tickets-beads-checks-')), home = path.join(work, 'main'), store = path.join(work, 'main-store', '.beads');
const put = (p, text) => fs.writeFileSync(p, text), read = p => fs.readFileSync(p, 'utf8');
const save = (name, value) => put(path.join(evidence, name), JSON.stringify(value, null, 2) + '\n');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const executable = name => {
  for (const dir of (process.env.PATH || '').split(path.delimiter)) { const p = path.resolve(dir, name); try { fs.accessSync(p, fs.constants.X_OK); if (fs.statSync(p).isFile()) return fs.realpathSync(p); } catch {} }
  throw new Error(`Required installed executable is missing: ${name}`);
};
const env = { PATH: process.env.PATH || '', TMPDIR: tmp, LANG: 'C.UTF-8', LC_ALL: 'C.UTF-8', TZ: 'UTC', PYTHONDONTWRITEBYTECODE: '1' };
for (const [k, v] of Object.entries(process.env)) if (/^(DONE_DONE_|MATRIX_|RUN_ID$|JG_TASK_ID$)/.test(k)) env[k] = v;
Object.assign(env, { HOME: path.join(work, 'user'), JG_HOME: home, SIGN_OFF_HOME: path.join(work, 'signoff'), XDG_CONFIG_HOME: path.join(work, 'config'), XDG_DATA_HOME: path.join(work, 'data'), XDG_STATE_HOME: path.join(work, 'state'), XDG_CACHE_HOME: path.join(work, 'cache'), XDG_RUNTIME_DIR: path.join(work, 'runtime'), JG_TICKETS_SYNC: '/nonexistent' });
const steps = []; let version = 'unresolved', result = 'Journey did not finish'; let serial = 0;
function run(label, command, args = [], extra = {}) {
  const start = performance.now();
  const r = spawnSync(command, args, { cwd: home, env: { ...env, ...extra }, encoding: 'utf8', timeout: 180000, maxBuffer: 128 * 1024 * 1024 });
  const milliseconds = performance.now() - start, stem = `${String(++serial).padStart(2, '0')}-${label}`;
  put(path.join(evidence, `${stem}.stdout.log`), r.stdout || ''); put(path.join(evidence, `${stem}.stderr.log`), r.stderr || '');
  save(`${stem}.json`, { command: path.basename(command), status: r.status, signal: r.signal, milliseconds, error: r.error?.message || '' });
  assert.ifError(r.error); assert.equal(r.status, 0, `${label}: ${r.stderr || r.stdout}`);
  return { stdout: r.stdout, stderr: r.stderr, milliseconds };
}
try {
  for (const p of [home, ...['data', 'config', 'state'].map(p => path.join(home, p)), path.dirname(store), ...['HOME', 'SIGN_OFF_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR'].map(k => env[k])]) fs.mkdirSync(p, { recursive: true, mode: 0o700 });
  fs.symlinkSync(path.join(repo, 'bin'), path.join(home, 'bin')); fs.symlinkSync(path.join(repo, 'toolchain.versions'), path.join(home, 'toolchain.versions'));
  const tools = path.join(work, 'tools'); fs.mkdirSync(tools);
  for (const [name, key, candidate] of [['bd', 'JG_BEADS_BD', process.env.JG_BEADS_TEST_BD || process.env.JG_BEADS_BD], ['dolt', 'JG_BEADS_DOLT', process.env.JG_BEADS_TEST_DOLT || process.env.JG_BEADS_DOLT]]) {
    const installed = candidate ? fs.realpathSync(path.resolve(candidate)) : executable(name); fs.accessSync(installed, fs.constants.X_OK); env[key] = installed; fs.symlinkSync(installed, path.join(tools, name));
  }
  env.PATH = [tools, path.join(home, 'bin'), env.PATH].join(path.delimiter);
  version = `juggernaut@${run('version', 'git', ['-C', repo, 'rev-parse', 'HEAD']).stdout.trim()}`;
  put(path.join(work, 'board.json'), '{"schema":2,"items":[]}\n'); put(path.join(home, 'config/fleet-board'), path.join(work, 'board.json') + '\n');
  put(path.join(home, 'config/beads-dir'), store + '\n'); put(path.join(home, 'config/backlog-intake-loose'), ''); put(path.join(home, 'data/squad_leads.md'), '');
  put(path.join(home, 'data/projects.md'), '- demo [local-trunk] - Umer isolated demo (added 2026-11-01)\n');
  const beads = path.join(home, 'bin/jg-beads.sh'), sql = (label, query) => run(label, beads, ['dolt', 'sql', '-q', query], { BEADS_DIR: store });
  run('initialize', beads, ['init', '--prefix', 'jg'], { BEADS_DIR: store });
  const digit = '(SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9)';
  const nums = `(SELECT a.n + 10*b.n + 100*c.n + 1000*d.n + 10000*e.n + 1 AS i FROM ${digit} a, ${digit} b, ${digit} c, ${digit} d, ${digit} e) x`;
  sql('seed', `INSERT INTO issues (id,title,description,design,acceptance_criteria,notes,status) SELECT CONCAT('jg-bulk-',i),CONCAT('Umer ticket ',i),'','','','','open' FROM ${nums} WHERE i <= 2553; INSERT INTO labels (issue_id,label) SELECT id,'project:demo' FROM issues WHERE id LIKE 'jg-bulk-%';`);
  steps.push('Initialize an isolated guarded Beads store and bulk-insert 2553 uniquely numbered Umer tickets.');
  run('install', 'bash', [path.join(repo, 'core/tickets-sync/wiring.sh')]);
  const checks = ['tickets-sync', 'tickets-stale', 'tickets-cleanup'], checkPath = name => path.join(home, 'state', `${name}.check.sh`);
  const probe = path.join(work, 'probe'); fs.mkdirSync(probe);
  put(path.join(probe, 'python3'), '#!/usr/bin/env bash\nprintf "%s\\n" "$SIGN_OFF_TICKETS_ADAPTER" "$BEADS_DIR" "$@"\n'); fs.chmodSync(path.join(probe, 'python3'), 0o700);
  const trust = {};
  for (const name of checks) {
    const script = checkPath(name), trusted = script.replace(/\.check\.sh$/, '.check-trust');
    const verify = () => { const lines = read(trusted).trimEnd().split('\n'); assert.equal(lines[0], 'jg-custom-check-v1'); assert.equal(lines[1], hash(fs.readFileSync(script))); assert.equal(fs.statSync(script).mode & 0o777, 0o700); assert.equal(fs.statSync(trusted).mode & 0o777, 0o600); return lines[1]; };
    const before = verify(); run(`register-${name}`, 'bash', [path.join(home, 'bin/jg-check-register.sh'), name]); assert.equal(verify(), before);
    const output = run(`environment-${name}`, script, [], { PATH: probe + path.delimiter + env.PATH }).stdout.trimEnd().split('\n');
    assert.deepEqual(output, [path.join(home, 'bin/jg-ticket-adapter.py'), store, path.join(env.XDG_DATA_HOME, 'jg-tickets-sync/tickets-sync/sync.py'), ...(name === 'tickets-stale' ? ['--check'] : name === 'tickets-cleanup' ? ['--cleanup'] : [])]);
    trust[name] = { sha256: before, checkMode: '0700', trustMode: '0600', suppliedAdapterAndStore: true };
  }
  save('registration.json', trust); steps.push('Install, inspect executable trust hashes, re-register all three checks, and verify their default adapter and store environment.');
  const boardRead = (label, since = '--all') => JSON.parse(run(label, 'python3', [path.join(home, 'bin/jg-beads-read.py'), 'board', since], { BEADS_DIR: store }).stdout);
  const projectionCode = 'import importlib.util,json,os\np=os.environ["JG_HOME"]+"/bin/jg-ticket-adapter.py"\ns=importlib.util.spec_from_file_location("adapter",p); a=importlib.util.module_from_spec(s); s.loader.exec_module(a)\nout=[]\nfor name,home,row in a.fleet_snapshot():\n if a.column(row,home):\n  a.BOARD_HOME=(name,home); out.append(a.to_ticket(row))\nprint(json.dumps(sorted(out,key=lambda t:json.dumps(t,sort_keys=True)),sort_keys=True))\n';
  const projection = label => JSON.parse(run(label, 'python3', ['-c', projectionCode], { BEADS_DIR: store }).stdout);
  const source = label => sql(label, 'SELECT * FROM issues ORDER BY id; SELECT * FROM labels ORDER BY issue_id,label; SELECT * FROM dependencies ORDER BY id;').stdout;
  const beforeRows = boardRead('source-before'), beforeProjection = projection('projection-before'), beforeSource = source('tables-before');
  assert.equal(beforeRows.length, 2553); assert.equal(new Set(beforeRows.map(r => r.id)).size, 2553); assert.equal(new Set(beforeRows.map(r => r.title)).size, 2553);
  assert(beforeRows.every(r => r.status === 'open' && /^Umer ticket \d+$/.test(r.title))); assert.equal(beforeProjection.length, 2553); assert.equal(new Set(beforeProjection.map(r => r.id)).size, 2553);
  save('source-before.json', beforeRows); save('board-before.json', beforeProjection);
  const state = path.join(home, 'state/tickets-sync'), progress = path.join(state, 'progress.log');
  assert(!fs.existsSync(path.join(home, '.jg-squad-lead-home'))); assert(!fs.existsSync(path.join(state, 'beads-snapshot.sha256')));
  const timed = run('timed-sync', checkPath('tickets-sync')); assert.equal(timed.stdout, ''); assert.equal(timed.stderr, '');
  const observed = read(progress), match = /^tickets-sync: 1 homes read; (\d+) Beads tickets observed\n$/.exec(observed); assert(match, observed); assert.equal(Number(match[1]), 2553);
  save('timing.json', { count: Number(match[1]), milliseconds: timed.milliseconds, limitMilliseconds: 20000, setupExcluded: true, fixture: 'isolated actual Beads store; not live fleet', leadMarker: false, backend: 'installed pinned bd and dolt through guarded jg-beads.sh', baseURLConfigured: Boolean(process.env.DONE_DONE_BASE_URL) });
  assert(timed.milliseconds < 20000, `Installed sync took ${timed.milliseconds}ms`);
  const digest = read(path.join(state, 'beads-snapshot.sha256'));
  for (const name of ['tickets-sync', 'tickets-stale', 'tickets-sync', 'tickets-stale']) { const r = run(`repeat-${name}`, checkPath(name)); assert.equal(r.stdout, ''); assert.equal(r.stderr, ''); }
  assert.equal(read(progress), observed); assert.equal(read(path.join(state, 'beads-snapshot.sha256')), digest);
  const afterRows = boardRead('source-after'), afterProjection = projection('projection-after'); save('source-after.json', afterRows); save('board-after.json', afterProjection);
  assert.deepEqual(afterRows, beforeRows); assert.deepEqual(afterProjection, beforeProjection); assert.equal(source('tables-after'), beforeSource);
  steps.push(`Run the installed sync in ${timed.milliseconds.toFixed(3)}ms, observe ${match[1]} tickets, and repeat sync/stale silently without changing source fields or board projection.`);
  sql('history-and-protections', "INSERT INTO issues (id,title,description,design,acceptance_criteria,notes,status,closed_at) VALUES ('jg-history','Umer history 2554','','','','','closed',DATE_SUB(NOW(), INTERVAL 10 DAY)); INSERT INTO labels (issue_id,label) VALUES ('jg-history','project:demo'); UPDATE issues SET description='status: superseded' WHERE id IN ('jg-bulk-1','jg-bulk-2'); INSERT INTO issues (id,title,description,design,acceptance_criteria,notes,issue_type) VALUES ('jg-owner-gate','Umer owner question 2555','Captain decides','','','','gate'); INSERT INTO dependencies (id,issue_id,type,created_by,depends_on_issue_id) VALUES (UUID(),'jg-bulk-1','blocks','journey','jg-owner-gate');");
  run('start-work', path.join(home, 'bin/jg-backlog.sh'), ['start', 'jg-bulk-2'], { BEADS_DIR: store });
  const board = path.join(work, 'board.json'), ticket = 'jg-' + hash('main/jg-history').slice(0, 32);
  run('raise-history-question', 'sign-off-axi', ['raise', board, '--key', 'q-history', '--ask-ref', 'q-history', '--title', 'Umer historical work completed?', '--why', 'The isolated source records completion.', '--outcome', 'yes=Record completion.', '--outcome', 'no=Keep reviewing.', '--recommend', 'no', '--recommend-reason', 'Review the source.', '--default', 'no', '--ticket', ticket]);
  save('cards-before.json', JSON.parse(run('cards-before', 'sign-off-axi', ['list', board, '--json']).stdout));
  const cutoff = new Date(Date.now() - 7 * 86400000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ordinary = boardRead('ordinary-history-filter', cutoff), historical = boardRead('all-history', '--all'); save('ordinary-history-filter.json', ordinary); save('all-history.json', historical);
  assert.equal(ordinary.length, 2553); assert(!ordinary.some(r => r.id === 'jg-history')); assert.equal(historical.length, 2554); assert(historical.some(r => r.id === 'jg-history' && r.status === 'closed' && Date.parse(r.closed_at) < Date.parse(cutoff)));
  const cleanupSource = source('tables-before-cleanup'), cleaned = run('cleanup', checkPath('tickets-cleanup')); assert.match(cleaned.stdout, /^tickets-cleanup: flagged /); assert.match(cleaned.stdout, /cards: 1 archived,/);
  const cards = JSON.parse(run('cards-after', 'sign-off-axi', ['list', board, '--json']).stdout); save('cards-after.json', cards); assert(cards.decisions.find(c => c.key === 'q-history')?.dismissed);
  const report = read(path.join(state, `cleanup-${read(path.join(state, 'cleanup.day')).trim()}.txt`));
  assert.match(report, /superseded: main\/jg-bulk-1 - .*kept: it holds an owner decision/); assert.match(report, /superseded: main\/jg-bulk-2 - .*kept: work is in flight/);
  assert.equal(source('tables-after-cleanup'), cleanupSource); const again = run('cleanup-again', checkPath('tickets-cleanup')); assert.equal(again.stdout, ''); assert.equal(again.stderr, '');
  steps.push('Read ten-day closed history with board --all, archive its linked local question through cleanup, and preserve both owner-gated and active superseded work.');
  function noLegacy(dir) { for (const entry of fs.readdirSync(dir, { withFileTypes: true })) { assert.notEqual(entry.name, 'tickets.jsonl', 'Legacy ticket store was created'); if (entry.isDirectory()) noLegacy(path.join(dir, entry.name)); } }
  noLegacy(work); result = `${match[1]} tickets observed in ${timed.milliseconds.toFixed(3)}ms; repeated polls are silent and unchanged; cleanup can resolve old closed sources while protecting owner decisions and active work.`;
} catch (error) { result = `Failed: ${error.message}`; save('failure.json', { message: error.message, stack: error.stack }); process.exitCode = 1; }
finally {
  save('steps.json', { target: { version }, start: 'Fresh isolated HOME/XDG/SIGN_OFF_HOME and guarded Beads fixture under the registered task TMPDIR, outside any git tree', steps, result });
  try { if (fs.existsSync(path.join(home, 'state'))) fs.cpSync(path.join(home, 'state'), path.join(evidence, 'resulting-state'), { recursive: true }); if (fs.existsSync(path.join(work, 'board.json'))) fs.copyFileSync(path.join(work, 'board.json'), path.join(evidence, 'resulting-board.json')); }
  finally { fs.rmSync(work, { recursive: true, force: true }); }
}
