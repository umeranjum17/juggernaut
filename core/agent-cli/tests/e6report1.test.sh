#!/usr/bin/env bash
# Exercise report operations against their real scripts in disposable homes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, re, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6report1']
fragment = json.loads((root/'core/agent-cli/contract/e6report1.json').read_text())
entries = fragment['entries']
assert len(rows) == len(entries) == 31
for r in rows:
    matches = [e for e in entries if e['script'] == 'bin/'+r['script'] and e['operation'] == r['operation']]
    assert len(matches) == 1, r
    e = matches[0]
    assert (e['form'], e['path'], e['method'], e['aliases']) == (r['form'], r['path'].split(), r['method'], [] if r['aliases'] == '-' else r['aliases'].split(',')), r
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext

# Keyed by canonical path to distinguish the no-verb and repeated verbs.
cases = {
'bearings-snapshot': [],
'branch-outcome append': ['--task','jg-fixture','--verdict','routine','--summary','fixture'],
'branch-outcome unread': [], 'branch-outcome mark-read': ['--through','1'],
'branch-outcome unprocessed': [], 'branch-outcome mark-processed': ['--through','1'],
'branch-outcome present': [], 'branch-outcome processed-init': [], 'branch-outcome list': [],
'branch-outcome lookup': ['--seqs','1'], 'branch-outcome startup-replay': [], 'branch-outcome seed-tail': [],
'clause decide': ['route-select'], 'clause facts': ['route-select'], 'clause list': [],
'clause add': ['--id','fixture','--point','missing','--when','fixture=yes','--then','allow'],
'clause validate': [], 'contract-carrier contract': [], 'contract-carrier path': ['claude'],
'contract-carrier check': ['claude'], 'contract-carrier ensure': ['claude'],
'doc-audience-check': [], 'doc-audience-check root': ['--root','MISSING'],
'fleet-ledger dispatched': ['jg-fixture','ship','demo','claude','default'],
'fleet-ledger merged pr': ['jg-fixture','https://example.invalid/fixture'],
'fleet-ledger merged local': ['jg-fixture'], 'fleet-ledger capture': [],
'fleet-ledger appended': ['CONFIG','STATUS'],
'fleet-ledger pr_ready': ['jg-fixture','https://example.invalid/fixture'],
'fleet-ledger cleaned_up': ['jg-fixture'], 'live-claim': ['report','fixture'],
}
options = {
'branch-outcome append': [['--wake','fixture'],['--silent','true']],
'branch-outcome processed-init': [['--held-lock']], 'branch-outcome list': [['--recent','1']],
'clause decide': [['hard=false']], 'clause facts': [['hard=false']], 'clause list': [['route-select']],
'clause add': [['--reason','fixture'],['--rule','fixture']],
'doc-audience-check root': [['--inventory','MISSING']],
}
def digest(home):
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
with tempfile.TemporaryDirectory(prefix='jg-e6report1-') as tmp:
    tmp = pathlib.Path(tmp)
    bindir = tmp/'bin'; bindir.mkdir()
    clock = bindir/'date'; clock.write_text('#!/bin/sh\nexec /bin/date -u -d @1700000000 "$@"\n'); clock.chmod(0o755)
    status = tmp/'status'; status.write_text('working: fixture\n')
    for e in entries:
        key = ' '.join(e['path'][1:])
        assert key in cases, key
        for extra in [[]] + options.get(key, []):
            results = []
            for name in ('direct','jg'):
                home = tmp/name
                # A fresh isolated home for every invocation, including optional forms.
                if home.exists():
                    import shutil
                    shutil.rmtree(home)
                for part in ('state','config','data','projects','tmp'):
                    (home/part).mkdir(parents=True, exist_ok=True)
                os.link(status, home/'state/jg-fixture.status')
                env = dict(os.environ, PATH=str(bindir)+os.pathsep+os.environ['PATH'], HOME=str(home), TMPDIR=str(home/'tmp'), JG_HOME=str(home),
                           JG_STATE_OVERRIDE=str(home/'state'), JG_DATA_OVERRIDE=str(home/'data'),
                           JG_CONFIG_OVERRIDE=str(home/'config'), JG_CLAUSE_NOW='1700000000')
                substitutions = {'CONFIG': str(home/'config'), 'STATUS': str(home/'state/jg-fixture.status'), 'MISSING': str(home/'missing')}
                args = [substitutions.get(x,x) for x in cases[key] + extra]
                # The form retains positional literals, including merged <task> pr/local.
                if name == 'direct':
                    op = e['operation']
                    prefix = [] if op in ('-', '--root') else op.split()
                    if key == 'fleet-ledger merged pr': prefix = ['merged', args.pop(0), 'pr']
                    if key == 'fleet-ledger merged local': prefix = ['merged', args.pop(0), 'local']
                    command = [str(root/e['script']), *prefix, *args]
                else:
                    command = [str(root/'bin/jg'), *e['path'], *args]
                before = digest(home)
                result = subprocess.run(command, env=env, cwd=home, text=True, capture_output=True, timeout=90)
                results.append((result,before,digest(home),str(home)))
            (direct, db, da, dh), (jg, jb, ja, jh) = results
            normalize = lambda s,h: re.sub(r'generated: "[^"]+"', 'generated: <time>', s.replace(h,'<home>').replace(str(pathlib.Path(h).relative_to(pathlib.Path(h).parent.parent)), '<home>'))
            assert 'usage:' not in direct.stderr.lower() and 'expected one argument' not in direct.stderr.lower(), (e['form'],extra,direct.stderr)
            try: envelope = json.loads(jg.stdout)
            except ValueError: raise AssertionError((e['form'], extra, jg.stderr, jg.stdout))
            assert jg.returncode == (direct.returncode if direct.returncode in (0,1,2,3) else 1), (e['form'],extra,direct.returncode,jg.returncode,jg.stderr)
            assert envelope['ok'] == (direct.returncode == 0), (e['form'],extra,envelope)
            assert normalize(jg.stderr,jh) == normalize(direct.stderr,dh), (e['form'],extra,direct.stderr,jg.stderr)
            try: direct_data = json.loads(direct.stdout)
            except ValueError: direct_data = {'stdout': normalize(direct.stdout,dh)}
            data = envelope['data']
            if isinstance(data, dict) and not envelope['ok']:
                data = {k:v for k,v in data.items() if k != 'error'}
            if isinstance(data, dict) and 'stdout' in data:
                data = dict(data, stdout=normalize(data['stdout'],jh))
            assert data == direct_data, (e['form'],extra,direct.stdout,envelope)
            assert db == jb and da == ja, (e['form'],extra,'durable results differ',da,ja)
            if e['method'] == 'GET':
                assert db == da, (e['form'],extra,'GET changed the home')
print('e6report1: 31 report operations and isolated parity passed')
PY
