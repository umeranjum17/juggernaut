// Real-process journey: a home's own session may stop a reparented tree under its task data or a recorded worktree,
// and everything else keeps the final refusal. Re-runs itself under a shell named "codex" that records its pid in the
// fake home's state/.lock, so the lock proof is genuine; only processes this test starts are signalled.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { join } from 'node:path';

if (process.argv[2] !== '--inner') {
  const temp = fs.realpathSync(fs.mkdtempSync(join(os.tmpdir(), 'kill-home-')));
  try {
    const lead = join(temp, 'home', '.treehouse', 'lead-abc', '1', 'lead'); fs.mkdirSync(join(lead, 'state'), { recursive: true });
    fs.mkdirSync(join(temp, 'bin')); fs.copyFileSync('/bin/sh', join(temp, 'bin', 'codex'));
    execFileSync(join(temp, 'bin', 'codex'), ['-c', `echo $$ > state/.lock; "$0" "$@"; exit $?`, process.execPath, new URL(import.meta.url).pathname, '--inner', temp], { cwd: lead, stdio: 'inherit' });
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
  process.exit(0);
}

const temp = process.argv[3], account = join(temp, 'home');
os.userInfo = () => ({ homedir: account });
syncBuiltinESMExports();
const lead = join(account, '.treehouse', 'lead-abc', '1', 'lead');
const taskData = join(lead, 'data', 'replay-task'), worktree = join(account, '.treehouse', 'proj-x', '1', 'proj'), stray = join(temp, 'elsewhere');
const foreignData = join(account, '.treehouse', 'other-abc', '1', 'other', 'data', 'their-task');
for (const d of [join(taskData, 'run'), worktree, stray, foreignData, join(lead, 'projects')]) fs.mkdirSync(d, { recursive: true });
fs.writeFileSync(join(lead, 'state', 'replay-task.meta'), `worktree=${worktree}\nkind=ship\n`);
fs.symlinkSync(stray, join(lead, 'data', 'linked-away'));

const { guard } = await import(new URL('../guard.mjs', import.meta.url));
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
// A reparented tree: a shell with two sleeping children, detached from this test so nothing here owns it.
const tree = (cwd) => execFileSync('sh', ['-c', 'sh -c "sleep 60 & sleep 60 & wait" </dev/null >/dev/null 2>&1 & echo $!'], { cwd, encoding: 'utf8' }).trim();
const members = (root) => [Number(root), ...execFileSync('pgrep', ['-P', root], { encoding: 'utf8' }).split('\n').filter(Boolean).map(Number)];
const all = [];
// A watcher loop of a home: a bin/jg-watch.sh run (cwd outside every owned root) whose child hangs. Returns the loop and child pids.
const loop = (home) => {
  fs.mkdirSync(join(home, 'bin'), { recursive: true }); const script = join(home, 'bin', 'jg-watch.sh');
  fs.writeFileSync(script, '#!/bin/sh\nsleep 60 &\nwait\n', { mode: 0o755 });
  const pid = execFileSync('sh', ['-c', `${script} </dev/null >/dev/null 2>&1 & echo $!`], { cwd: stray, encoding: 'utf8' }).trim();
  return { pid, child: execFileSync('sh', ['-c', `for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -P ${pid} && exit; sleep 0.1; done`], { encoding: 'utf8' }).trim() };
};
// A detached landing job of a home: `bash <home>/core/trunk-landing/trunk-landing.sh <sub> <home> ...` (cwd outside every owned root)
// whose gate test child hangs in a /tmp clone. Returns the job and child pids.
const landing = (home, sub, named = home) => {
  const dir = join(home, 'core', 'trunk-landing'); fs.mkdirSync(dir, { recursive: true }); const script = join(dir, 'trunk-landing.sh');
  fs.writeFileSync(script, '#!/bin/sh\nsleep 60 &\nwait\n', { mode: 0o755 });
  const pid = execFileSync('sh', ['-c', `bash ${script} ${sub} ${named} lane-01 ${'a'.repeat(40)} </dev/null >/dev/null 2>&1 & echo $!`], { cwd: stray, encoding: 'utf8' }).trim();
  return { pid, child: execFileSync('sh', ['-c', `for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -P ${pid} && exit; sleep 0.1; done`], { encoding: 'utf8' }).trim() };
};
try {
  const owned = tree(join(taskData, 'run')), ownedWt = tree(worktree), unowned = tree(stray), foreign = tree(foreignData), linked = tree(stray);
  all.push(owned, ownedWt, unowned, foreign, linked);
  await new Promise((r) => setTimeout(r, 300));
  const mine = loop(lead), theirs = loop(join(account, '.treehouse', 'other-abc', '1', 'other'));
  all.push(mine.pid, theirs.pid);
  assert(mine.child && theirs.child, 'loop children started');
  assert.equal(guard(`kill ${mine.child}`), null, 'a hung child of this home\'s own watcher loop');
  assert.match(guard(`kill ${mine.pid}`) ?? '', /which this task did not start/, 'the loop itself stays refused');
  assert.match(guard(`kill ${theirs.child}`) ?? '', /which this task did not start/, 'another home\'s loop child');
  console.log('watcher loop journey: hung child of this home\'s own watcher loop allowed; the loop itself and another home\'s loop child refused');
  const runs = ['run', 'runbatch', 'verify'].map((sub) => landing(lead, sub)), strange = landing(lead, 'lookup'), other = landing(join(account, '.treehouse', 'other-abc', '1', 'other'), 'runbatch');
  const misnamed = landing(join(account, '.treehouse', 'third-abc', '1', 'third'), 'run', lead); // names this home but is not under it: still this home's job by its argument
  all.push(...runs.map((r) => r.pid), strange.pid, other.pid, misnamed.pid);
  for (const r of runs) assert.equal(guard(`kill ${r.child}`), null, 'a hung child of this home\'s own landing job');
  assert.equal(guard(`kill ${misnamed.child}`), null, 'a landing job names its home in its arguments');
  assert.match(guard(`kill ${runs[0].pid}`) ?? '', /which this task did not start/, 'the landing job itself stays refused');
  assert.match(guard(`kill ${strange.child}`) ?? '', /which this task did not start/, 'an unknown landing subcommand');
  assert.match(guard(`kill ${other.child}`) ?? '', /which this task did not start/, 'another home\'s landing job child');
  console.log('landing job journey: hung child of this home\'s own landing job allowed; the job itself, an unknown subcommand and another home\'s job child refused');
  // A Main with another name: the guard directory's own `homes` registry names it, and the same lock-and-ancestry proof then makes it Main.
  const projectTree = tree(join(lead, 'projects')); all.push(projectTree);
  const registered = join(temp, 'registered-guard'); fs.mkdirSync(registered);
  fs.copyFileSync(new URL('../guard.mjs', import.meta.url), join(registered, 'guard.mjs'));
  assert.match(guard(`kill ${projectTree}`) ?? '', /which this task did not start/, 'an unregistered home is no Main');
  fs.writeFileSync(join(registered, 'homes'), `relative/path\n${account}\n/elsewhere/home\n${lead}/\n`);
  const named = await import(join(registered, 'guard.mjs'));
  assert.equal(named.guard(`kill ${projectTree}`, { reason: 'stuck gate' }), null, 'a registered Main home\'s fleet paths');
  assert.match(named.guard(`kill ${unowned}`) ?? '', /which this task did not start/, 'a path outside the registered home');
  console.log('registered Main journey: a Main named by the guard registry may stop fleet processes under its home; relative, account-home and outside-account entries and other paths refused');
  const group = members(owned);
  assert(group.length >= 3, 'tree has children');

  assert.equal(guard(`kill ${owned}`), null, 'tree under the home task data dir');
  assert.equal(guard(`kill ${ownedWt}`), null, 'tree under a worktree its task record names');
  const refusal = guard(`kill ${unowned}`);
  assert.match(refusal ?? '', /BLOCKED by the fleet kill guard: "kill \d+" aims at PID \d+ \(sh\), which this task did not start\. .*This block is final/);
  assert.match(guard(`kill ${foreign}`) ?? '', /which this task did not start/, 'another home\'s data dir');
  assert.match(guard(`kill ${linked}`) ?? '', /BLOCKED/, 'a task dir linked outside data/');
  assert.match(guard('pkill -f sleep') ?? '', /name\/pattern kills are forbidden/, 'pattern kills stay refused');
  assert.match(guard('kill 1') ?? '', /PID 1 \(init\)/);
  for (const pid of [unowned, foreign, linked]) assert(alive(pid), 'a refused tree is never signalled');

  // An allowed kill reaps the whole tree: the children go with the shell once we signal each approved member.
  for (const pid of group) assert.equal(guard(`kill ${pid}`), null, `member ${pid}`);
  for (const pid of group) process.kill(pid, 'SIGKILL');
  await new Promise((r) => setTimeout(r, 300));
  for (const pid of group) assert(!alive(pid), `member ${pid} reaped`);
  console.log('home owner tree journey: ok');
} finally { // only trees this test started
  for (const k of all) { let kids = []; try { kids = members(String(k)); } catch {} for (const p of kids) try { process.kill(p, 'SIGKILL'); } catch {} }
}
