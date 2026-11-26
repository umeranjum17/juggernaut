#!/usr/bin/env bash
# Exercise decisions commands through the public CLI and their existing scripts on isolated fixtures.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
[ -f "$ROOT/core/agent-cli/contract/e6holds1.json" ] || { echo 'missing decisions contract' >&2; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/e6holds1.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
python3 - "$ROOT" "$T" <<'PY'
import csv, importlib.util, json, os, subprocess, sys
root, temp = sys.argv[1:]
spec = importlib.util.spec_from_file_location('parse', root + '/core/agent-cli/inventory/parse.py')
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
with open(root + '/core/agent-cli/operations.tsv') as f:
    rows = [r for r in csv.DictReader(f, delimiter='\t') if r['owner'] == 'e6holds1']
with open(root + '/core/agent-cli/contract/e6holds1.json') as f: fragment = json.load(f)
assert len(rows) == len(fragment['entries']) == 15
entries = {(e['script'][4:], e['operation']): e for e in fragment['entries']}
assert len(entries) == 15
for row in rows:
    e = entries[row['script'], row['operation']]
    assert (e['form'], ' '.join(e['path']), e['method'], e['aliases']) == (row['form'], row['path'], row['method'], [])
subprocess.run(['bash', root + '/core/agent-cli/dispatch.sh', 'check'], check=True)
helptext = subprocess.check_output([root + '/bin/jg', 'help'], text=True)
for e in entries.values(): assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext
lab = p.Lab(root, temp + '/lab')
# Freeze only the clock formats used by these writers so paired runs have identical records.
clock = lab.stub + '/date'
with open(clock, 'w') as f:
    f.write('''#!/bin/sh
case "$*" in
  +%s) echo 1795000000 ;;
  '-u +%Y%m%dT%H%M%SZ') echo 20261118T100000Z ;;
  '-u +%Y-%m-%dT%H:%MZ') echo 2026-11-18T10:00Z ;;
  *) exec /usr/bin/date "$@" ;;
esac
''')
os.chmod(clock, 0o755)
# The read has a real route row to return, not only an absent-file case.
os.makedirs(lab.home + '/data/answer-route', exist_ok=True)
with open(lab.home + '/data/answer-route/jg-t1.tsv', 'w') as f: f.write('1\tyes\tno-op\tfixture\n')
import shutil
os.makedirs(lab.snap + '/home/data/answer-route', exist_ok=True)
shutil.copy2(lab.home + '/data/answer-route/jg-t1.tsv', lab.snap + '/home/data/answer-route/jg-t1.tsv')
values = {'pass|fail': 'pass', 'card-key': 'jg-t1', 'lead': 'missing-worker',
          'record-id': 'owd-missing', 'at': '1', 'epoch': '1', 'feed.json': lab.values['file'],
          'board.json': lab.values['file'], 'file': lab.run_dir + '/out.json'}
def run(argv):
    lab.reset()
    before = lab.digest()
    proc = subprocess.run([lab.tree + '/' + argv[0]] + argv[1:], env=lab.env, cwd=lab.run_dir,
                          stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
    return proc.returncode, proc.stdout, proc.stderr, before != lab.digest(), open(lab.calls).read()

for row in rows:
    e = entries[row['script'], row['operation']]
    groups = [None] + p.optional_groups(row['form'])
    if '[<decision-key>]' in row['form']: groups.append('[<decision-key>]')
    if '[<label>]' in row['form']: groups.append('[<label>]')
    for group in groups:
        argv, err = p.render(lab, row['form'], values, row['script'], keep=group)
        assert not err, (row['form'], err)
        # arm registers an isolated check only; stand-ins keep its subsequent board read local.
        rc, out, errout, changed, calls = run(argv)
        diagnostic = errout + out
        assert rc != 'timeout' and not (rc and p.PARSE_ERROR.search(diagnostic)), (row['form'], group, rc, diagnostic)
        before = lab.digest()
        if e['method'] == 'GET': assert not changed and not calls, (row['form'], out, calls)
        cli = ['bin/jg'] + e['path'] + argv[2:]
        crc, cout, cerr, cchanged, ccalls = run(cli)
        assert crc != 'timeout' and not (crc and p.PARSE_ERROR.search(cerr + cout)), (row['form'], group, crc, cerr + cout)
        assert crc == e['exits'].get(str(rc), 0 if rc == 0 else 1), (row['form'], rc, crc, cout)
        assert changed == cchanged, (row['form'], group, changed, cchanged)
        assert errout == cerr, (row['form'], group, 'stderr differs', errout, cerr)
        envelope = json.loads(cout.strip().splitlines()[-1])
        try: expected = json.loads(out)
        except ValueError: expected = {'stdout': out}
        if rc != 0:
            assert envelope['ok'] is False and envelope['data'].get('error') == errout, (row['form'], 'error differs', errout, cout)
            actual = {k: v for k, v in envelope['data'].items() if k != 'error'}
        else:
            assert envelope['ok'] is True, (row['form'], cout)
            actual = envelope['data']
        assert actual == expected, (row['form'], group, 'output differs', out, cout)
        assert before == lab.digest(), (row['form'], group, 'durable state differs')
print('ok - 15 decision forms, optional groups, reads and CLI parity')
PY
