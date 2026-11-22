import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';

const root = process.cwd();
const evidence = process.env.DONE_DONE_EVIDENCE_ROOT;
assert.ok(evidence, 'DONE_DONE_EVIDENCE_ROOT is required');
await fs.mkdir(evidence, { recursive: true });
const scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'agent-cli-regressions-'));
const run = (cmd, args, env = process.env) => new Promise((resolve, reject) => {
  const child = spawn(cmd, args, { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  child.stdout.setEncoding('utf8').on('data', x => stdout += x);
  child.stderr.setEncoding('utf8').on('data', x => stderr += x);
  child.on('error', reject);
  child.on('close', code => resolve({ code, stdout, stderr }));
});
const capture = async (name, value) => fs.writeFile(path.join(evidence, name), typeof value === 'string' ? value : JSON.stringify(value, null, 2) + '\n');
const steps = [];
try {
  const lint = await run('bash', ['bin/jg-lint.sh', 'bin/jg-wake-core.sh']);
  await capture('wake-core-lint.log', lint.stdout + lint.stderr);
  assert.equal(lint.code, 0, lint.stderr || lint.stdout);

  const go = execFileSync('which', ['go'], { encoding: 'utf8' }).trim();
  assert.ok(path.isAbsolute(go), 'resolved go executable must be absolute');
  const home = path.join(scratch, 'home'), cache = path.join(scratch, 'cache');
  const bin = path.join(scratch, 'wake-core'), queue = path.join(scratch, 'queue');
  const trace = path.join(scratch, 'go.trace'), wrapper = path.join(scratch, 'go-wrapper.sh');
  await fs.mkdir(home); await fs.mkdir(cache); await fs.writeFile(queue, '');
  assert.equal((await fs.stat(queue)).isFile(), true);
  await fs.writeFile(wrapper, '#!/usr/bin/env bash\nprintf "%s\\n" "$1" >> "$JG_TRACE_FILE"\nexec "$JG_REAL_GO" "$@"\n');
  await fs.chmod(wrapper, 0o755);
  const wakeEnv = {
    ...process.env,
    HOME: home,
    XDG_CACHE_HOME: cache,
    XDG_CONFIG_HOME: path.join(home, '.config'),
    JG_HOME: home,
    JG_STATE_OVERRIDE: path.join(home, 'state'),
    JG_WAKE_CORE_BIN: bin,
    JG_WAKE_CORE_GO: wrapper,
    JG_REAL_GO: go,
    JG_TRACE_FILE: trace,
  };
  const calls = await Promise.all(Array.from({ length: 6 }, () => run('bash', ['bin/jg-wake-core.sh', '--queue', queue, 'count'], wakeEnv)));
  const builds = await fs.readFile(trace, 'utf8').catch(error => {
    if (error.code !== 'ENOENT') throw error;
    return '';
  });
  await capture('wake-concurrency.json', { calls, builds });
  for (const [i, result] of calls.entries()) {
    assert.equal(result.code, 0, `wake call ${i + 1}: ${result.stderr}`);
    assert.equal(result.stdout.trim(), '0');
  }
  assert.equal(builds.trim(), 'build', 'concurrent callers must share one build');
  await assert.rejects(fs.lstat(wakeEnv.JG_STATE_OVERRIDE), { code: 'ENOENT' });
  await assert.rejects(fs.lstat(bin + '.build.lock'), { code: 'ENOENT' });
  steps.push('Run six concurrent wake queue counts against one missing binary in an isolated home.');

  const inventory = await run('python3', ['-I', 'core/agent-cli/inventory/parse.py', 'get', '.', 'core/agent-cli/operations.tsv', path.join(scratch, 'FRESH_SCRATCH'), '--only', 'jg-crew-state.sh', '--jobs', '1']);
  await capture('inventory-get.json', inventory);
  assert.equal(inventory.code, 0, inventory.stderr);
  assert.match(inventory.stdout, /^get\tok\tjg-crew-state\.sh\t/m);
  steps.push('Run the isolated inventory GET check for jg-crew-state.sh and inspect its status row.');

  const observer = path.join(scratch, 'bash-env-observer.sh');
  const observed = path.join(scratch, 'forms-startup.txt');
  const contractLog = path.join(evidence, 'contract.log');
  const formsPath = 'core/agent-cli/tests/forms.test.sh';
  await fs.writeFile(observer, 'if [[ "$0" == "$JG_FORMS_SCRIPT" ]]; then\n  if grep -Fqx "PASS core/agent-cli/tests/contract.test.sh" "$JG_CONTRACT_LOG" 2>/dev/null; then printf "prior-pass\\n" > "$JG_FORMS_OBSERVATION"; else printf "no-prior-pass\\n" > "$JG_FORMS_OBSERVATION"; fi\nfi\n');
  const suiteEnv = { ...process.env, BASH_ENV: observer, JG_FORMS_SCRIPT: formsPath, JG_CONTRACT_LOG: contractLog, JG_FORMS_OBSERVATION: observed };
  const suite = await run('bash', ['journeys/agent-cli-contract.sh', ...process.argv.slice(2)], suiteEnv);
  await capture('agent-cli-contract.log', suite.stdout + suite.stderr);
  const observation = await fs.readFile(observed, 'utf8').catch(() => '');
  await capture('forms-startup.txt', observation);
  assert.equal(suite.code, 0, `agent CLI journey failed (${suite.code})`);
  assert.equal(observation.trim(), 'no-prior-pass', 'forms must start before contract reports PASS');
  for (const name of ['contract', 'inventory', 'forms']) {
    const log = await fs.readFile(path.join(evidence, `${name}.log`), 'utf8');
    assert.ok(log.split('\n').includes(`PASS core/agent-cli/tests/${name}.test.sh`), `${name} did not publish PASS`);
  }
  steps.push('Drive the existing agent CLI contract journey with the caller supplied release ref.');
  steps.push('Observe forms.test.sh startup and confirm contract had not reported PASS yet.');
  const version = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
  await fs.writeFile(path.join(evidence, 'steps.json'), JSON.stringify({ target: { version }, start: 'Repository HEAD with isolated temporary home, cache, queue, and inventory scratch.', steps, result: 'Six wake counts exited successfully and printed 0 with one traced build and no state override or lingering lock; the inventory GET reported ok; the agent CLI journey passed and forms started before contract PASS.' }, null, 2) + '\n');
} finally {
  await fs.rm(scratch, { recursive: true, force: true });
}
