import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
const root = process.cwd(), evidence = process.env.DONE_DONE_EVIDENCE_ROOT || fs.mkdtempSync(path.join(os.tmpdir(), 'jg-cl-evidence-'));
fs.mkdirSync(evidence, { recursive: true });
const steps = [], outputs = [], daemons = [], cleanupErrors = [];
const timing = { daemons: {}, startup: {}, cleanup: {} };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const base = {};
for (const [k, v] of Object.entries(process.env)) if (!/^(JG_|FM_|HERDR_|TMUX)/.test(k)) base[k] = v;
const command = (file, args, runEnv = base) => {
  const r = spawnSync(file, args, { cwd: root, env: runEnv, encoding: 'utf8', timeout: 30000 });
  outputs.push(JSON.stringify({ command: [file, ...args], stdout: r.stdout, stderr: r.stderr, status: r.status, signal: r.signal, error: r.error?.message }));
  assert.ifError(r.error); assert.equal(r.status, 0, `${file} failed: ${r.stderr}`); return r.stdout;
};
const version = command('git', ['rev-parse', '--short', 'HEAD']).trim();
const sess = 'codex-lead-lab', doorbellRe = /read '([^']+\.msg)'/;
let made = '', labHome = '', tmuxDir = '', cpMade = '', cpHome = '', env = {}, failure = null, recordBody = null;
let checkpoint = { attempted: false, status: null, signal: null, stdout: '', stderr: '' };
const read = (f) => fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '';
const received = () => labHome ? read(path.join(labHome, 'receiver.log')) : '';
const daemonLog = () => read(path.join(labHome, 'state', '.supervise-daemon.log'));
const isolate = (home) => {
  const stateDir = path.join(home, 'state'), configDir = path.join(home, 'config');
  fs.mkdirSync(configDir, { recursive: true }); fs.mkdirSync(stateDir, { recursive: true });
  for (const [name, body] of [['wake-bus', 'off\n'], ['captain-channel', 'set mode off\n'], ['bus-homes', '']]) fs.writeFileSync(path.join(configDir, name), body);
  for (const f of ['.last-fast-check', '.last-check', '.last-heartbeat']) fs.writeFileSync(path.join(stateDir, f), '');
  return { ...base, JG_HOME: home,
    JG_BUS_HOMES: path.join(configDir, 'bus-homes'), JG_CAPTAIN_CHANNEL: path.join(configDir, 'captain-channel'),
    JG_FAST_CHECK_INTERVAL: '86400', JG_CHECK_INTERVAL: '86400', JG_HEARTBEAT: '86400' };
};
const capture = (home, label) => {
  let cadence = '';
  const visit = (dir, rel = '') => { for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const src = path.join(dir, ent.name), next = path.join(rel, ent.name), dest = path.join(evidence, label, 'state', next);
    try { if (ent.isDirectory()) visit(src, next); else if (ent.isFile()) { fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.copyFileSync(src, dest); if (/cadence/i.test(ent.name)) cadence += `${next}: ${read(dest)}\n`; } }
    catch (e) { outputs.push(`capture ${label}/${next}: ${e.message}`); }
  } };
  if (home) try { visit(path.join(home, 'state')); } catch (e) { outputs.push(`capture ${label}: ${e.message}`); }
  return cadence;
};
const startDaemon = (name, extra) => {
  const out = fs.openSync(path.join(labHome, name), 'a'), rec = { name, out, closed: false, exit: null, child: null, started: Date.now() };
  rec.child = spawn('bash', [path.join(root, 'bin/jg-supervise-daemon.sh')], { cwd: root, detached: true, stdio: ['ignore', out, out], env: { ...env, JG_DAEMON_PRIMARY_HARNESS: 'codex', JG_SUPERVISOR_BACKEND: 'tmux', JG_SUPERVISOR_TARGET: sess, ...extra } });
  rec.child.on('exit', (code, signal) => { rec.exit = { code, signal }; });
  rec.child.on('error', (e) => { rec.exit = { error: e.message }; }); daemons.push(rec); return rec;
};
const waitForBatch = async (rec, want) => {
  const until = rec.started + 10000; let line = '';
  while (Date.now() < until) {
    line = daemonLog().split('\n').find((s) => s.includes(`daemon starting (pid ${rec.child.pid})`)) || '';
    if (line) break;
    assert.equal(rec.exit, null, `${rec.name}: daemon exited during startup`);
    await sleep(Math.min(200, Math.max(0, until - Date.now())));
  }
  assert.ok(line, `${rec.name}: no startup line for pid ${rec.child.pid} in state/.supervise-daemon.log within 10 seconds`);
  assert.equal(rec.exit, null, `${rec.name}: daemon exited during startup`);
  assert.equal(line.match(/\bbatch=(\d+s)\b/)?.[1], want, `${rec.name}: unexpected startup batch: ${line}`);
  timing.startup[rec.name] = { pid: rec.child.pid, batch: want, line };
};
const stopDaemon = async (rec) => {
  try {
    if (rec.exit === null) {
      timing.daemons[rec.name] = 'running'; rec.child.kill('SIGTERM');
      const until = Date.now() + 15000; while (rec.exit === null && Date.now() < until) await sleep(100);
      if (rec.exit === null) throw new Error(`${rec.name}: daemon did not exit after SIGTERM`);
    }
    timing.daemons[rec.name] = rec.exit;
  } finally { if (!rec.closed) { fs.closeSync(rec.out); rec.closed = true; } }
};
const startupBatch = async (name, extra, want, step) => {
  const rec = startDaemon(name, extra); await waitForBatch(rec, want); await stopDaemon(rec); steps.push(step);
};
try {
  made = fs.mkdtempSync(path.join(os.tmpdir(), 'jg-codex-lead-'));
  labHome = command('bash', ['bin/jg-lab-home.sh', 'create', made]).trim();
  tmuxDir = command('bash', ['bin/jg-lab-home.sh', 'tmux-dir', labHome]).trim();
  steps.push('create the marked lab home and its private tmux socket directory');
  const stateDir = path.join(labHome, 'state');
  env = { ...isolate(labHome), JG_ROOT_OVERRIDE: labHome, JG_STATE_OVERRIDE: stateDir, TMUX_TMPDIR: tmuxDir };
  fs.writeFileSync(path.join(labHome, '.jg-squad-lead-home'), 'lab-lead\n');
  steps.push('set lab wake-bus and captain-channel off, isolate bus addresses and mark the lab lead');
  const recvLog = path.join(labHome, 'receiver.log'), receiver = path.join(labHome, 'receiver-bin', 'codex');
  fs.mkdirSync(path.dirname(receiver), { recursive: true }); fs.copyFileSync(command('bash', ['-c', 'printf %s "$BASH"']).trim(), receiver); fs.chmodSync(receiver, 0o755);
  const launch = [receiver, path.join(root, 'tests/fixtures/composer/fake-composer.sh'), recvLog].map((s) => "'" + s.replaceAll("'", "'\\''") + "'").join(' ');
  command('tmux', ['new-session', '-d', '-s', sess, '-x', '200', '-y', '40', launch], env);
  for (let i = 0; i < 30 && command('tmux', ['capture-pane', '-p', '-t', sess], env).trim() === ''; i++) await sleep(500);
  steps.push('start a 200x40 private receiver running fake-composer.sh through a copied bash named codex and wait for readiness');
  await startupBatch('startup-nonlead.log', {}, '90s', 'start a no-event non-lead daemon, assert its own pid startup batch=90s, then stop and await it');
  await startupBatch('startup-17.log', { JG_LEAD_DAEMON: '1', JG_ESCALATE_BATCH_SECS: '17' }, '17s', 'start a no-event lead daemon with explicit batch=17s, assert its own pid startup line, then stop and await it');
  const scan = path.join(stateDir, '.watch.lock', 'scan-complete'); assert.equal(fs.existsSync(scan), false, 'startup cleanup left a stale scan-complete marker');
  const main = startDaemon('daemon.log', { JG_LEAD_DAEMON: '1' });
  await waitForBatch(main, '1s'); await sleep(3000); assert.equal(main.exit, null, 'the daemon exited during startup'); process.kill(main.child.pid, 0);
  steps.push('start the real lead daemon with codex primary, tmux backend and explicit target; assert its own pid startup batch=1s');
  const scanUntil = Date.now() + 30000;
  while (!fs.existsSync(scan) && Date.now() < scanUntil) { assert.equal(main.exit, null, 'daemon exited before its first idle scan'); await sleep(200); }
  assert.ok(fs.existsSync(scan), 'real watcher did not complete its first idle scan within 30 seconds'); assert.equal(main.exit, null); process.kill(main.child.pid, 0);
  timing.firstIdleScan = { daemonPid: main.child.pid, elapsedMs: Date.now() - main.started, marker: read(scan) }; steps.push('wait for the running watcher state/.watch.lock/scan-complete before queueing any row');
  const wake = (kind, key, payload) => {
    const script = '. bin/jg-wake-lib.sh && jg_wake_append "$1" "$2" "$3" && printf %s "$JG_WAKE_LAST"';
    const out = command('bash', ['-c', script, 'wake', kind, key, payload], env).trim();
    outputs.push(`$ jg_wake_append ${kind} ${key} "${payload}" -> JG_WAKE_LAST=${out}`); return out;
  };
  const submitted = () => received().split('\n').map((l) => l.match(doorbellRe)).filter(Boolean).map((m) => {
    const abs = path.resolve(labHome, m[1]);
    assert.ok(abs.startsWith(path.join(stateDir, 'operational-inbox') + path.sep), `doorbell outside state/operational-inbox: ${m[1]}`);
    return { abs, body: read(abs) };
  });
  const urgent = () => submitted().filter((r) => r.body.includes('inbox:lab-wake'));
  const batchLast = wake('check', 'merged-fixture', 'routine payload'); assert.equal(batchLast, 'batch:merged-fixture');
  steps.push('append an older batch row: check merged-fixture with a routine payload');
  await sleep(10000); assert.equal(received().trim(), '', 'a batch-only interval submitted input to the receiver');
  steps.push('wait 10 seconds with only the batch row queued and see zero receiver submissions');
  const urgentStart = Date.now();
  const nowLast = wake('check', 'inbox:lab-wake', 'check: inbox:lab-wake'); assert.equal(nowLast, 'now:inbox:lab-wake');
  steps.push('append the urgent row: check inbox:lab-wake');
  let found = null;
  while (Date.now() - urgentStart < 60000) { if (urgent().length > 0) { found = Date.now(); break; } await sleep(500); }
  assert.ok(found, 'the urgent doorbell did not reach the receiver within 60 seconds');
  timing.queueToReceiverMs = found - urgentStart; await sleep(3000);
  const hits = urgent(); assert.equal(hits.length, 1, `receiver got ${hits.length} records holding inbox:lab-wake`); recordBody = hits[0].body;
  const bodyCount = recordBody.split('inbox:lab-wake').length - 1; assert.equal(bodyCount, 1, `record body holds inbox:lab-wake ${bodyCount} times`);
  timing.doorbellRecord = path.relative(labHome, hits[0].abs);
  steps.push('read every submitted doorbell record; exactly one contains inbox:lab-wake, once');
  const beforeRepeat = { total: received().split('\n').filter(Boolean).length, urgent: urgent().length };
  assert.equal(command('bash', ['bin/jg-bus.sh', 'watcher', 'oldest'], env).trim(), '', 'the delivered queue must be empty before repeating the event');
  const repeated = wake('check', 'inbox:lab-wake', 'check: inbox:lab-wake'); assert.equal(repeated, 'batch:inbox:lab-wake');
  const staticClass = command('bash', ['-c', '. bin/jg-wake-lib.sh && jg_wake_route_class "$1" "$2" "$3"', 'route', 'check', 'inbox:lab-wake', 'check: inbox:lab-wake'], env).trim(); assert.equal(staticClass, 'now');
  const ordinaryOldest = command('bash', ['bin/jg-bus.sh', 'watcher', 'oldest'], env).trim(); assert.notEqual(ordinaryOldest, '', 'ordinary oldest lost the repeated batch row');
  const urgentOldest = command('bash', ['bin/jg-bus.sh', 'watcher', 'oldest', '--urgent'], env).trim(); assert.equal(urgentOldest, '', 'urgent oldest exposed a producer-effective batch row');
  const repeatStart = Date.now(); assert.equal(main.exit, null); process.kill(main.child.pid, 0);
  while (Date.now() - repeatStart < 35000) { assert.equal(main.exit, null, 'daemon exited during repeat observation'); process.kill(main.child.pid, 0); await sleep(Math.min(500, Math.max(0, 35000 - (Date.now() - repeatStart)))); }
  assert.equal(main.exit, null, 'daemon exited during repeat observation'); process.kill(main.child.pid, 0);
  const afterRepeat = { total: received().split('\n').filter(Boolean).length, urgent: urgent().length };
  timing.repeatedWake = { producer: repeated, staticClass, ordinaryOldest, urgentOldest, elapsedMs: Date.now() - repeatStart, daemonPid: main.child.pid, before: beforeRepeat, after: afterRepeat };
  assert.equal(afterRepeat.total, beforeRepeat.total, 'the repeated batch event submitted new receiver input'); assert.equal(afterRepeat.urgent, beforeRepeat.urgent, 'the repeated event produced another urgent matching record');
  steps.push('repeat the identical inbox wake; assert producer batch, static now, ordinary oldest present and urgent oldest empty; observe the live daemon for 35 seconds with unchanged receiver and urgent record counts');
} catch (err) { failure = err; } finally {
  capture(labHome, 'watcher-before-cleanup');
  for (const rec of daemons) try { await stopDaemon(rec); timing.cleanup[rec.name] = rec.exit; } catch (e) { cleanupErrors.push(e); timing.cleanup[rec.name] = e.message; }
  capture(labHome, 'watcher-after-cleanup');
  try {
    assert.ok(daemons.every((rec) => rec.exit !== null), 'checkpoint requires all spawned daemons to have exited');
    cpMade = fs.mkdtempSync(path.join(os.tmpdir(), 'jg-codex-checkpoint-')); cpHome = command('bash', ['bin/jg-lab-home.sh', 'create', cpMade]).trim();
    const cpEnv = { ...isolate(cpHome), TMUX_TMPDIR: command('bash', ['bin/jg-lab-home.sh', 'tmux-dir', cpHome]).trim() };
    steps.push('after daemon cleanup, run the actual one-second checkpoint in a separate empty marked lab using plain JG_HOME');
    const cp = spawnSync('bash', ['bin/jg-watch-checkpoint.sh', '--seconds', '1'], { cwd: root, env: cpEnv, encoding: 'utf8', timeout: 30000 });
    checkpoint = { attempted: true, status: cp.status, signal: cp.signal, stdout: cp.stdout || '', stderr: cp.stderr || '', error: cp.error?.message };
    const cadence = capture(cpHome, 'checkpoint'); timing.checkpoint = { status: cp.status, signal: cp.signal, cadence };
    assert.ifError(cp.error); assert.equal(cp.status, 0, `checkpoint failed: ${checkpoint.stderr}`); assert.match(checkpoint.stdout, /checkpoint: no actionable wake within 1s/);
    assert.ok(/\bcadence\b[^\n]*\bphase=quiet\b/i.test(checkpoint.stdout + '\n' + checkpoint.stderr) || /\bphase=quiet\b|"phase"\s*:\s*"quiet"/.test(cadence), 'checkpoint cadence did not report phase=quiet');
    steps.push('assert checkpoint exit 0, no actionable wake within 1s and cadence phase=quiet');
  } catch (e) { failure ||= e; timing.checkpointFailure = e.message; }
  if (labHome) {
    for (const rec of daemons) { const f = path.join(labHome, rec.name); if (fs.existsSync(f)) fs.copyFileSync(f, path.join(evidence, rec.name)); }
    for (const name of ['.supervise-daemon.log', '.supervise-daemon.watcher.err']) { const f = path.join(labHome, 'state', name); if (fs.existsSync(f)) fs.copyFileSync(f, path.join(evidence, name)); else outputs.push(`${name}: absent in lab state`); }
    fs.writeFileSync(path.join(evidence, 'receiver.log'), received());
  }
  if (recordBody !== null) fs.writeFileSync(path.join(evidence, 'record.body.txt'), recordBody);
  if (tmuxDir) {
    try { fs.writeFileSync(path.join(evidence, 'receiver.pane.txt'), command('tmux', ['capture-pane', '-p', '-t', sess], { ...base, TMUX_TMPDIR: tmuxDir })); } catch (e) { timing.receiverPane = `not captured: ${e.message}`; }
    try { command('tmux', ['kill-server'], { ...base, TMUX_TMPDIR: tmuxDir }); timing.cleanup.tmux = 'stopped'; } catch (e) { if (!/no server running|error connecting/.test(e.message)) cleanupErrors.push(e); timing.cleanup.tmux = e.message; }
  }
  for (const [label, home, dir] of [['lab', labHome, made], ['checkpointLab', cpHome, cpMade]]) try { if (home) command('bash', ['bin/jg-lab-home.sh', 'teardown', home]); if (dir) fs.rmSync(dir, { recursive: true, force: true }); timing.cleanup[label] = dir ? 'removed' : 'not created'; } catch (e) { cleanupErrors.push(e); timing.cleanup[label] = e.message; }
  timing.cleanupErrors = cleanupErrors.map((e) => e.message); if (failure) outputs.push(failure.stack || failure.message);
  fs.writeFileSync(path.join(evidence, 'command-output.txt'), outputs.join('\n') + '\n');
  fs.writeFileSync(path.join(evidence, 'checkpoint.stdout.txt'), checkpoint.stdout); fs.writeFileSync(path.join(evidence, 'checkpoint.stderr.txt'), checkpoint.stderr); fs.writeFileSync(path.join(evidence, 'checkpoint-status.json'), JSON.stringify(checkpoint, null, 2) + '\n');
  fs.writeFileSync(path.join(evidence, 'timing.json'), JSON.stringify(timing, null, 2) + '\n');
  fs.writeFileSync(path.join(evidence, 'steps.json'), JSON.stringify({
    target: { version }, start: 'isolated marked lab homes with no real Codex, model or installed state', steps,
    result: failure ? `failed: ${failure.message}` : cleanupErrors.length ? `cleanup failed: ${cleanupErrors[0].message}` : 'PID-matched batches are 90s/17s/1s; a running idle watcher delivers the urgent row once behind a silent batch row within 60s; an identical repeat is producer-batched despite static now classification, remains visible to ordinary oldest but absent from urgent oldest, and adds no receiver submission or urgent matching record over 35s with the daemon alive; the separate empty checkpoint exits 0 with quiet cadence',
  }, null, 2) + '\n');
}
if (failure) throw failure;
if (cleanupErrors.length) throw new AggregateError(cleanupErrors, 'lab cleanup failed');
