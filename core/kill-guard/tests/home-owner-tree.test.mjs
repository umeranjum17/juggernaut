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
try {
  const owned = tree(join(taskData, 'run')), ownedWt = tree(worktree), unowned = tree(stray), foreign = tree(foreignData), linked = tree(stray);
  all.push(owned, ownedWt, unowned, foreign, linked);
  await new Promise((r) => setTimeout(r, 300));
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
