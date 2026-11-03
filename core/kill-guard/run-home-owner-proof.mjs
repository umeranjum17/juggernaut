// Drive the real guard CLI as a lead home's own session, plus the real lane runner and teardown reap, on live process trees.
// An owned tree under the home's task data is stopped and reaped, an unowned tree is refused and never signalled, and a
// lane that starts a replay harness and finishes (or is killed) leaves no surviving process. Only processes this proof starts are signalled.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fork, spawn, spawnSync, execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const ev = process.env.DONE_DONE_EVIDENCE_ROOT; assert(ev, 'DONE_DONE_EVIDENCE_ROOT required');
const here = dirname(fileURLToPath(import.meta.url)), repo = join(here, '..', '..');
const temp = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), 'kill-home-'))), account = join(temp, 'account'), lead = join(account, '.treehouse', 'lead-abc', '1', 'lead');
const copy = join(temp, 'kill-guard'), data = join(lead, 'data', 'replay-task'), elsewhere = join(temp, 'elsewhere'), state = join(temp, 'state');
const log = (t) => fs.appendFileSync(join(ev, 'journey.txt'), t + '\n'), alive = (p) => { try { process.kill(p, 0); return true; } catch { return false; } };
for (const d of [copy, join(lead, 'state'), join(data, 'run'), elsewhere, state]) fs.mkdirSync(d, { recursive: true });
fs.copyFileSync(join(here, 'guard.mjs'), join(copy, 'guard.mjs'));
const preload = join(temp, 'account.cjs'), helper = join(temp, 'caller.cjs');
fs.writeFileSync(preload, `const os=require('node:os'),o=os.userInfo;os.userInfo=()=>({...o(),homedir:${JSON.stringify(account)}});require('node:module').syncBuiltinESMExports();`);
fs.writeFileSync(helper, `const fs=require('node:fs'),{spawnSync}=require('node:child_process');process.title='codex';
const [guard,preload,lock]=process.argv.slice(2);fs.writeFileSync(lock,process.pid+'\\n');
process.on('message',({command,execute})=>{const r=spawnSync(process.execPath,['--require',preload,guard,'--caller',String(process.pid)],{input:JSON.stringify({tool_input:{command}}),encoding:'utf8'});
const sent=r.status===0&&execute?spawnSync('/bin/kill',['-KILL',command.split(' ').at(-1)]).status:null;process.send({status:r.status,stderr:r.stderr,sent});});process.send({ready:true});`);
const tree = (cwd) => { const root = Number(execFileSync('sh', ['-c', 'sh -c "sleep 120 & sleep 120 & wait" </dev/null >/dev/null 2>&1 & echo $!'], { cwd, encoding: 'utf8' }).trim()); return root; };
const members = (root) => [root, ...spawnSync('pgrep', ['-P', String(root)], { encoding: 'utf8' }).stdout.split('\n').filter(Boolean).map(Number)];
const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms));
let agent; const roots = [];
try {
  agent = fork(helper, [join(copy, 'guard.mjs'), preload, join(lead, 'state', '.lock')], { cwd: lead, stdio: ['ignore', 'ignore', 'inherit', 'ipc'] });
  await new Promise((r) => agent.once('message', r));
  const ask = (command, execute = false) => new Promise((r) => { agent.once('message', r); agent.send({ command, execute }); });
  log('Real guard CLI as a lead home session (the home\'s state/.lock names this harness); trees below are reparented, so nobody here started them.');
  const owned = tree(join(data, 'run')), unowned = tree(elsewhere); roots.push(owned, unowned); await sleepMs(400);
  const group = members(owned); assert(group.length >= 3);
  for (const pid of group) { const r = await ask(`kill ${pid}`, true); assert.equal(r.status, 0, r.stderr); assert.equal(r.sent, 0); }
  await sleepMs(300); for (const pid of group) assert(!alive(pid), `member ${pid} reaped`);
  log(`\n1. Tree under the home's task data (cwd ${data.replace(temp, '<tmp>')}/run), ${group.length} processes: each kill approved (exit 0), all reaped.`);
  const refused = await ask(`kill ${unowned}`); assert.equal(refused.status, 2); assert.match(refused.stderr, /BLOCKED by the fleet kill guard: "kill \d+" aims at PID \d+ \(sh\), which this task did not start\. .*This block is final/);
  const others = members(unowned); for (const pid of others) assert(alive(pid), 'refused tree untouched');
  log(`\n2. Tree outside the home (cwd <tmp>/elsewhere) -> blocked (exit 2), all ${others.length} processes still alive:\n${refused.stderr.trim()}`);
  const pattern = await ask('pkill -f sleep'); assert.equal(pattern.status, 2); assert.match(pattern.stderr, /name\/pattern kills are forbidden/);
  log(`\n3. pkill -> blocked (exit 2):\n${pattern.stderr.trim()}`);
  for (const pid of others) try { process.kill(pid, 'SIGKILL'); } catch {}

  // Lane harness. The harness backgrounds a replay loop in another session and cwd, then ends.
  const harness = join(temp, 'harness.sh'), marker = join(temp, 'pids');
  fs.writeFileSync(harness, `#!/bin/sh\n(cd / && setsid sleep 130 </dev/null >/dev/null 2>&1 & echo $! >> '${marker}')\nsleep 131 </dev/null >/dev/null 2>&1 &\necho $! >> '${marker}'\nif [ "$1" = stay ]; then sleep 132; fi\nexit 7\n`, { mode: 0o755 });
  const env = { ...process.env, JG_HOME: temp, JG_STATE_OVERRIDE: state, JG_ROOT_OVERRIDE: repo };
  const lane = spawnSync(join(repo, 'bin', 'jg-lane-run.sh'), ['proof-task', '--', harness], { env, encoding: 'utf8' }); assert.equal(lane.status, 7);
  await sleepMs(300); const left1 = fs.readFileSync(marker, 'utf8').split('\n').filter(Boolean).map(Number); assert.equal(left1.length, 2);
  for (const pid of left1) assert(!alive(pid), `harness process ${pid} survived its finished lane`);
  log(`\n4. Lane starts a replay harness (a loop in another session and cwd) and finishes with status 7: ${left1.length} harness processes, none survive.`);
  fs.writeFileSync(marker, '');
  const wrapper = spawn(join(repo, 'bin', 'jg-lane-run.sh'), ['proof-task', '--', harness, 'stay'], { env, detached: true, stdio: 'ignore' });
  await sleepMs(1000); process.kill(wrapper.pid, 'SIGKILL');
  const left2 = fs.readFileSync(marker, 'utf8').split('\n').filter(Boolean).map(Number); assert.equal(left2.length, 2); assert(left2.every(alive), 'killed lane left its harness');
  const empty = join(temp, 'emptydir'); fs.mkdirSync(empty);
  const reap = spawnSync(join(repo, 'bin', 'jg-teardown-core.sh'), ['reap', '--label', 'proof', '--task-id', 'proof-task', '--backend', 'herdr', '--target', 'x', '--caller-pid', String(process.pid), '--lane-groups', join(state, 'proof-task.lane-groups'), '--', empty],
    { env: { ...env, JG_TEARDOWN_CORE_BIN: join(temp, 'core-bin') }, encoding: 'utf8' });
  assert.equal(reap.status, 0, reap.stderr); await sleepMs(300);
  for (const pid of left2) assert(!alive(pid), `harness process ${pid} survived teardown`);
  log(`\n5. Lane killed outright (no trap ran): ${left2.length} harness processes still alive; teardown reap exit 0:\n${reap.stderr.trim()}\nAll gone. PASS.`);
  const version = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: here, encoding: 'utf8' }).trim();
  fs.writeFileSync(join(ev, 'steps.json'), JSON.stringify({ target: { version }, start: 'Disposable guard CLI copy, fake account with a lead home whose harness holds state/.lock; live reparented process trees.', steps: ['Home session stops a tree under its task data and every process is reaped', 'Tree outside the home is refused with the same message and stays alive', 'pkill is still refused', 'A lane runs a replay harness and finishes: nothing survives', 'A lane killed outright: teardown reaps the harness by its recorded token'], result: 'a home can stop and reap process trees under its own task data, still cannot touch others, and a finished or killed lane leaves no harness processes' }, null, 2));
} finally {
  for (const r of roots) for (const p of members(r)) try { process.kill(p, 'SIGKILL'); } catch {}
  if (agent?.exitCode === null) agent.kill();
  fs.rmSync(temp, { recursive: true, force: true });
}
