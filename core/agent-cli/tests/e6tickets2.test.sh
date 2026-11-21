#!/usr/bin/env bash
# Exercise the backlog command contract through the real scripts in isolated homes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, importlib.util, json, os, pathlib, re, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6tickets2']
f = json.loads((root/'core/agent-cli/contract/e6tickets2.json').read_text())
assert len(rows) == 31
for row in rows:
    entries = [e for e in f['entries'] if e['script'] == 'bin/'+row['script'] and e['operation'] == row['operation']]
    dropped = [e for e in f.get('dropped', []) if e['script'] == 'bin/'+row['script'] and e['operation'] == row['operation']]
    assert len(entries) + len(dropped) == 1, row
    if dropped:
        assert row['review'] == 'pending' and dropped[0]['reason'] and dropped[0]['run'], row
        continue
    e = entries[0]
    assert e['form'] == row['form'] and e['path'] == row['path'].split() and e['method'] == row['method'], row
    assert e['aliases'] == ([] if row['aliases'] == '-' else row['aliases'].split(',')), row
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in f['entries']:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext
# The inventory lab copies the product and provides synthetic homes and command stand-ins.
spec = importlib.util.spec_from_file_location('parse_inventory', root/'core/agent-cli/inventory/parse.py')
parse = importlib.util.module_from_spec(spec); spec.loader.exec_module(parse)
def snapshot(home):
    out = {}
    for p in pathlib.Path(home).rglob('*'):
        if p.is_file():
            data = p.read_bytes()
            out[str(p.relative_to(home))] = re.sub(rb'(?<![0-9])1[0-9]{9}(?![0-9])', b'<epoch>', data)
    return out
with tempfile.TemporaryDirectory(prefix='jg-e6tickets2-') as temp:
    lab = parse.Lab(str(root), str(pathlib.Path(temp)/'lab'))
    for row in rows:
        if row['script'] == 'jg-promote.sh':
            continue
        entry = next(e for e in f['entries'] if e['script'] == 'bin/'+row['script'] and e['operation'] == row['operation'])
        for keep in [None] + parse.optional_groups(entry['form']):
            overrides = {'goal-id':'jg-missing', 'id':'jg-missing', 'machine':'ticket', 'proof argv...':'/bin/true',
                         'checks':'config', 'YYYY-MM-DDTHH:MMZ':'2099-01-01T00:00Z'}
            argv, why = parse.render(lab, entry['form'], overrides, row['script'], keep)
            assert argv, (entry['form'], why)
            # Restrict triage to configuration, including when --fix or --agent is present.
            if row['script'] == 'jg-triage.sh':
                if '--only' not in argv: argv += ['--only', 'config']
                if '--offline' not in argv: argv += ['--offline']
            args = argv[1:]
            op = entry['operation'].split() if entry['operation'] != '-' else []
            for word in op: args.remove(word)
            calls = []
            for command in (argv, ['bin/jg', *entry['path'], *args]):
                lab.reset()
                before = snapshot(lab.home)
                result = subprocess.run([str(pathlib.Path(lab.tree)/command[0]), *command[1:]],
                    env=lab.env, cwd=lab.run_dir, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
                calls.append((result, before, snapshot(lab.home)))
            (direct, before, after), (via, before2, after2) = calls
            assert not parse.PARSE_ERROR.search(direct.stderr), (entry['form'], keep, direct.stderr)
            assert before == before2, entry['form']
            if entry['method'] == 'GET': assert before == after, (entry['form'], 'GET changed home')
            try: envelope = json.loads(via.stdout)
            except ValueError: raise AssertionError((entry['form'], keep, via.stderr, via.stdout))
            assert via.returncode == direct.returncode, (entry['form'], keep, direct.returncode, via.returncode, via.stderr)
            assert envelope['ok'] == (direct.returncode == 0), (entry['form'], keep, envelope)
            assert after == after2, (entry['form'], keep, 'home differs')
            assert via.stderr == direct.stderr, (entry['form'], keep, direct.stderr, via.stderr)
            try: expected = json.loads(direct.stdout)
            except ValueError: expected = {'stdout': re.sub(r'(?<![0-9])1[0-9]{9}(?![0-9])', '<epoch>', direct.stdout)}
            actual = envelope['data'].copy()
            if isinstance(actual, dict):
                actual.pop('error', None)
                if 'stdout' in actual: actual['stdout'] = re.sub(r'(?<![0-9])1[0-9]{9}(?![0-9])', '<epoch>', actual['stdout'])
            assert actual == expected, (entry['form'], keep, expected, actual)
    # A documented dispatcher gap is tracked by the lead: direct workflow arguments work.
    lab.reset()
    direct = subprocess.run([lab.tree+'/bin/jg-workflow.sh', 'parse', 'recon(quick)'], env=lab.env, capture_output=True, text=True)
    assert direct.returncode == 0 and json.loads(direct.stdout)['spec'] == 'recon(quick)'
    via = subprocess.run([lab.tree+'/bin/jg', 'ticket', 'workflow', 'parse', 'recon(quick)'], env=lab.env, capture_output=True, text=True)
    assert via.returncode == 2 and 'unexpected argument recon(quick)' in via.stderr
    # The pending promotion row is a refused mode value, not an operation.
    direct = subprocess.run([lab.tree+'/bin/jg-promote.sh', 'jg-missing', '--mode', 'no-mistakes-prod-only', '--yolo', 'off'], env=lab.env, capture_output=True, text=True)
    assert direct.returncode != 0 and 'registry policy, not a task mode' in direct.stderr
print('e6tickets2: inventory, real forms and isolated dispatch parity passed; workflow argument gap recorded')
PY
