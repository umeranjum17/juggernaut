#!/usr/bin/env bash
# Exercise the decisions contract on the isolated inventory fixture.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/e6holds2.XXXXXX")
trap "rm -rf -- '$T'" EXIT
python3 -I - "$ROOT" "$T" <<'PY'
import csv, datetime, importlib.util, json, os, re, shutil, sqlite3, subprocess, sys, time
from pathlib import Path
root, tmp = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('parse_lab', root/'core/agent-cli/inventory/parse.py')
parse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parse)
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6holds2']
fragment = json.loads((root/'core/agent-cli/contract/e6holds2.json').read_text())
entries = fragment['entries']
assert fragment['owner'] == 'e6holds2' and len(rows) == len(entries) == 33
bykey = {(e['script'].removeprefix('bin/'), e['operation']): e for e in entries}
assert len(bykey) == len(rows)
for r in rows:
    e = bykey[(r['script'], r['operation'])]
    assert e['form'] == r['form'] and e['path'] == r['path'].split() and e['method'] == r['method'], r
    assert e['aliases'] == ([] if r['aliases'] == '-' else r['aliases'].split(',')), r
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext, e['path']
lab = parse.Lab(str(root), str(tmp/'lab'))
lab.env['JG_BOARD_GATE_NOW'] = '1795000000'
lab.env['JG_MIGRATION_LIVE_BIN'] = '/bin/true'
lab.env['JG_BUS_CMD'] = '/bin/true'
lab.env['JG_MIGRATION_CARD_NOW'] = '1795000000'
config = Path(lab.snap)/'home/config/migration-card'
config.write_text('branch=release/v13\ntarget=100\nboard=' + lab.home + '/board.json\n')
def run(argv):
    lab.reset()
    before = lab.digest()
    out, err = tmp/'stdout', tmp/'stderr'
    start = int(time.time())
    with out.open('w') as stdout, err.open('w') as stderr:
        proc = subprocess.Popen([str(Path(lab.tree)/argv[0])] + argv[1:], stdin=subprocess.DEVNULL,
                                stdout=stdout, stderr=stderr, env=lab.env, cwd=lab.run_dir,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=parse.TIMEOUT)
        except subprocess.TimeoutExpired:
            rc = 'timeout'
        parse.kill_session(proc.pid)
        if rc == 'timeout':
            proc.wait()
    end = int(time.time())
    stdout = out.read_text(errors='replace')
    stderr = err.read_text(errors='replace')
    text = stderr + stdout
    calls = Path(lab.calls).read_text().strip()
    return rc, (text.strip().splitlines() or [''])[0][:110], text, before != lab.digest(), calls, stdout, stderr, (start, end)
def snapshot(window=None):
    home = Path(lab.home)
    result = {}
    for p in home.rglob('*'):
        if not p.is_file() or p.name.endswith('.lock'):
            continue
        key = str(p.relative_to(home))
        if p.name == 'fleet.db':
            db = sqlite3.connect('file:' + str(p) + '?mode=ro', uri=True)
            db.execute('begin')
            tables = [r[0] for r in db.execute("select name from sqlite_master where type='table' order by name")]
            content = {}
            for table in tables:
                cols = [r[1] for r in db.execute('pragma table_info(' + table + ')')]
                rows = sorted((tuple(row) for row in db.execute('select * from ' + table)), key=repr)
                content[table] = (cols, rows)
            db.rollback()
            db.close()
            result[key] = content
        elif not p.name.endswith(('-wal', '-shm')):
            data = p.read_bytes()
            if key in ('state/.branch-outcomes-tail.jsonl', 'state/branch-outcomes.jsonl') and window:
                records = [json.loads(line) for line in data.splitlines()]
                for rec in records:
                    if window[0] <= rec['epoch'] <= window[1]:
                        rec['epoch'] = '<call time>'
                data = json.dumps(records, sort_keys=True).encode()
            result[key] = data
    return result
def canonical_db(db, baseline, window):
    # Normalize only newly created gate identities and their measured clock fields.
    cols, tickets = db['ticket']
    id_col = cols.index('id')
    old_ids = {row[id_col] for row in baseline['ticket'][1]}
    new = [row for row in tickets if row[id_col] not in old_ids]
    new.sort(key=lambda row: repr(tuple(v for i, v in enumerate(row) if cols[i] not in
                                      ('id', 'created_at', 'updated_at', 'metadata'))))
    ids = {row[id_col]: '<new-ticket-%d>' % i for i, row in enumerate(new)}
    for row in new:
        created = datetime.datetime.fromisoformat(row[cols.index('created_at')].replace('Z', '+00:00'))
        assert window[0] <= created.timestamp() <= window[1], (created, window)
        metadata = json.loads(row[cols.index('metadata')] or '{}')
        if 'expires_at' in metadata:
            expiry = datetime.datetime.fromisoformat(metadata['expires_at'].replace('Z', '+00:00'))
            assert expiry - created == datetime.timedelta(days=7), (created, expiry)
    event_cols, events = baseline['ticket_change']
    seq_col = event_cols.index('seq')
    last_seq = max((row[seq_col] for row in events), default=0)
    def idrefs(v):
        if not isinstance(v, str):
            return v
        for old, new_id in ids.items():
            v = v.replace(old, new_id)
        return v
    def metadata(v, gate=False):
        data = json.loads(v or '{}')
        if gate and 'expires_at' in data:
            data['expires_at'] = '<gate expiry>'
        if 'wait_at' in data:
            stamp = datetime.datetime.fromisoformat(data['wait_at'].replace('Z', '+00:00')).timestamp()
            if window[0] <= stamp <= window[1]:
                data['wait_at'] = '<wait time>'
        return json.dumps(data, sort_keys=True)
    result = {}
    for table, (names, records) in db.items():
        normalized = []
        for row in records:
            fields = dict(zip(names, row))
            is_new_ticket = table == 'ticket' and fields['id'] in ids
            is_new_event = table == 'ticket_change' and fields['seq'] > last_seq
            if table == 'ticket':
                fields['metadata'] = metadata(fields['metadata'], is_new_ticket)
            if is_new_ticket:
                fields['created_at'] = fields['updated_at'] = '<gate time>'
            if is_new_event:
                assert window[0] <= fields['at'] <= window[1], (fields['at'], window)
                fields['at'] = '<event time>'
                fields['source'] = re.sub(r'(bd-(?:gate-create|gate-block|update):)\d+', r'\1<clock>', fields['source'])
                if fields['row']:
                    data = json.loads(fields['row'])
                    if fields['id'] in ids:
                        data['created_at'] = data['updated_at'] = '<gate time>'
                    data['metadata'] = metadata(data['metadata'], fields['id'] in ids)
                    fields['row'] = json.dumps(data, sort_keys=True)
            normalized.append(tuple(idrefs(fields[col]) for col in names))
        result[table] = (names, sorted(normalized, key=repr))
    return result

for r in rows:
    e = bykey[(r['script'], r['operation'])]
    groups = parse.optional_groups(r['form'])
    for group in [None] + groups + (['optional-text'] if r['script'] == 'jg-migration-card.sh' and r['operation'] == 'milestone' else []):
        argv, why = parse.render(lab, r['form'], script=r['script'], keep=None if group == 'optional-text' else group)
        if group == 'optional-text' and argv is not None:
            argv.append('fixture message')
        assert argv is not None, (r, group, why)
        lab.reset()
        baseline = snapshot()
        direct = run(argv)
        direct_state = snapshot(direct[7])
        if os.environ.get('E6_CAPTURE_DIR'):
            shutil.copy2(Path(lab.home)/'state/item-store/fleet.db', Path(os.environ['E6_CAPTURE_DIR'])/'direct.db')
        assert direct[0] != 'timeout' and not (direct[0] != 0 and parse.PARSE_ERROR.search(direct[2])), (r['form'], group, direct[:3])
        if r['method'] == 'GET':
            assert not direct[3] and not direct[4], (r['form'], direct)
        # The scripts here put their operation words before the arguments.
        n = len(r['operation'].split())
        assert argv[1:1+n] == r['operation'].split(), argv
        route = ['bin/jg'] + e['path'] + argv[1+n:]
        routed = run(route)
        routed_state = snapshot(routed[7])
        if os.environ.get('E6_CAPTURE_DIR'):
            shutil.copy2(Path(lab.home)/'state/item-store/fleet.db', Path(os.environ['E6_CAPTURE_DIR'])/'routed.db')
        # A reported dispatcher gap is owned by the shared dispatcher repair.
        if r['script'] == 'jg-migration-card.sh' and r['operation'] == 'milestone' and group == 'optional-text' and routed[0] == 2 and 'unexpected argument' in routed[2]:
            assert b'fixture message' in direct_state['state/branch-outcomes.jsonl'], direct_state
            print('dispatcher gap:', r['form'], group, routed[1])
            continue
        assert routed[0] == direct[0], (r['form'], group, direct[:3], routed[:3])
        # jg wraps successful script stdout as JSON or as data.stdout, and forwards stderr.
        if direct[0] == 0:
            try:
                expected = json.loads(direct[5])
            except ValueError:
                expected = {'stdout': direct[5]}
            envelope = json.loads(routed[5])
            assert envelope['ok'] and envelope['data'] == expected, (r['form'], group, expected, envelope)
        assert routed[6] == direct[6], (r['form'], group, direct[6], routed[6])
        db_key = 'state/item-store/fleet.db'
        if db_key in baseline and db_key in direct_state and db_key in routed_state:
            direct_state[db_key] = canonical_db(direct_state[db_key], baseline[db_key], direct[7])
            routed_state[db_key] = canonical_db(routed_state[db_key], baseline[db_key], routed[7])
        if direct_state != routed_state:
            key = next(k for k in sorted(direct_state.keys() | routed_state.keys()) if direct_state.get(k) != routed_state.get(k))
            if key.endswith('fleet.db') and key in direct_state and key in routed_state:
                left, right = direct_state[key], routed_state[key]
                table = next(t for t in sorted(left.keys() | right.keys()) if left.get(t) != right.get(t))
                cols, a = left[table]; _, b = right[table]
                for idx in range(max(len(a), len(b))):
                    if idx >= len(a) or idx >= len(b):
                        raise AssertionError((r['form'], table, idx, 'row missing', a[idx:idx+1], b[idx:idx+1]))
                    for col, x, y in zip(cols, a[idx], b[idx]):
                        if x != y:
                            raise AssertionError((r['form'], table, idx, col, x, y))
            raise AssertionError((r['form'], key, direct_state.get(key), routed_state.get(key)))
        if r['method'] == 'GET':
            assert not routed[3] and not routed[4], (r['form'], routed)
print('ok - decisions forms, routes, reads and isolated script calls')
PY
