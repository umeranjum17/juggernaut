#!/usr/bin/env bash
# Exercise the landing command contract against the real scripts in isolated homes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6land2']
fragment = json.loads((root/'core/agent-cli/contract/e6land2.json').read_text())
entries = fragment['entries']
assert len(rows) == len(entries) == 31
for row in rows:
    matches = [e for e in entries if e['script'] == 'bin/'+row['script'] and e['operation'] == row['operation']]
    assert len(matches) == 1, row
    e = matches[0]
    assert e['form'] == row['form'] and e['path'] == row['path'].split() and e['method'] == row['method'], row
    assert e['aliases'] == ([] if row['aliases'] == '-' else row['aliases'].split(',')), row
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext

# Each fixture exercises the actual argument form without starting a worker or reaching a forge.
cases = {
 'init': ['/missing-project'], 'proof': ['jg-missing'], 'forecast': ['jg-missing'],
 'land': ['jg-missing'], 'classify': ['LOG'], 'land-batch': ['jg-missing', 'jg-other'],
 'flush': ['/missing-project'], 'land-next': ['jg-missing'], 'cancel': ['jg-missing', '--reason', 'fixture'],
 'verify': ['/missing-project'], 'verify-due': ['/missing-project'], 'nightly': ['/missing-project'],
 'nightly-due': ['/missing-project'], 'green-alarm': ['/missing-project'],
 'word': ['in-use', '/missing-project', 'fixture words'], 'recover': ['/missing-project'],
 'adopt-tip': ['/missing-project', '--reason', 'fixture'], 'live': ['/missing-project'],
 'autolive': ['/missing-project'], 'waiver': ['/missing-project', '--rule', 'owner-rule-fixture'],
 'ci': ['/missing-project', 'fixture-sha', 'green'], 'release': ['/missing-project'],
 'publish': ['/missing-project'], 'autorelease': ['/missing-project'], 'rollover': ['/missing-project'],
 'retire': ['/missing-project'], 'due': ['/missing-project'], 'release-daily': [],
 'run': [], 'features': ['not-a-url'], 'reconcile': ['/missing-project'],
}
options = {
 'init': [['fixture-ref']], 'forecast': [['--record']], 'classify': [['LOG']],
 'verify': [['fixture-sha']], 'recover': [['--prepare', 'jg-missing'], ['--land', 'jg-missing']],
 'adopt-tip': [['--carried-by', 'jg-missing']], 'live': [['--home', '/missing-home']],
 'autolive': [['--now']], 'features': [['/missing-project']],
}
def digest(home):
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in home.rglob('*') if p.is_file()}
with tempfile.TemporaryDirectory(prefix='jg-e6land2-') as tmp:
    tmp = pathlib.Path(tmp)
    log = tmp/'fixture.log'; log.write_text('fixture refusal\n')
    for e in entries:
        op = e['operation']
        assert op in cases, op
        for extra in [[]] + options.get(op, []):
            args = [str(log) if x == 'LOG' else x for x in cases[op] + extra]
            results = []
            for name, command in [('direct', [str(root/e['script']), op]),
                                  ('jg', [str(root/'bin/jg'), *e['path']])]:
                home = tmp/name
                for part in ('state', 'config', 'data', 'projects'):
                    (home/part).mkdir(parents=True, exist_ok=True)
                env = dict(os.environ, HOME=str(tmp), TMPDIR=str(tmp), JG_HOME=str(home), JG_ROOT_OVERRIDE=str(tmp/'root'),
                           JG_STATE_OVERRIDE=str(home/'state'), JG_DATA_OVERRIDE=str(home/'data'),
                           JG_CONFIG_OVERRIDE=str(home/'config'), JG_TASK_ID='jg-fixture')
                before = digest(home)
                result = subprocess.run(command + args, env=env, text=True, capture_output=True)
                results.append((result, before, digest(home), str(home)))
            (direct, direct_before, direct_after, dh), (dispatched, jg_before, jg_after, jh) = results
            normalize = lambda value, home: value.replace(home, '<home>')
            try: envelope = json.loads(dispatched.stdout)
            except ValueError: raise AssertionError((e['form'], args, dispatched.returncode, dispatched.stdout, dispatched.stderr))
            assert normalize(dispatched.stderr, jh) == normalize(direct.stderr, dh), (e['form'], args, direct.stderr, dispatched.stderr)
            assert dispatched.returncode == (direct.returncode if direct.returncode in (0,1,2,3) else 1), (e['form'], args, direct.returncode, dispatched.returncode)
            assert envelope['ok'] == (direct.returncode == 0), (e['form'], args, envelope)
            assert normalize(envelope['data'].get('stdout', ''), jh) == normalize(direct.stdout, dh), (e['form'], args, direct.stdout, envelope)
            assert direct_before == jg_before and direct_after == jg_after, (e['form'], args, 'durable results differ')
            if e['method'] == 'GET':
                assert direct_before == direct_after, (e['form'], args, 'GET changed the home')
            assert 'usage:' not in direct.stderr.lower(), (e['form'], args, direct.stderr)
print('e6land2: 31 operations, real forms and isolated parity passed')
PY
