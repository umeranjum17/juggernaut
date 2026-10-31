// Real-git journey: Main may kill a process whose cwd is a worktree of a registered lead home's project.
// Re-runs itself under a shell named "codex" (node renames its own comm) in a fake account home, so Main verification is genuine; nothing real is signalled.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { join } from 'node:path';

if (process.argv[2] !== '--inner') {
  const temp = fs.realpathSync(fs.mkdtempSync(join(os.tmpdir(), 'kill-lead-')));
  try {
    const main = join(temp, 'home', 'juggernaut'); fs.mkdirSync(join(main, 'state'), { recursive: true });
    fs.mkdirSync(join(temp, 'bin')); fs.copyFileSync('/bin/sh', join(temp, 'bin', 'codex'));
    // The shell is Main's anchor: it records its own PID as the lock, and the test runs as its child (no exec, so it stays alive).
    execFileSync(join(temp, 'bin', 'codex'), ['-c', `echo $$ > state/.lock; "$0" "$@"; exit $?`, process.execPath, new URL(import.meta.url).pathname, '--inner', temp], { cwd: main, stdio: 'inherit' });
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
  process.exit(0);
}

const temp = process.argv[3], account = join(temp, 'home'), main = join(account, 'juggernaut');
os.userInfo = () => ({ homedir: account });
syncBuiltinESMExports();
const lead = join(account, '.treehouse', 'lead-abc', '1', 'lead');
const git = (cwd, ...a) => execFileSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', ...a], { cwd, stdio: 'ignore' });
const worktreeOf = (home, name) => { // a project clone under <home>/projects with a task worktree beside the pool
  const clone = join(home, 'projects', name), tree = join(account, '.treehouse', `${name}-x`, '1', name);
  fs.mkdirSync(clone, { recursive: true }); git(clone, 'init', '-q'); git(clone, 'commit', '-q', '--allow-empty', '-m', 'init');
  fs.mkdirSync(join(tree, '..'), { recursive: true }); git(clone, 'worktree', 'add', '-q', '--detach', tree);
  return tree;
};
fs.mkdirSync(join(lead, 'data'), { recursive: true });
const leadTree = worktreeOf(lead, 'demo'), strayTree = worktreeOf(join(temp, 'unregistered'), 'other');
fs.mkdirSync(join(main, 'data'));

const { guard } = await import(new URL('../guard.mjs', import.meta.url));
// Reparented to init, so this task does not own it and only the fleet rule can allow the kill.
const sleeper = (cwd) => +execFileSync('sh', ['-c', 'sleep 60 </dev/null >/dev/null 2>&1 & echo $!'], { cwd, encoding: 'utf8' });
const kids = [];
try {
  const a = sleeper(leadTree), b = sleeper(strayTree); kids.push(a, b);
  await new Promise((r) => setTimeout(r, 200));
  assert.match(guard(`kill ${a}`) ?? '', /BLOCKED/, 'lead home not registered yet');
  fs.writeFileSync(join(main, 'data', 'squad_leads.md'), `- lead - Owns demo. (home: ${lead}; scope: demo; projects: demo; added 2026-10-01)\n`);
  assert.equal(guard(`kill ${a}`), null, 'registered lead project worktree');
  assert.match(guard(`kill ${b}`) ?? '', /BLOCKED/, 'unregistered worktree stays blocked');
  console.log('lead project worktree journey: ok');
} finally { for (const k of kids) process.kill(k); }
