#!/usr/bin/env bash
# Drive the installed done-done doctor through the documented author routes.
exec node --input-type=module - <<'JS'
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';

const evidence = process.env.DONE_DONE_EVIDENCE_ROOT;
assert.ok(evidence, 'DONE_DONE_EVIDENCE_ROOT is required');
fs.mkdirSync(evidence, { recursive: true });
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'done-done-author-route-'));
const repo = path.join(temp, 'repo');
const home = path.join(temp, 'home');
const doneHome = path.join(temp, 'done-home');
const jgHome = path.join(temp, 'jg-home');
const rows = {};
const steps = [];
let version = 'unknown';
let result = 'Journey did not complete';

function run(command, args, env, cwd = repo) {
  const child = spawnSync(command, args, { cwd, env, encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024 });
  if (child.error) throw new Error(`${command} launch failed: ${child.error.message}`);
  if (child.signal) throw new Error(`${command} terminated by ${child.signal}`);
  return child;
}

try {
  const source = JSON.parse(fs.readFileSync('docs/examples/tool-models.json', 'utf8'));
  assert.ok(Array.isArray(source.rules));
  const matches = source.rules.filter(rule => rule.tool === 'done-done-author');
  assert.equal(matches.length, 1);
  const rule = matches[0];
  for (const dir of [repo, home, doneHome, path.join(jgHome, 'config')]) fs.mkdirSync(dir, { recursive: true });
  const env = { PATH: process.env.PATH || '/usr/bin:/bin', HOME: home, DONE_DONE_HOME: doneHome, JG_HOME: jgHome };
  const init = run('git', ['init', '--quiet'], env);
  assert.equal(init.status, 0, `git init failed: ${init.stderr}`);
  fs.writeFileSync(path.join(repo, '.done-done.yaml'), 'app: author-route-probe\n');
  fs.writeFileSync(path.join(doneHome, 'config.yaml'), 'agent: claude\nagent_path_override:\n  claude: /bin/false\n  codex: /bin/false\n');
  const defaultFile = path.join(jgHome, 'config', 'tool-models.json');
  fs.writeFileSync(defaultFile, JSON.stringify({ rules: [rule] }));
  const v = run('done-done', ['--version'], env);
  assert.equal(v.status, 0, `done-done --version failed: ${v.stderr}`);
  version = v.stdout.trim();

  function doctor(label, override) {
    const child = run('done-done', ['doctor', '--json'], override ? { ...env, JG_TOOL_MODELS: override } : env);
    let report;
    try { report = JSON.parse(child.stdout); } catch (error) {
      throw new Error(`${label}: doctor did not return JSON: ${error.message}; stderr: ${child.stderr}`);
    }
    assert.ok(report && typeof report === 'object' && !Array.isArray(report), `${label}: invalid report`);
    assert.ok(Array.isArray(report.checks), `${label}: report has no checks array`);
    const found = report.checks.filter(row => row && row.check === 'agent');
    rows[label] = found;
    assert.equal(found.length, 1, `${label}: expected exactly one agent check`);
    assert.equal(typeof found[0].detail, 'string', `${label}: agent detail missing`);
    return found[0].detail;
  }

  const first = doctor('default');
  steps.push('Run doctor with the documented author rule in the synthetic Juggernaut home.');
  assert.ok(first.startsWith('codex (model gpt-6.1-terra;'), first);
  const reversed = path.join(temp, 'reversed.json');
  fs.writeFileSync(reversed, JSON.stringify({ rules: [{ ...rule, use: [...rule.use].reverse() }] }));
  const second = doctor('override', reversed);
  steps.push('Run doctor with JG_TOOL_MODELS pointing to the reversed author rule.');
  assert.ok(second.startsWith('codex (model gpt-6.2-sol;'), second);
  fs.unlinkSync(defaultFile);
  const third = doctor('fallback');
  steps.push('Remove the default rule and run doctor without an override.');
  assert.match(third, /claude/i);
  assert.ok(third.includes('/bin/false'), third);
  result = `Doctor reports ${first}; then ${second}; then ${third}.`;
} catch (error) {
  result = `Journey failed: ${error.message}`;
  console.error(error.stack || error);
  process.exitCode = 1;
} finally {
  fs.writeFileSync(path.join(evidence, 'agent-rows.json'), JSON.stringify(rows, null, 2) + '\n');
  fs.writeFileSync(path.join(evidence, 'steps.json'), JSON.stringify({ target: { version }, start: 'A synthetic git repository and empty temporary homes, with the documented author rule and a Claude fallback.', steps, result }, null, 2) + '\n');
  fs.rmSync(temp, { recursive: true, force: true });
}
JS
