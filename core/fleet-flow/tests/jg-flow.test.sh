#!/usr/bin/env bash
# Integration: query the real flow CLI over isolated durable fleet records.
# Run it with JG_BIN pointing at a Juggernaut checkout's bin/: the reader sources
# its helper libraries from there and the second block drives the fork's
# model/skill statistics and outcome-recording readers, which did not move.
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[ -n "${JG_BIN:-}" ] && [ -f "$JG_BIN/jg-classify-lib.sh" ] || {
  echo "jg-flow test: set JG_BIN to a Juggernaut checkout's bin/ (helper libraries live there)" >&2
  exit 2
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/xdg" "$TMP/tmp"
# A fixture home on the tickets tables (fleet.db); config/beads-dir is kept until bin/jg-backlog-lib.sh stops asking for a store path.
core_tables_home() {  # <checkout> <home>
  mkdir -p "$2/config" "$2/data" && printf '%s\n' "$2" > "$2/config/beads-dir" && : > "$2/config/backlog-intake-loose"
  case ":$PATH:" in *":$1/bin:"*) ;; *) PATH=$1/bin:$PATH; export PATH ;; esac
  JG_HOME=$2 python3 -I "$1/core/item-store/adapters/tickets.py" import --home main /dev/null >/dev/null
}
for h in main child grand; do core_tables_home "$(cd "$JG_BIN/.." && pwd)" "$TMP/$h"; done
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" TMPDIR="$TMP/tmp" python3 - "$ROOT/bin/jg-flow.sh" "$TMP" <<'PY'
import hashlib, json, os, shlex, shutil, socket, subprocess, sys, threading
from pathlib import Path
script, tmp = sys.argv[1], Path(sys.argv[2])
main, child = tmp / 'main', tmp / 'child'
def tx(home, *args):
    r = subprocess.run(['jg-backlog.sh', *args], env=dict(os.environ, JG_HOME=str(home)), capture_output=True, text=True)
    assert r.returncode == 0, (args, r.stdout, r.stderr)
for h in (main, child):
    (h / 'state').mkdir(parents=True, exist_ok=True)
(main / 'data/squad_leads.md').write_text(f'- child - Worker (home: {child}; scope: app; projects: app)\n')
(child / 'data/squad_leads.md').write_text(f'- main - Parent (home: {main}; scope: fleet; projects: app)\n')
# Exact rejected-key return from writeboost.status; key and timestamp remain unknown.
(main / 'state/child.status').write_text('done [key=ov-rn-setup-polish corr=03b23bf8e7b2c26c]: PR 26 merged and verified - guarded merge read back state=MERGED at the exact checked head 2c7f3076 with all checks green; task cleaned up; per your words, production-phone replacement and live ChatGPT remain separately unapproved\n')
for i, t in (('jg-next', 'Next'), ('jg-held', 'Held'), ('jg-ready', 'Ready'), ('jg-prior', 'Prerequisite'), ('jg-finished', 'Completed')):
    tx(main, 'add', i, t)
tx(main, 'start', 'jg-prior')
tx(main, 'done', 'jg-finished')
tx(main, 'block', 'jg-next', '--by', 'jg-prior')
tx(main, 'block', 'jg-ready', '--by', 'jg-finished')
tx(main, 'hold', 'jg-held', '--reason', 'Wait for You')
(child / 'state/live.meta').write_text('kind=ship\nspawn_gen=s99.1.2\n')
(child / 'state/live.status').write_text('working [at=10]: building\n'
    'needs-decision [at=20] [key=captain-hold-a]: choose scope\n'
    'blocked [at=25] [key=external]: external credential\n'
    'done [at=30]: implemented\nresolved [at=40] [key=external]: credential ready\n'
    'working [at=50]: resumed\nworking [at=60]: still working\n')
(child / 'state/unknown.meta').write_text('kind=scout\n')
(child / 'state/unknown.status').write_text('blocked: missing timestamp\n')
ledger = [dict(v=1, task='closed', ts=t, event='task.' + event) for t, event in
          [(10, 'dispatched'), (20, 'status'), (35, 'pr_ready'), (70, 'merged'), (80, 'cleaned_up')]]
ledger[1].update(state='working', text='building')
(child / 'state/fleet-ledger.jsonl').write_text('\n'.join(map(json.dumps, ledger + [ledger[3]])) + '\n{bad}\n')
def files():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for h in (main, child) for p in h.rglob('*') if p.is_file()}
def run():
    return subprocess.check_output(['bash', script, '--json', '--now', '100'],
                                   env=dict((k, v) for k, v in dict(os.environ, JG_HOME=str(main), JG_DATA_OVERRIDE='').items()
                                            if k != 'BACKLOG_BACKEND'))
before = files()
a = run()
assert a == run() and files() == before, 'deterministic and read-only'
x = json.loads(a)
assert x['homes'] == ['child', 'main'], 'registry cycle deduplicated'
live = next(l for l in x['lanes'] if l['task'] == 'live')
assert live['seconds_in_stage'] == 50 and len(live['open_waits']) == 1
assert live['open_waits'][0]['seconds'] == 80, 'done/working do not close keyed wait'
assert live['times']['dispatched'] is None, 'spawn incarnation is not pickup'
assert live['state_seconds'] == {'working': 20, 'needs-decision': 5, 'blocked': 5, 'done': 10, 'resolved': 10}, 'stage time from recorded status intervals'
closed = x['executed_24h'][0]
assert len(x['executed_24h']) == 1 and closed['durations']['time_to_merge'] == 60
assert closed['durations']['merge_to_cleanup'] == 10
assert closed['state_seconds'] == {'working': 50}, 'the trailing stage runs to the merge'
assert 'pr_opened' not in closed['times'] and 'checks_green' not in closed['times']
assert x['time_to_merge']['median_seconds'] == x['time_to_merge']['p85_seconds'] == 60
assert {q['task']: q['why'] for q in x['queue']} == {'jg-next': 'dependency: jg-prior', 'jg-held': 'hold: Wait for You',
    'jg-ready': 'unknown: dispatch admission not recorded'}
assert next(b for b in x['bottlenecks'] if b['cause'] == 'unknown')['unknown_items'] == 1
assert any(n.get('line') == 7 for n in x['limitations']), 'malformed durable record disclosed'
assert sum(d['known'] + d['unknown'] for d in x['trend_7d']) == len(x['executed_7d'])
grand = tmp / 'grand'
(grand / 'state').mkdir(parents=True, exist_ok=True)
(grand / 'data/squad_leads.md').write_text(f'- main - Parent (home: {main}; scope: fleet; projects: app)\n')
with open(child / 'data/squad_leads.md', 'a') as f:
    f.write(f'- grand - Worker (home: {grand}; scope: app; projects: app)\n')
(child / 'state/grand.status').write_text('done [at=70] [key=merged-gtask]: merged\n')
with open(child / 'state/fleet-ledger.jsonl', 'a') as f:
    f.write(json.dumps(dict(v=1, task='reused', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='reused', ts=70, event='task.merged')) + '\n')
    f.write(json.dumps(dict(v=1, task='reused', ts=90, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullstage', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullstage', ts=20, event='task.status', state=None, key='k', text='t')) + '\n')
    f.write(json.dumps(dict(v=1, task='restale', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='restale', ts=20, event='task.status', state='blocked', key='k', text='stale')) + '\n')
    f.write(json.dumps(dict(v=1, task='restale', ts=90, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullwait', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='nullwait', ts=20, event='task.status', state='blocked', key='k', text=None)) + '\n')
    f.write(json.dumps(dict(v=1, task='relive', ts=10, event='task.dispatched')) + '\n')
    f.write(json.dumps(dict(v=1, task='relive', ts=90, event='task.dispatched')) + '\n')
(child / 'state/relive.meta').write_text('kind=ship\n')
(child / 'state/relive.status').write_text('working [at=20]: building\nblocked [at=25] [key=stale-key]: waiting\n')
y = json.loads(run())
assert y['homes'] == ['child', 'grand', 'main'], 'nested home discovered'
bytask = {(l['home'], l['task']): l for l in y['lanes']}
assert bytask[('grand', 'gtask')]['times']['merged'] == 70, 'nested return-channel merge found'
assert bytask[('grand', 'gtask')]['durations']['time_to_merge'] is None, 'no guessed pickup'
assert 'gtask' in {l['task'] for l in y['executed_24h']}
assert bytask[('child', 'reused')]['times']['merged'] is None, 'reused id keeps no merge'
assert 'reused' not in {l['task'] for l in y['executed_24h']}
assert bytask[('child', 'nullstage')]['stage'] == 'unknown', 'null ledger state stays unknown'
restale = bytask[('child', 'restale')]
assert restale['stage'] == 'unknown' and restale['open_waits'] == [], 'reuse drops pre-dispatch status'
assert restale['seconds_in_stage'] is None and restale['times']['working'] is None
assert restale['reason'] == 'unknown: no status reason'
assert 'restale' not in {l['task'] for l in y['executed_24h']}
assert bytask[('child', 'nullwait')]['open_waits'][0]['reason'] == '', 'null wait text coerced'
relive = bytask[('child', 'relive')]
assert relive['open'] and relive['timestamp_basis'] == 'emitted'
assert relive['stage'] == 'unknown' and relive['open_waits'] == [], 'live reuse drops pre-dispatch status'
assert relive['seconds_in_stage'] is None and relive['times']['working'] is None
assert relive['reason'] == 'unknown: no status reason'
(main / 'config').mkdir(exist_ok=True)
(main / 'config/jg-flow-check.sh').write_text("clock = 30 if L['verb'] == 'needs-decision' else 50\n")
(main / 'config/lane-caps').write_text('main 0\n')
(main / 'data/captain-shared.md').write_text('# Captain notes\n- project-x: soft pause pending budget review\n')
tx(child, 'add', 'jg-hold-lane', 'Captain held task')
tx(child, 'start', 'jg-hold-lane')
tx(child, 'hold', 'jg-hold-lane', '--reason', 'wait for captain', '--kind', 'captain')
(child / 'state/jg-hold-lane.meta').write_text('kind=ship\nproject=project-y\n')
(child / 'state/jg-hold-lane.status').write_text('working [at=10]: started\n')
(child / 'state/project-paused.meta').write_text('kind=ship\nproject=project-x\n')
(child / 'state/project-paused.status').write_text('paused [at=10]: soft pause\n')
for task, reason in [('memory', 'jg-mem-gate: waiting (free 1 GB)'), ('credential', 'waiting for login'),
                     ('ci', 'waiting for CI queue'), ('merge', 'waiting for merge'),
                     ('mention', 'memory gate code fixed; waiting for new instructions')]:
    (child / 'state' / (task + '.meta')).write_text('kind=ship\n')
    (child / 'state' / (task + '.status')).write_text(f'blocked [at=10] [key=wait]: {reason}\n')
(child / 'state/mixed.meta').write_text('kind=ship\n')
(child / 'state/mixed.status').write_text('blocked [at=10] [key=a]: jg-mem-gate: waiting (free 1 GB)\n'
    'blocked [at=30] [key=a2]: jg-mem-gate: waiting (free 1 GB)\n'
    'blocked [key=a0]: jg-mem-gate: waiting (free 1 GB)\n'
    'needs-decision [at=20] [key=b]: waiting for merge\n')
(child / 'state/partknown.meta').write_text('kind=ship\n')
(child / 'state/partknown.status').write_text('blocked [at=10] [key=a]: jg-mem-gate: waiting (free 1 GB)\n'
    'blocked [key=b]: jg-mem-gate: waiting (free 1 GB)\n')
(child / 'state/smallmerge.meta').write_text('kind=ship\n')
(child / 'state/smallmerge.status').write_text('blocked [at=90] [key=wait]: waiting for merge\n')
z = json.loads(run())
new = {l['task']: l for l in z['lanes'] if l['open']}
assert new['jg-hold-lane']['kind'] == 'ship' and new['jg-hold-lane']['hold_kind'] == 'captain', new['jg-hold-lane']
assert new['jg-hold-lane']['open_waits'][-1]['cause'] == 'captain'
assert new['jg-hold-lane']['open_waits'][-1]['reason'] == 'wait for captain'
assert new['project-paused']['project'] == 'project-x'
assert new['project-paused']['parked_reason'] == 'project-x: soft pause pending budget review'
for task, expected in [('memory', 'memory_gate'), ('credential', 'credential_external'),
                       ('ci', 'ci_queue'), ('merge', 'review_merge'), ('mention', 'unknown')]:
    assert new[task]['open_waits'][0]['cause'] == expected
    assert new[task]['stage_clock']['seconds'] == 50 and new[task]['stage_clock']['overdue'] is True
    assert new[task]['ci'] is None, 'no reported CI is not a zero or green'
mem_bucket = next(b for b in z['bottlenecks'] if b['cause'] == 'memory_gate')
merge_bucket = next(b for b in z['bottlenecks'] if b['cause'] == 'review_merge')
mem_item = next(i for i in mem_bucket['items'] if i['task'] == 'mixed')
merge_item = next(i for i in merge_bucket['items'] if i['task'] == 'mixed')
assert mem_item['seconds'] is None, 'unstamped same-cause wait keeps full total unknown'
assert mem_item['known_seconds'] == 90 and len(mem_item['waits']) == 3, 'within-cause maximum, not sum'
assert mem_item['unknown_waits'] == 1
assert merge_item['seconds'] == 80 and merge_item['known_seconds'] == 80
assert mem_bucket['known_lower_bound_lane_hours'] == (90 + 90 + 90) / 3600
assert mem_bucket['unknown_items'] == 2 and mem_bucket['unknown_waits'] == 2
part = next(i for i in mem_bucket['items'] if i['task'] == 'partknown')
assert part['seconds'] is None and part['known_seconds'] == 90 and part['unknown_waits'] == 1
assert [b['cause'] for b in z['bottlenecks']].index('memory_gate') < [b['cause'] for b in z['bottlenecks']].index('review_merge'), 'known lower bound ranks first'
assert mem_item['overlap'] is True and merge_item['overlap'] is True
assert mem_bucket['additive'] is False and merge_bucket['additive'] is False
assert next(i for i in mem_bucket['items'] if i['task'] == 'memory')['overlap'] is False
assert 'mixed' not in {i['task'] for i in next(b for b in z['bottlenecks'] if b['cause'] == 'unknown')['items']}
assert {q['task']: q['why'] for q in z['queue']}['jg-ready'] == 'lane cap: 0 recorded active lanes, cap 0'
assert new['unknown']['stage_clock']['overdue'] is None, 'unstamped stage never guessed overdue'
scenarios = {
    'keyclose': [('blocked', 10, 'a', 'waiting for login'),
                 ('resolved', 20, None, '[key=a] login restored')],
    'noteopens': [('blocked', 10, None, '[key=a] waiting for login'),
                  ('blocked', 20, None, '[key=b] waiting for merge'),
                  ('captain-held', 30, 'a', 'held')],
    'reopened': [('blocked', 10, 'a', 'waiting for login'),
                 ('blocked', 20, None, '[key=a] waiting for merge'),
                 ('blocked', 30, 'b', 'waiting for merge')],
    'precedence': [('blocked', 10, 'a', '[key=b] waiting for login'),
                   ('resolved', 20, 'b', 'answered')],
    'pause': [('paused', 10, None, 'waiting for memory gate')],
    'repause': [('paused', 10, None, 'waiting for login'),
                ('paused', 20, None, 'waiting for memory gate')],
    'resumed': [('paused', 10, None, 'waiting for memory gate'),
                ('working', 20, None, 'building')],
    'decisionpause': [('blocked', 10, 'a', 'waiting for merge'),
                      ('paused', 20, None, 'waiting for memory gate')],
    'unknownpause': [('paused', None, None, 'waiting for memory gate')],
}
for representation in ('emitted', 'captured'):
    for task, entries in scenarios.items():
        task = representation + '-' + task
        (child / 'state' / (task + '.meta')).write_text('kind=ship\n')
        if representation == 'emitted':
            lines = [state + (f' [at={ts}]' if ts is not None else '') +
                     (f' [key={key}]' if key else '') + ': ' + text + '\n'
                     for state, ts, key, text in entries]
            (child / 'state' / (task + '.status')).write_text(''.join(lines))
        else:
            if any(ts is None for _, ts, _, _ in entries):
                continue
            with open(child / 'state/fleet-ledger.jsonl', 'a') as f:
                for state, ts, key, text in entries:
                    stored_key = key or (text.split(']', 1)[0][5:] if text.startswith('[key=') else None)
                    f.write(json.dumps(dict(v=1, task=task, ts=ts, event='task.status',
                                           state=state, key=stored_key, text=text)) + '\n')
result = json.loads(run())
rows = {l['task']: l for l in result['lanes']}
for representation in ('emitted', 'captured'):
    def lane(task):
        return rows[representation + '-' + task]
    assert lane('keyclose')['open_waits'] == [], 'note-head resolution closes the stated key'
    waits = lane('noteopens')['open_waits']
    assert [(w['key'], w['reason'], w['cause'], w['seconds']) for w in waits] == [
        ('b', 'waiting for merge', 'review_merge', 80)], 'distinct note-head keys and normalized reasons'
    waits = lane('reopened')['open_waits']
    assert [(w['key'], w['cause'], w['seconds']) for w in waits] == [
        ('a', 'review_merge', 80), ('b', 'review_merge', 70)], 'latest opener replaces cause and age'
    bucket = next(b for b in result['bottlenecks'] if b['cause'] == 'review_merge')
    item = next(i for i in bucket['items'] if i['task'] == representation + '-reopened')
    assert item['seconds'] == item['known_seconds'] == 80, 'distinct same-cause keys retain maximum'
    waits = lane('precedence')['open_waits']
    assert len(waits) == 1 and waits[0]['key'] == 'a' and waits[0]['reason'] == '[key=b] waiting for login'
    for task, seconds in [('pause', 90), ('repause', 80)]:
        waits = lane(task)['open_waits']
        assert len(waits) == 1 and waits[0]['key'] is None
        assert waits[0]['cause'] == 'memory_gate' and waits[0]['seconds'] == seconds
        bucket = next(b for b in result['bottlenecks'] if b['cause'] == 'memory_gate')
        item = next(i for i in bucket['items'] if i['task'] == representation + '-' + task)
        assert item['seconds'] == seconds and item['unknown_waits'] == 0
    assert lane('resumed')['open_waits'] == [], 'working ends the current declared pause'
    waits = lane('decisionpause')['open_waits']
    assert [(w['key'], w['cause'], w['seconds']) for w in waits] == [
        ('a', 'review_merge', 90), (None, 'memory_gate', 80)], 'pause does not overwrite keyed decision'
wait = rows['emitted-unknownpause']['open_waits'][0]
assert wait['seconds'] is None and wait['since'] is None, 'unstamped pause stays unknown'
for i, t in (('jg-archived', 'Completed prerequisite'), ('jg-archive-ready', 'Archived prerequisite'), ('jg-multiple', 'Multiple dependencies')):
    tx(main, 'add', i, t)
tx(main, 'done', 'jg-archived')
tx(main, 'block', 'jg-archive-ready', '--by', 'jg-archived')
tx(main, 'block', 'jg-multiple', '--by', 'jg-archived')
tx(main, 'block', 'jg-multiple', '--by', 'jg-prior')
with open(main / 'data/squad_leads.md', 'a') as f:
    f.write(f'- macbook - Remote (host: macbook; root: /remote/repo; home: {grand}; scope: app; projects: app)\n')
before = files()
coverage = json.loads(run())
assert files() == before, 'authoritative backlog reads never mutate homes or archive'
assert coverage['homes'] == ['child', 'grand', 'macbook', 'main'], 'remote registration remains visible'
assert not any(l['home'] == 'macbook' for l in coverage['lanes']), 'remote path is never collected locally'
assert not any(q['home'] == 'macbook' for q in coverage['queue'])
remote = next(n for n in coverage['limitations'] if n['source'] == 'macbook')
assert remote['host'] == 'macbook' and remote['home'] == str(grand)
assert 'unknown' in remote['reason'] and 'remote' in remote['reason']
reasons = {q['task']: q['why'] for q in coverage['queue'] if q['home'] == 'main'}
assert reasons['jg-archive-ready'] == 'lane cap: 0 recorded active lanes, cap 0'
assert reasons['jg-multiple'] == 'dependency: jg-prior', 'completed edges excluded, unresolved edge retained'
assert reasons['jg-held'] == 'hold: Wait for You', 'consumer decodes hold reasons'
(main / 'config/jg-flow-check.sh').write_text('unrecognized clock policy\n')
assert next(l for l in json.loads(run())['lanes'] if l['task'] == 'memory')['stage_clock']['seconds'] is None
(main / 'config/jg-mem-gate.sh').write_text('min=${JG_MEM_MIN_GB:-12}\n'
    '[ "$psi" -lt 40 ] && [ "$running" -lt "${JG_EMU_MAX:-3}" ] && [ "$builds" -lt "${JG_GRADLE_MAX:-2}" ]\n'
    'echo "${JG_MEM_JOB_GB:-10}G"\n')
clean_env = dict(os.environ, JG_HOME=str(main))
for key in ('JG_MAC_HOST', 'XDG_DATA_HOME', 'JG_MEM_MIN_GB', 'JG_EMU_MAX', 'JG_GRADLE_MAX', 'JG_MEM_JOB_GB'):
    clean_env.pop(key, None)
before = files()
c = json.loads(subprocess.check_output(['bash', script, '--json', '--capacity'], env=clean_env))['capacity']
assert files() == before, 'native read-only census never writes the isolated home'
assert c['limits']['JG_EMU_MAX'] == 3 and c['limits']['JG_GRADLE_MAX'] == 2
assert c['gate_source'] == str(main / 'config/jg-mem-gate.sh')
# Installed gate (host-memory/wiring.sh): config/jg-mem-gate.sh is a shim, so the policy is read from the copy.
installed = tmp / 'home/.local/share/jg-host-memory/jg-mem-gate.sh'
installed.parent.mkdir(parents=True)
installed.write_text('min=${JG_MEM_MIN_GB:-12}\n[ "$psi" -lt 40 ] && [ "$running" -lt "${JG_EMU_MAX:-2}" ]\n'
    '[ "$builds" -lt "${JG_GRADLE_MAX:-1}" ] && echo "${JG_MEM_JOB_GB:-10}G"\n')
shim = (main / 'config/jg-mem-gate.sh').read_text()
(main / 'config/jg-mem-gate.sh').write_text('#!/usr/bin/env bash\nexec "${XDG_DATA_HOME:-$HOME/.local/share}/jg-host-memory/jg-mem-gate.sh" "$@"\n')
s = json.loads(subprocess.check_output(['bash', script, '--json', '--capacity'], env=clean_env))['capacity']
assert s['gate_source'] == str(installed), s['gate_source']
assert s['limits'] == dict(c['limits'], JG_EMU_MAX=2, JG_GRADLE_MAX=1), s['limits']
installed.unlink(); (main / 'config/jg-mem-gate.sh').write_text(shim)
assert c['mac']['reachable'] is None and c['mac']['available_bytes'] is None and c['mac']['simulators'] is None
if Path('/proc/meminfo').exists():
    assert c['memory_bytes']['MemTotal'] > 0 and 0 <= c['memory_bytes']['MemAvailable'] <= c['memory_bytes']['MemTotal']
for kind, limit in [('emulator', 3), ('gradle_gate_match', 2)]:
    if c['gate_counts'][kind] is not None:
        assert c['gate_counts'][kind] == sum(j['kind'] == kind for j in c['jobs'])
        assert c['slots_under_caps'][kind] == max(limit - c['gate_counts'][kind], 0)
assert all(j['rss_bytes'] is None or j['rss_bytes'] % 1024 == 0 for j in c['jobs'])
if c['tmp']['top_folders_complete'] is False:
    assert all(f['bytes'] is None and f['known_bytes'] >= 0 for f in c['tmp']['top_folders'])
# Real SSH stalls on a task-owned loopback banner exchange. A private port route
# extends SSH's own timeout so the flow CLI's six-second outer bound must win.
ssh = shutil.which('ssh')
assert ssh, 'native SSH client required for timeout integration'
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(30)
    banner = []
    def stalled_banner():
        with listener.accept()[0] as connection:
            connection.settimeout(30)
            while data := connection.recv(4096):
                banner.append(data)
    thread = threading.Thread(target=stalled_banner, daemon=True)
    thread.start()
    route = tmp / 'ssh-route'
    route.mkdir()
    config = route / 'config'
    config.write_text('Host *\n    UpdateHostKeys yes\n')
    effective = route / 'effective-options'
    native = shlex.quote(ssh) + ' -F ' + shlex.quote(str(config)) + \
        f' -p {listener.getsockname()[1]} -o ConnectTimeout=30'
    control = dict(line.split(None, 1) for line in subprocess.check_output(
        [ssh, '-G', '-F', str(config), 'nobody@127.0.0.1'], text=True).splitlines())
    assert control['updatehostkeys'] == 'true', 'private configuration enables host-key updates'
    wrapper = route / 'ssh'
    wrapper.write_text('#!/bin/sh\n' + native + ' -G "$@" > ' + shlex.quote(str(effective)) +
        ' || exit $?\nexec ' + native + ' "$@"\n')
    wrapper.chmod(0o700)
    before = files()
    stalled = json.loads(subprocess.check_output(['bash', script, '--json', '--capacity'],
        env=dict(clean_env, JG_MAC_HOST='nobody@127.0.0.1', PATH=str(route) + os.pathsep + os.environ['PATH']),
        timeout=45))
    thread.join(2)
    options = dict(line.split(None, 1) for line in effective.read_text().splitlines())
    assert options['updatehostkeys'] == 'false', 'flow CLI disables host-key updates in native SSH'
    assert banner and banner[0].startswith(b'SSH-'), 'actual SSH client reached private native transport'
    assert not thread.is_alive(), 'timed-out SSH connection closed'
    assert files() == before, 'timeout path also leaves fleet records untouched'
    assert any(n['source'] == 'Mac SSH probe' and 'timed out after 6 seconds' in n['reason']
               for n in stalled['limitations']), 'outer Mac deadline enforced with native SSH'
    mac = stalled['capacity']['mac']
    assert mac['reachable'] is None and mac['available_bytes'] is None and mac['simulators'] is None
bad = subprocess.run(['bash', script, '--json', '--now', 'bad'], capture_output=True)
assert bad.returncode == 2
print('PASS: real flow CLI, two homes, queue, keyed waits, retained lifecycle, unknowns, read-only determinism')
PY

# The per-skill reader: run the real CLI over isolated durable records and read the JSON the skill statistics command consumes.
# The per-model reader reads tickets and is proved on real Beads stores by tests/jg-model-stats.test.sh.
mkdir -p "$TMP/stats"
HOME="$TMP/stats/home" XDG_CONFIG_HOME="$TMP/xdg" TMPDIR="$TMP/tmp" python3 - \
  "$JG_BIN/jg-skill-stats.sh" "$TMP/stats" <<'PY'
import json, os, subprocess, sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

skill, tmp = sys.argv[1], Path(sys.argv[2])
now, day = 1700000000, 86400

def run(script, home):
    return subprocess.check_output(['bash', script, '--json', '--now', str(now)],
        env=dict(os.environ, JG_HOME=str(home), JG_DATA_OVERRIDE=''))
def iso(e):
    return datetime.fromtimestamp(e, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
def onday(off):
    return (datetime.fromtimestamp(now, timezone.utc) - timedelta(days=off)).strftime('%Y-%m-%d')
def stamps(home):
    return {str(p): p.stat().st_mtime_ns for p in home.rglob('*') if p.is_file()}

# Skills: reads, windows, ranking, zero-read discovery, remote disclosure.
s, sb = tmp / 's', tmp / 'sb'
for h in (s, sb):
    (h / 'data/metrics').mkdir(parents=True, exist_ok=True)
    (h / 'state').mkdir(parents=True, exist_ok=True)
(s / 'data/squad_leads.md').write_text(f'- byokit - BYOKit (home: {sb}; scope: toolkit; projects: byokit)\n'
    '- distant - Remote (host: box; root: /srv; home: /srv/home; scope: x; projects: y)\n')
for rel in ('skills', '.agents/skills'):
    for name in ('widget', 'gadget'):
        p = s / rel / name
        p.mkdir(parents=True, exist_ok=True)
        (p / 'SKILL.md').write_text('x')
(sp := sb / '.agents/skills/spanner').mkdir(parents=True)
(sp / 'SKILL.md').write_text('x')
(s / 'data/metrics/skills.tsv').write_text('day\thome\tskill\treads\n' + ''.join(
    f'{onday(0)}\tmain\tused-heavy\t5\n{onday(1)}\tmain\tused-heavy\t3\n{onday(0)}\tmain\tshared\t2\n{onday(0)}\tbyokit\tshared\t4\n'
    f'{onday(20)}\tmain\told\t10\n{onday(10)}\tmain\tgadget\t100\n{onday(7)}\tmain\twidget\t9\n'))
before = stamps(s)
z = json.loads(run(skill, s))
assert run(skill, s) == run(skill, s) and stamps(s) == before, 'skill reader deterministic and read-only'
assert z['schema'] == 'jg-skill-stats.v1' and z['windows'] == [7, 30] and (z['coverage']['rows'], z['coverage']['skills'], z['coverage']['homes']) == (7, 5, 2), 'skill schema, windows, coverage'
def sk(name):
    return next(r for r in z['skills'] if r['skill'] == name)
assert [r['skill'] for r in z['skills']][:2] == ['used-heavy', 'shared'] and [r['skill'] for r in z['skills']][2:] == ['gadget', 'old', 'widget'], 'skill ranking by reads'
assert sk('used-heavy')['w7'] == {'reads': 8, 'homes': 1} and sk('shared')['w7'] == {'reads': 6, 'homes': 2}, 'window sums and cross-home reads'
assert sk('gadget')['w7']['reads'] == 0 and sk('gadget')['w30']['reads'] == 100 and sk('widget')['w30']['reads'] == 9, 'a skill read only outside 7 days'
assert z['zero_read_w7'] == [] and z['zero_read_w30'] == [], 'a registered remote home suppresses zero-read claims'
assert [r['skill'] for r in z['by_home']['main']][:3] == ['used-heavy', 'shared', 'gadget'] and [r['skill'] for r in z['by_home']['byokit']] == ['shared'], 'per-home skill breakdown'
assert any('distant' in n for n in z['limitations']), 'a remote home is disclosed as unreadable'
def mk_skill_home(name, skills=(), tsv=None):
    h = tmp / name
    (h / 'data/metrics').mkdir(parents=True)
    for s in skills:
        (h / 'skills' / s).mkdir(parents=True)
        (h / 'skills' / s / 'SKILL.md').write_text('x')
    if tsv is not None:
        (h / 'data/metrics/skills.tsv').write_text('day\thome\tskill\treads\n' + tsv)
    return h
zempty = json.loads(run(skill, mk_skill_home('empty-skill')))
assert zempty['skills'] == [] and zempty['by_home'] == {} and zempty['limitations'], 'absent skill record is empty, not fatal'
znr = json.loads(run(skill, mk_skill_home('no-reads', ['widget'])))
assert znr['zero_read_w7'] == [] and znr['zero_read_w30'] == [], 'known skills are not zero-read without any read records'
zs = json.loads(run(skill, mk_skill_home('stale-skill', ['widget'], f'{onday(40)}\tmain\twidget\t1\n')))
assert zs['zero_read_w7'] == [] and zs['zero_read_w30'] == [], 'a collector whose coverage ends before the window claims no zero reads'
zz = json.loads(run(skill, mk_skill_home('zero-count', ['beta'],
    f'{onday(6)}\tmain\talpha\t1\n{onday(0)}\tmain\talpha\t3\n{onday(0)}\tmain\tbeta\t0\n')))
assert zz['zero_read_w7'] == ['beta'] and zz['zero_read_w30'] == [], 'a covered window lists known skills with no reads; a window the coverage does not span lists none'
assert next(r for r in zz['skills'] if r['skill'] == 'beta')['w7'] == {'reads': 0, 'homes': 0}, 'a zero-count row does not count as reading a home'

print('PASS: skill reader over isolated durable records')
PY
