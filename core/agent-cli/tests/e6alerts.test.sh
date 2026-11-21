#!/usr/bin/env bash
# Exercise cleanup and alert routes using only isolated homes and synthetic process data.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, re, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6alerts']
fragment = json.loads((root/'core/agent-cli/contract/e6alerts.json').read_text())
entries = fragment['entries']
dropped = fragment['dropped']
assert len(rows) == 24
for row in rows:
    matches = [e for e in entries + dropped if e['script'] == 'bin/'+row['script'] and e['operation'] == row['operation']]
    assert len(matches) == 1, row
    e = matches[0]
    if e in dropped:
        assert row['review'] == 'pending' and e['reason'] and e['run'], row
        continue
    assert e['path'] == row['path'].split() and e['method'] == row['method'], row
    assert e['aliases'] == ([] if row['aliases'] == '-' else row['aliases'].split(',')), row
    if row['script'] != 'jg-teardown-core.sh':
        assert e['form'] == row['form'], row
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext

# No cleanup target exists, and browser selection uses an empty synthetic process table.
cases = {
 ('jg-alert.sh','row'): ['capacity'], ('jg-alert.sh','limit'): ['ship'],
 ('jg-alert.sh','timers'): [], ('jg-alert.sh','raise'): ['capacity','fixture'],
 ('jg-alert.sh','capacity'): ['fixture','fixture text'], ('jg-alert.sh','climb'): ['missing'],
 ('jg-alert.sh','ack'): ['missing'], ('jg-alert.sh','reopen'): ['missing'],
 ('jg-alert.sh','resolve'): ['missing','--proof','source:fixture'],
 ('jg-alert.sh','resolve-ticket'): ['jg-missing','--proof','source:fixture'],
 ('jg-alert.sh','overdue'): [], ('jg-alert.sh','show'): ['capacity--fixture'],
 ('jg-alert.sh','deliver'): [], ('jg-alert.sh','word'): ['missing'],
 ('jg-alert.sh','list'): [], ('jg-browser-sweep.sh','-'): [],
 ('jg-teardown-core.sh','-'): ['default-branch','--project','/missing-project'],
 ('jg-teardown.sh','-'): ['jg-missing','--park'],
 ('jg-tmp-reaper.sh','check'): [], ('jg-tmp-reaper.sh','arm'): [],
 ('jg-tmp-sweep.sh','check'): [], ('jg-tmp-sweep.sh','top'): [], ('jg-tmp-sweep.sh','sweep'): [],
}
options = {
 ('jg-alert.sh','raise'): [['--mode','local'],['--kind','ship'],['--held','3600'],['--fact','fixture=value'],
   ['--home','fixture'],['--project','fixture'],['--route','fixture'],['--machine','fixture'],
   ['--ticket','jg-fixture'],['--rung','1'],['--wake','check','--text','fixture'],['--repeat'],
   ['--note','fixture'],['--print'],['--deliver'],['--owner-gate','fixture','--ticket','jg-fixture','--origin','fixture'],
   ['--security-source','fixture']],
 ('jg-alert.sh','capacity'): [['--print'],['--deliver']], ('jg-alert.sh','climb'): [['--now','1']],
 ('jg-alert.sh','reopen'): [['--now','1']], ('jg-alert.sh','overdue'): [['--now','1']],
 ('jg-browser-sweep.sh','-'): [['--dry-run'],['--apply'],['--hours','1'],['--no-bridges']],
 ('jg-tmp-sweep.sh','check'): [['--root','ROOT'],['--warn-pct','100']],
 ('jg-tmp-sweep.sh','top'): [['--root','ROOT','-n','1']],
 ('jg-tmp-sweep.sh','sweep'): [['--dry-run','--root','ROOT','--min-age-days','1'], ['--apply','--root','ROOT','--min-age-days','1']],
}
def digest(home):
    result = {}
    files = sorted(p for p in home.rglob('*') if p.is_file())
    episodes = []
    for p in files:
        for value in re.findall(rb'(?m)^episode=([^\n]+)$', p.read_bytes()):
            assert re.fullmatch(rb'12345-\d+-\d+', value), (p, value)
            assert value not in episodes, (p, value, 'distinct episodes share an identity')
            episodes.append(value)
    for p in files:
        if not p.is_file():
            continue
        data = p.read_bytes()
        if p.name in ('.wake-bus.events.jsonl', '.wake-bus.outbox.jsonl', 'chat.jsonl'):
            records = [json.loads(line) for line in data.splitlines()]
            for record in records:
                for field in ('at', 'seq', 'rseq'):
                    if field in record:
                        assert isinstance(record[field], int) and record[field] > 0
                        record[field] = '<generated>'
                if 'id' in record:
                    assert record['id'].startswith('wake/')
                    record['id'] = '<wake-id>'
                if 'home' in record:
                    assert record['home'].startswith(home.name + ':')
                    record['home'] = '<home-id>'
                if 'subject' in record:
                    assert record['subject'] == 'jg.' + home.name + '_.wake.raise'
                    record['subject'] = '<wake-subject>'
            data = json.dumps(records, sort_keys=True).encode()
        elif p.name in ('.wake-queue', '.wake-realert'):
            lines = [line.split(b'\t') for line in data.splitlines()]
            for line in lines:
                assert line[0].isdigit()
                line[0] = b'<clock>'
                if p.name == '.wake-queue':
                    assert line[1].isdigit()
                    line[1] = b'<sequence>'
            data = b'\n'.join(b'\t'.join(line) for line in lines)
        elif p.name == 'wake-ledger.tsv':
            lines = [line.split(b'\t') for line in data.splitlines()]
            for line in lines:
                assert len(line) == 5 and line[0].isdigit()
                line[0] = b'<clock>'
            data = b'\n'.join(b'\t'.join(line) for line in lines)
        elif p.name == 'wake-order' and p.parent.name == 'bus':
            assert data.strip().isdigit()
            data = b'<sequence>'
        if p.name == 'tmp-reaper.check-trust':
            check = p.with_name('tmp-reaper.check.sh')
            assert data.decode().splitlines() == ['jg-custom-check-v1', hashlib.sha256(check.read_bytes()).hexdigest()]
            data = b'valid trust for check'
        data = data.replace(str(home).encode(), b'<home>')
        for index, episode in enumerate(episodes):
            data = data.replace(episode, ('<episode-%d>' % index).encode())
        result[str(p.relative_to(home))] = data
    return result

with tempfile.TemporaryDirectory(prefix='jg-e6alerts-') as tmp:
    tmp = pathlib.Path(tmp)
    build_env = dict(os.environ, HOME=str(tmp), TMPDIR=str(tmp), GOCACHE=str(tmp/'go-cache'), GOTOOLCHAIN='local')
    subprocess.run(['go', 'build', '-o', str(tmp/'teardown-core'), './cmd/jg-teardown'],
                   cwd=root/'core/teardown', env=build_env, check=True)
    ps = tmp/'ps'; ps.write_text('')
    sandbox = tmp/'scratch'; sandbox.mkdir()
    for e in entries:
        script = pathlib.Path(e['script']).name
        key = (script,e['operation'])
        assert key in cases, key
        for extra in [[]] + options.get(key, []):
            print('checking', '/'.join(key), ' '.join(extra) or '(default)', flush=True)
            results = []
            for name in ('direct','jg'):
                home = tmp/name
                for part in ('state','config','data','projects','tmp'):
                    (home/part).mkdir(parents=True, exist_ok=True)
                env = dict(os.environ, HOME=str(home), TMPDIR=str(home/'tmp'), JG_HOME=str(home),
                           JG_STATE_OVERRIDE=str(home/'state'), JG_DATA_OVERRIDE=str(home/'data'),
                           JG_CONFIG_OVERRIDE=str(home/'config'), JG_TMP_ROOT=str(sandbox), JG_TMP_WARN_PCT='100', JG_ALERT_NOW='12345',
                           JG_BROWSER_SWEEP_PS_FILE=str(ps), JG_BROWSER_SWEEP_SESSIONS_FILE=str(ps),
                           JG_BROWSER_SWEEP_PROFILE_PREFIX=str(sandbox/'profile-'),
                           JG_TEARDOWN_CORE_BIN=str(tmp/'teardown-core'), JG_TEARDOWN_CORE_GO='false')
                argv = [str(sandbox) if x == 'ROOT' else x for x in cases[key]+extra]
                direct = [str(root/e['script'])] + ([] if e['operation']=='-' else [e['operation']])
                command = direct if name == 'direct' else [str(root/'bin/jg'), *e['path']]
                before = digest(home)
                result = subprocess.run(command+argv, env=env, input='', text=True, capture_output=True, timeout=60)
                results.append((result,before,digest(home),str(home)))
            (direct, db, da, dh), (jg, jb, ja, jh) = results
            if e['method'] == 'GET':
                assert db == da and jb == ja, (key, argv, 'GET changed home')
            assert 'usage:' not in direct.stderr.lower(), (e['form'], argv, direct.stderr)
            try:
                envelope = json.loads(jg.stdout)
            except ValueError:
                raise AssertionError((e['form'],argv,jg.returncode,jg.stdout,jg.stderr))
            def norm(s,h):
                s = s.replace(h,'<home>')
                for index, record in enumerate(sorted((pathlib.Path(h)/'state/alerts').glob('*.rec'))):
                    episode = re.search(r'(?m)^episode=(.+)$', record.read_text())
                    if episode:
                        s = s.replace(episode.group(1), '<episode-%d>' % index)
                s = re.sub(r'space \d+% used \([^\n]+\), inodes \d+% used \([^\n]+\)', 'space and inode usage', s)
                s = re.sub(r'cutoff \d{4}-\d\d-\d\d \d\d:\d\d:\d\d', 'cutoff <clock>', s)
                return re.sub(r'((?:inode|space) use of [^\n]+): \d+% before, \d+% after', r'\1: <usage>', s)
            assert norm(jg.stderr,jh) == norm(direct.stderr,dh), (e['form'],argv,direct.stderr,jg.stderr)
            assert jg.returncode == (direct.returncode if direct.returncode in (0,1,2) else 1), (e['form'],argv,direct.returncode,jg.returncode)
            assert norm(envelope['data'].get('stdout',''),jh) == norm(direct.stdout,dh), (e['form'],argv,direct.stdout,envelope)
            assert db == jb, (e['form'], argv, 'fixture homes differ before call')
            if da != ja:
                from itertools import zip_longest
                path = next(k for k in sorted(da.keys() | ja.keys()) if da.get(k) != ja.get(k))
                left = da.get(path, b'<missing>').decode(errors='replace').splitlines()
                right = ja.get(path, b'<missing>').decode(errors='replace').splitlines()
                pair = next((x,y) for x,y in zip_longest(left,right) if x != y)
                raise AssertionError((e['form'], argv, path, 'first differing field', pair))
print('e6alerts: inventory, help, isolated reads and script parity passed')
PY
