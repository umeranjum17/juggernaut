#!/usr/bin/env bash
# Exercise backlog command forms and parity on isolated homes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, re, shutil, subprocess, tempfile, time
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6tickets1']
f = json.loads((root/'core/agent-cli/contract/e6tickets1.json').read_text())
entries = f['entries']
assert len(rows) == len(entries) == 17
for r in rows:
    e, = [e for e in entries if e['script'] == 'bin/'+r['script'] and e['operation'] == r['operation']]
    assert e['path'] == r['path'].split() and e['method'] == r['method']
    assert e['form'] == r['form'] or (r['script'] == 'jg-classify.sh' and e['form'] == 'bin/jg-classify.sh <command> [<args...>]')
    assert e['aliases'] == ([] if r['aliases'] == '-' else r['aliases'].split(','))
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext

def digest(home):
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
cases = {
 'ticket backlog-handoff': [], 'ticket backlog-handoff resume-pending': [],
 'ticket backlog-receive': [], 'ticket backlog-receive check': [],
 'ticket backlog approve-dispatch': ['missing', '--harness', 'codex', '--model', 'fixture', '--effort', 'low'],
 'ticket backlog show': ['q-1'], 'ticket backlog list': [], 'ticket backlog ready': [],
 'ticket backlog markdown': [], 'ticket backlog homes': [], 'ticket backlog tree': [],
 'ticket backlog compare': [], 'ticket backlog add': ['Fixture item'],
 'ticket backlog update': ['missing'], 'ticket backlog done': ['missing'],
 'ticket classify': ['verb', 'working: fixture'], 'ticket flow': [],
}
options = {'ticket backlog show': [['--full']], 'ticket backlog update': [['--title', 'Fixture title']],
           'ticket flow': [['--now', '0'], ['--checks'], ['--now', '0', '--capacity']]}
with tempfile.TemporaryDirectory(prefix='jg-e6tickets1-') as tmp:
    tmp = pathlib.Path(tmp)
    base = tmp/'base'
    for part in ('state', 'config', 'data', 'projects'):
        (base/part).mkdir(parents=True, exist_ok=True)
    (base/'config/backlog-intake-loose').touch()
    seed_env = dict(os.environ, HOME=str(tmp), TMPDIR=str(tmp), JG_HOME=str(base),
                    JG_STATE_OVERRIDE=str(base/'state'), JG_DATA_OVERRIDE=str(base/'data'),
                    JG_CONFIG_OVERRIDE=str(base/'config'), JG_ROOT_OVERRIDE=str(tmp/'root'))
    seed_env.pop('JG_TASK_ID', None)
    subprocess.run([str(root/'bin/jg-backlog.sh'), 'add', 'q-1', '[feature] Ready work', '--priority', '1',
                    '--kind', 'ship', '--repo', 'alpha', '--body', 'Fixture'], env=seed_env, check=True,
                   stdout=subprocess.DEVNULL, cwd=base)
    index = 0
    for e in entries:
        name = ' '.join(e['path'])
        for extra in [[]] + options.get(name, []):
            results = []
            index += 1
            for kind in ('direct', 'jg'):
                home = tmp/(str(index)+'-'+kind)
                shutil.copytree(base, home)
                env = dict(os.environ, HOME=str(tmp), TMPDIR=str(tmp), JG_HOME=str(home),
                           JG_STATE_OVERRIDE=str(home/'state'), JG_DATA_OVERRIDE=str(home/'data'),
                           JG_CONFIG_OVERRIDE=str(home/'config'), JG_ROOT_OVERRIDE=str(tmp/'root'))
                env.pop('JG_TASK_ID', None)
                args = cases[name] + extra
                # The form itself supplies all operation words and literal flags.
                fixed = e['form'].split()[1:]
                fixed = [x for x in fixed if not (x.startswith('<') or x.startswith('[') or x.endswith('>'))]
                if e['operation'] == 'approve-dispatch': fixed = ['approve-dispatch']
                cmd = [str(root/e['script']), *fixed] if kind == 'direct' else [str(root/'bin/jg'), *e['path']]
                before = digest(home)
                start = time.time()
                p = subprocess.run(cmd + args, env=env, capture_output=True, text=True)
                end = time.time()
                listed = ''
                if name == 'ticket backlog add' and p.returncode == 0:
                    listed = subprocess.check_output([str(root/'bin/jg-backlog.sh'), 'list'], env=env, text=True)
                results.append((p, before, digest(home), str(home), listed, start, end))
            (a, before_a, after_a, ha, la, sa, ea), (b, before_b, after_b, hb, lb, sb, eb) = results
            ids = []
            if name == 'ticket backlog add':
                for out in (a.stdout, json.loads(b.stdout)['data']['stdout']):
                    match = re.search(r'ok: added (\S+)', out)
                    assert match, out
                    ids.append(match.group(1))
            def normalize(s, home):
                s = s.replace(home, '<home>')
                for item in ids: s = s.replace(item, '<new-id>')
                return s
            assert 'usage:' not in a.stderr.lower(), (e['form'], args, a.stderr)
            envelope = json.loads(b.stdout)
            assert normalize(a.stderr, ha) == normalize(b.stderr, hb), (e['form'], args, a.stderr, b.stderr)
            try: direct_data = json.loads(a.stdout)
            except ValueError: direct_data = {'stdout': a.stdout}
            if name == 'ticket flow' and isinstance(direct_data, dict):
                direct_data.pop('at', None)
                envelope['data'].pop('at', None)
                if '--capacity' in args:
                    ca, cb = direct_data['capacity'], envelope['data']['capacity']
                    print('capacity direct:', json.dumps(ca, sort_keys=True))
                    print('capacity jg:', json.dumps(cb, sort_keys=True))
                    assert isinstance(ca, dict) and isinstance(cb, dict) and set(ca) == set(cb)
                    for c, start, end in ((ca, sa, ea), (cb, sb, eb)):
                        assert int(start) <= c['observed_at'] <= int(end)
                        m = c['memory_bytes']
                        if m['MemTotal'] is not None:
                            assert m['MemTotal'] > 0 and 0 <= m['MemAvailable'] <= m['MemTotal']
                        if m['SwapTotal'] is not None:
                            assert 0 <= m['SwapFree'] <= m['SwapTotal']
                        for kind, limit in [('emulator', 'JG_EMU_MAX'), ('gradle_gate_match', 'JG_GRADLE_MAX')]:
                            count = c['gate_counts'][kind]
                            if count is not None:
                                assert count >= 0 and count == sum(j['kind'] == kind for j in c['jobs'])
                                assert c['slots_under_caps'][kind] == max(c['limits'][limit] - count, 0)
                        assert all(j['rss_bytes'] is None or (j['rss_bytes'] >= 0 and j['rss_bytes'] % 1024 == 0) for j in c['jobs'])
                        assert c['memory_pressure_percent'] is None or 0 <= c['memory_pressure_percent'] <= 100
                        if not c['tmp']['top_folders_complete']:
                            assert all(f['bytes'] is None and f['known_bytes'] >= 0 for f in c['tmp']['top_folders'])
                        for key in ('observed_at', 'memory_pressure_percent', 'jobs', 'gate_counts', 'slots_under_caps'):
                            c.pop(key)
                        for key in ('MemAvailable', 'SwapFree'): c['memory_bytes'].pop(key)
                        c['heavy_slice'].pop('MemoryCurrent', None)
                        for key in ('filesystem_used_bytes', 'top_folders', 'top_folders_complete'): c['tmp'].pop(key)
            assert normalize(json.dumps(direct_data, sort_keys=True), ha) == normalize(json.dumps(({k:v for k,v in envelope['data'].items() if k != 'error'} if isinstance(envelope['data'], dict) else envelope['data']), sort_keys=True), hb), (e['form'], args, a.stdout, b.stdout)
            assert b.returncode == (a.returncode if a.returncode in (0,1,2,3) else 1), (e['form'], args, a.returncode, b.returncode)
            assert before_a == before_b, (e['form'], args, 'initial home differs')
            if name == 'ticket backlog add':
                assert normalize(la, ha) == normalize(lb, hb) and 'Fixture item' in la
            else:
                assert after_a == after_b, (e['form'], args, 'home differs')
            if e['method'] == 'GET': assert before_a == after_a, (e['form'], args, 'GET changed home')
print('e6tickets1: 17 forms and isolated parity passed')
PY
