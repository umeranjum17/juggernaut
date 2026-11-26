#!/usr/bin/env bash
# Exercise notification command routes with real scripts and disposable homes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, re, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6radio3']
fragment = json.loads((root/'core/agent-cli/contract/e6radio3.json').read_text())
entries, dropped = fragment['entries'], fragment['dropped']
assert len(rows) == 39 and len(entries) + len(dropped) == 39
for row in rows:
    match = [e for e in entries + dropped if e['script'] == 'bin/'+row['script'] and e['operation'] == row['operation']]
    assert len(match) == 1, row
    e = match[0]
    if e in dropped:
        assert row['review'] == 'pending' and e['reason'] and e['run'], row
        continue
    assert e['path'] == row['path'].split() and e['method'] == row['method'], row
    assert e['aliases'] == ([] if row['aliases'] == '-' else row['aliases'].split(',')), row
    if e['script'] not in ('bin/jg-wake-core.sh', 'bin/jg-watch-core.sh', 'bin/jg-watch-arm.sh', 'bin/jg-watch-checkpoint.sh'):
        assert e['form'] == row['form'], row
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext

cases = {
 'raise': ['kind','key','message','now'], 'settle':['kind','key','message'],
 'raise-stdin':['kind','key','now'], 'settle-stdin':['kind','key'], 'ack':[],
 'ids':['kind','key'], 'ids-through':['1'], 'count':[],
 'inbox-raise':['jg-fixture','1','delivery','sha'],
 'inbox-handled':['jg-fixture','1','handled','evidence'], 'inbox-settle':[], 'render':[],
}
def arguments(e):
    script, op = pathlib.Path(e['script']).name, e['operation']
    if script == 'jg-supervision-instructions.sh': return ['--harness',op], [[], ['--read-only','1'], ['--afk','1'], ['--afk-mode','quiet'], ['--x-mode','1'], ['--repair-line'], ['--queue-pending','1']]
    if script == 'jg-wake-bus.sh': return [op]+cases[op], [[]] + ([['1']] if op == 'ack' else ([['SEQFILE']] if op == 'ids-through' else []))
    if script == 'jg-wake-core.sh': return ['count'], [[]]
    if script == 'jg-watch-core.sh': return ['inventory','/missing-fixture'], [[]]
    if script == 'jg-turnend-guard.sh': return ['--claude'], [[], ['--cursor']]
    if script == 'jg-watch-arm.sh': return ['--stop'], [[]]
    if script == 'jg-watch-checkpoint.sh': return [], [[], ['--seconds','0']]
    if script == 'jg-wake.sh': return [op], [[], ['3']] if op == 'settled' else [[], ['--ack-through','1','--recovery-generation','fixture']]
    return [], [[]]

def digest(home):
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
def normalize(text, home):
    text = text.replace(str(home), '<home>')
    text = re.sub(r'home:[0-9a-f]{8}', 'home:<key>', text)
    text = re.sub(r'\b[0-9]{9,}\b', '<time>', text)
    text = re.sub(r'(?<=<time>)-[0-9]+(?:-[0-9]+)?', '-<generated>', text)
    return text
def durable(home):
    out = {}
    for p in home.rglob('*'):
        if not p.is_file(): continue
        key = str(p.relative_to(home))
        if key.startswith('state/bin/') or key.endswith('.lock'): continue
        data = p.read_bytes()
        if b'\0' in data:
            raise AssertionError(('unrecognized binary state', key))
        else:
            out[key] = normalize(data.decode('utf-8', errors='replace'), home)
    return out
with tempfile.TemporaryDirectory(prefix='jg-e6radio3-') as td:
    tmp = pathlib.Path(td)
    seqfile = tmp/'sequences'; seqfile.write_text('1\n')
    for i, e in enumerate(entries):
        base, options = arguments(e)
        for n, extra in enumerate(options):
            args = [str(seqfile) if x == 'SEQFILE' else x for x in base + extra]
            if e['script'] == 'bin/jg-turnend-guard.sh' and extra: args = extra
            for side in ('direct','jg'):
                home = tmp/f'{i}-{n}-{side}'/'home'
                for part in ('state','config','data','projects'): (home/part).mkdir(parents=True, exist_ok=True)
                (home/'state/.wake-queue').write_text('')
                env = dict(os.environ, HOME=str(tmp), TMPDIR=str(tmp), XDG_CACHE_HOME=str(tmp/'cache'),
                           JG_HOME=str(home), JG_STATE_OVERRIDE=str(home/'state'), JG_DATA_OVERRIDE=str(home/'data'),
                           JG_CONFIG_OVERRIDE=str(home/'config'), JG_CLAUDE_AUTOARM_SYNC_WAIT_MS='0', JG_CODEX_WATCH_CHECKPOINT='0',
                           JG_BUS_BIN=str(tmp/'cache/jg-bus'))
                before = digest(home)
                supplied = args[2:] if e['script'] == 'bin/jg-supervision-instructions.sh' else (args[1:] if e['operation'] != '-' and args and args[0] == e['operation'] else args)
                command = [str(root/e['script']), *args] if side == 'direct' else [str(root/'bin/jg'), *e['path'], *supplied]
                payload = 'fixture payload' if e['operation'] in ('raise-stdin', 'settle-stdin') else ''
                result = subprocess.run(command, env=env, input=payload, text=True, capture_output=True, timeout=30)
                after = digest(home)
                saved = durable(home)
                if e['method'] == 'GET': assert before == after, (e['path'], side, before, after)
                if side == 'direct': direct, direct_saved, direct_home = result, saved, home
                else:
                    try: envelope = json.loads(result.stdout)
                    except ValueError: raise AssertionError((e['form'], args, result.returncode, result.stdout, result.stderr))
                    assert result.returncode == (direct.returncode if direct.returncode in (0,1,2,3) else 1), (e['form'], args, direct.returncode, result.returncode, direct.stderr, result.stderr)
                    assert envelope['ok'] == (direct.returncode == 0), (e['form'], args, envelope)
                    assert normalize(result.stderr, home) == normalize(direct.stderr, direct_home), (e['form'], args, direct.stderr, result.stderr)
                    try: expected_data = json.loads(direct.stdout)
                    except ValueError: expected_data = {'stdout': direct.stdout}
                    actual_data = envelope['data']
                    if direct.returncode and isinstance(actual_data, dict): actual_data = {k:v for k,v in actual_data.items() if k != 'error'}
                    assert normalize(json.dumps(actual_data, sort_keys=True), home) == normalize(json.dumps(expected_data, sort_keys=True), direct_home), (e['form'], args, direct.stdout, envelope)
                    assert saved == direct_saved, (e['form'], args, direct_saved, saved)
                    assert 'usage:' not in direct.stderr.lower(), (e['form'], args, direct.stderr)
print('e6radio3: routes, forms and isolated reads passed')
PY
