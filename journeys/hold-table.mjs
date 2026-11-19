import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

assert.ok(process.env.DONE_DONE_EVIDENCE_ROOT, 'DONE_DONE_EVIDENCE_ROOT is required');
const evidence = path.resolve(process.env.DONE_DONE_EVIDENCE_ROOT);
const captures = path.join(evidence, 'hold-table-protocol');
fs.mkdirSync(captures, { recursive: true });
const log = path.join(evidence, 'hold-table-capture.log');
fs.writeFileSync(log, '');
const env = { ...process.env, DONE_DONE_EVIDENCE_ROOT: evidence, HOLD_TABLE_CAPTURE: captures };
for (const key of ['JG_BEADS_TEST_BD', 'JG_BEADS_TEST_DOLT']) {
  assert.ok(env[key] && path.isAbsolute(env[key]), `${key} must supply its installed pinned absolute path`);
  fs.accessSync(env[key], fs.constants.X_OK);
}
function run(command, args, input) {
  const result = spawnSync(command, args, { env, input, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  fs.appendFileSync(log, `$ ${command} ${args.join(' ')}\n${result.stdout || ''}${result.stderr || ''}\nexit=${result.status} signal=${result.signal || ''}\n`);
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} failed; see ${log}`);
  return result.stdout;
}
const text = name => fs.readFileSync(path.join(captures, `${name}.out`), 'utf8');
const output = name => text(name) + fs.readFileSync(path.join(captures, `${name}.err`), 'utf8');
const json = name => JSON.parse(text(name));
const steps = [];
try {
  const version = run('git', ['rev-parse', 'HEAD']).trim();
  assert.match(version, /^[0-9a-f]{40,64}$/);
  run('bash', ['--noprofile', '--norc', '-s'], String.raw`set -euo pipefail
export JG_BEADS_TEST_BD JG_BEADS_TEST_DOLT
source tests/lib.sh
fixture=$(jg_test_tmproot owner-waits)
home=$fixture/home
mkdir -p "$home/state" "$home/projects/sample"
jg_test_beads_home "$home"
export JG_HOME=$home JG_DATA_OVERRIDE=$home/data JG_STATE_OVERRIDE=$home/state JG_CONFIG_OVERRIDE=$home/config
E=$HOLD_TABLE_CAPTURE
run() {
  local name=$1 rc=0
  shift
  printf '$'; printf ' %q' "$@"; printf '\n'
  "$@" > "$E/$name.out" 2> "$E/$name.err" || rc=$?
  cat "$E/$name.out" "$E/$name.err"
  printf '\nexit=%s\n' "$rc"
  return "$rc"
}
snapshot() {
  run "$1" python3 -c 'import base64,json,os,sys; p=sys.argv[1]; s=os.stat(p); print(json.dumps({"inode":s.st_ino,"mtime_ns":s.st_mtime_ns,"size":s.st_size,"content_base64":base64.b64encode(open(p,"rb").read()).decode()}))' "$2"
}
board() { printf '%s\n' '{"interface":1}' | python3 "$ROOT/bin/jg-ticket-adapter.py" list; }
run order-add bash "$ROOT/bin/jg-backlog.sh" add jg-order "[captain-ask] Build requested change" --repo sample --priority 0 --body "Captain: Build requested change."
run order-hold bash "$ROOT/bin/jg-captain-hold.sh" hold jg-order --reason "captain stop order"
run order-questions bash "$ROOT/bin/jg-backlog.sh" questions --ticket jg-order --json
run choice-add bash "$ROOT/bin/jg-backlog.sh" add jg-choice "[feature] Choose product route" --repo sample --body "Choose A or B."
run choice-hold bash "$ROOT/bin/jg-captain-hold.sh" hold jg-choice --must design-pick --reason "Which product route should we use? A or B?"
run choice-before bash "$ROOT/bin/jg-backlog.sh" questions --ticket jg-choice --json
run board-before board
run expiry-first env JG_CAPTAIN_HOLD_NOW=2099-01-01T00:00:00Z bash "$ROOT/bin/jg-captain-hold.sh" reconcile check
snapshot request-first "$home/state/reconcile-requests/jg-choice.request"
run choice-expiry-first bash "$ROOT/bin/jg-backlog.sh" questions --ticket jg-choice --json
run expiry-second env JG_CAPTAIN_HOLD_NOW=2099-01-01T00:00:00Z bash "$ROOT/bin/jg-captain-hold.sh" reconcile check
snapshot request-second "$home/state/reconcile-requests/jg-choice.request"
run choice-expiry-second bash "$ROOT/bin/jg-backlog.sh" questions --ticket jg-choice --json
run choice2-add bash "$ROOT/bin/jg-backlog.sh" add jg-choice2 "[feature] Umer chooses another product route" --repo sample --body "Umer must choose C or D."
run choice2-hold bash "$ROOT/bin/jg-captain-hold.sh" hold jg-choice2 --must design-pick --reason "Umer, which product route should we use? C or D?"
run choice2-before bash "$ROOT/bin/jg-backlog.sh" questions --ticket jg-choice2 --json
run cap-first env JG_CAPTAIN_CALL_CAP=1 bash "$ROOT/bin/jg-captain-hold.sh" reconcile check
snapshot latch-first "$home/state/.captain-call-cap-alert"
run cap-second env JG_CAPTAIN_CALL_CAP=1 bash "$ROOT/bin/jg-captain-hold.sh" reconcile check
snapshot latch-second "$home/state/.captain-call-cap-alert"
run choice-final bash "$ROOT/bin/jg-backlog.sh" questions --ticket jg-choice --json
run choice2-final bash "$ROOT/bin/jg-backlog.sh" questions --ticket jg-choice2 --json
run order-final bash "$ROOT/bin/jg-backlog.sh" questions --ticket jg-order --json
run board-final board
`);
  steps.push('Create and hold a Captain order; inspect its questions and the ticket board.');
  steps.push('Create a product choice and ask a real design-pick question; inspect its generated gate and expiry.');
  steps.push('Reconcile twice at 2099-01-01T00:00:00Z; capture the request file and unanswered gate after each call.');
  steps.push('Ask Umer a second product question, reconcile twice with home cap 1, and inspect the alert latch.');
  steps.push('Read both final owner questions and the final ticket board.');
  function gate(name, ticket, previous) {
    const rows = json(name);
    assert.ok(Array.isArray(rows), `${name} must be an array`);
    assert.equal(rows.length, 1, `${ticket} must have exactly one question`);
    const row = rows[0];
    assert.ok(typeof row.id === 'string' && row.id.length > 0);
    for (const [key, value] of Object.entries({ ticket, must: 'design-pick', state: 'open', resolution: '-', words: '', until: '-' })) {
      assert.equal(row[key], value, `${name}: ${key}`);
    }
    assert.match(row.expires_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/);
    assert.ok(Number.isFinite(Date.parse(row.expires_at)));
    if (previous) {
      assert.equal(row.id, previous.id, `${name}: preserve the generated gate`);
      assert.equal(row.expires_at, previous.expires_at, `${name}: preserve expiry`);
    }
    return row;
  }
  function board(name, tickets) {
    const value = json(name);
    assert.equal(value.complete, true);
    assert.ok(Array.isArray(value.tickets));
    assert.ok(!value.tickets.some(row => row.id === 'main--jg-order' || row.id === 'jg-order'));
    for (const ticket of tickets) {
      const rows = value.tickets.filter(row => row.id === `main--${ticket}`);
      assert.equal(rows.length, 1, `${name}: ${ticket} board row`);
      assert.equal(rows[0].status, 'Waiting for you');
    }
    return value;
  }
  assert.deepEqual(json('order-questions'), []);
  const choice = gate('choice-before', 'jg-choice');
  assert.ok(Date.parse(choice.expires_at) < Date.parse('2099-01-01T00:00:00Z'));
  board('board-before', ['jg-choice']);
  const expiryMessage = `reconcile: jg-choice expired question ${choice.id}; recheck its evidence, keep open until settled`;
  assert.equal(output('expiry-first').trim(), expiryMessage);
  gate('choice-expiry-first', 'jg-choice', choice);
  assert.equal(output('expiry-second').trim(), '');
  gate('choice-expiry-second', 'jg-choice', choice);
  assert.deepEqual(json('request-second'), json('request-first'), 'repeat expiry must preserve the existing reconciliation request');
  const choice2 = gate('choice2-before', 'jg-choice2');
  assert.notEqual(choice2.id, choice.id);
  const capMessage = 'owner-call cap: 2 open questions exceed home cap 1; review existing calls before adding more';
  assert.equal(output('cap-first').trim(), capMessage);
  assert.ok(!output('cap-second').includes('owner-call cap:'), 'repeat cap check must not repeat its alert');
  assert.deepEqual(json('latch-second'), json('latch-first'), 'cap alert must retain its existing latch');
  const finalChoice = gate('choice-final', 'jg-choice', choice);
  const finalChoice2 = gate('choice2-final', 'jg-choice2', choice2);
  assert.deepEqual(json('order-final'), []);
  board('board-final', ['jg-choice', 'jg-choice2']);
  fs.writeFileSync(path.join(evidence, 'steps.json'), JSON.stringify({
    target: { version: `juggernaut@${version}` },
    start: 'A fresh isolated real Beads home and an empty sample project; no installed home state copied.',
    steps,
    result: `jg-order has no question or board row. ${finalChoice.id} and ${finalChoice2.id} remain ${finalChoice.state}, unanswered, and Waiting for you. Observed expiry: ${expiryMessage}. Observed cap: ${capMessage}. Repeated checks preserve the request and alert latch without repeating their alerts.`
  }, null, 2) + '\n');
} catch (error) {
  fs.appendFileSync(log, `${error.stack || error}\n`);
  throw error;
}
