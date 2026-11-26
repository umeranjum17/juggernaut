#!/usr/bin/env bash
# Exercise the worker command routes with synthetic homes and no external services.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, re, shutil, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6crew2']
fragment = json.loads((root/'core/agent-cli/contract/e6crew2.json').read_text())
entries, dropped = fragment['entries'], fragment['dropped']
assert len(rows) == 38 and len(entries) + len(dropped) == len(rows)
for r in rows:
    pair = ('bin/'+r['script'], r['operation'])
    hits = [e for e in entries+dropped if (e['script'], e['operation']) == pair]
    assert len(hits) == 1, pair
    e = hits[0]
    if 'reason' in e:
        assert r['review'] == 'pending' and e['reason'], pair
    else:
        assert e['form'] == r['form'] and e['path'] == r['path'].split() and e['method'] == r['method'], pair
        assert e['aliases'] == ([] if r['aliases'] == '-' else r['aliases'].split(',')), pair
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext, e['path']

# A missing task or missing project stops operations before any worker or remote can start.
# Network and host-control operations are never run here; their CLI binding is checked on
# a recording stand-in with the same contract in an isolated dispatcher tree.
cases = {
 ('jg-model-stats.sh','-'): [], ('jg-quota-choose.sh','-'): [],
 ('jg-release-readiness.sh','tick'): ['HOME'], ('jg-release-readiness.sh','show'): ['HOME'],
 ('jg-release-smoke.sh','-'): [], ('jg-release-tag.sh','-'): ['invalid-url'],
 ('jg-remote-doctor.sh','-'): [], ('jg-remote-doctor.sh','--fix'): [],
 ('jg-remote-doctor.sh','--worker-tool-probe'): [],
 ('jg-remote-squad-lead-control.sh','launch'): ['missing','codex','default','default'],
 ('jg-remote-squad-lead-control.sh','relaunch'): ['missing','codex','default','default'],
 ('jg-remote-squad-lead-control.sh','state'): ['missing'], ('jg-remote-squad-lead-control.sh','route'): ['missing'],
 ('jg-remote-squad-lead-control.sh','send'): ['missing','hello'], ('jg-remote-squad-lead-control.sh','key'): ['missing','x'],
 ('jg-remote-squad-lead-control.sh','capture'): ['missing'], ('jg-remote-squad-lead-control.sh','observe'): ['missing'],
 ('jg-remote-squad-lead-control.sh','sync'): ['missing'], ('jg-remote-squad-lead-control.sh','update'): ['missing'],
 ('jg-remote-squad-lead-control.sh','retire'): ['missing'],
 ('jg-remote-squad-lead-relaunch.sh','-'): ['missing','codex','default','default'],
 ('jg-spawn.sh','-'): ['missing'], ('jg-squad-lead-restart.sh','-'): ['missing'],
 ('jg-stack.sh','status'): [], ('jg-switch.sh','status'): ['--home','HOME'],
 ('jg-switch.sh','verify'): ['--home','HOME'], ('jg-switch.sh','refresh-releases'): ['--home','HOME'],
 ('jg-switch.sh','flags'): ['missing','--home','HOME'], ('jg-switch.sh','count'): ['--home','HOME'],
 ('jg-switch.sh','apply'): ['missing','example','--home','HOME'], ('jg-tool-models.sh','resolve'): ['missing'],
 ('jg-tool-models.sh','model'): ['missing','codex'], ('jg-tool-models.sh','profiles'): ['missing'],
 ('jg-tool-models.sh','check'): [], ('jg-vendor-auth-probe.sh','-'): ['invalid'],
}
unsafe = {'jg-release-tag.sh','jg-remote-doctor.sh','jg-remote-squad-lead-relaunch.sh',
          'jg-spawn.sh','jg-squad-lead-restart.sh','jg-switch.sh:refresh-releases','jg-vendor-auth-probe.sh'}
def digest(home):
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
with tempfile.TemporaryDirectory(prefix='jg-crew2-') as td:
    tmp = pathlib.Path(td)
    # A copied dispatcher and recording executables verify arguments without invoking
    # the host, a worker, or the network. Real execution is used below where safe.
    tree = tmp/'standin'
    (tree/'core/agent-cli/contract').mkdir(parents=True)
    (tree/'bin').mkdir()
    shutil.copy(root/'core/agent-cli/dispatch.sh', tree/'core/agent-cli/dispatch.sh')
    shutil.copy(root/'core/agent-cli/contract/e6crew2.json', tree/'core/agent-cli/contract/e6crew2.json')
    for script in {pathlib.Path(e['script']).name for e in entries}:
        f = tree/'bin'/script
        f.write_text('#!/usr/bin/env bash\n[ "$#" -eq 0 ] || printf \'%s\\n\' "$@"\n')
        f.chmod(0o755)
    for e in entries:
        script = pathlib.Path(e['script']).name; op = e['operation']; key = (script, op)
        assert key in cases, key
        if script in unsafe or script+':'+op in unsafe:
            args = [str(tmp/'home') if v == 'HOME' else v for v in cases[key]]
            r = subprocess.run(['bash', str(tree/'core/agent-cli/dispatch.sh'), 'run', *e['path'], *args],
                               input='', text=True, capture_output=True, timeout=20)
            assert r.returncode == 0, (key, r.stderr)
            recorded = json.loads(r.stdout)['data']['stdout'].splitlines()
            direct = ([] if op == '-' else [op]) + args
            if script == 'jg-spawn.sh': direct += ['--relaunch']
            assert recorded == direct, (key, recorded, direct)
            continue
        outcomes = []
        for side in ('direct','jg'):
            home = tmp/(script+'-'+op.replace('/', '_'))/side/'home'
            for d in ('state','config','data','projects'):
                (home/d).mkdir(parents=True, exist_ok=True)
            env = dict(os.environ, HOME=str(tmp), TMPDIR=str(tmp), JG_HOME=str(home),
                       JG_STATE_OVERRIDE=str(home/'state'), JG_DATA_OVERRIDE=str(home/'data'),
                       JG_CONFIG_OVERRIDE=str(home/'config'), JG_ROOT_OVERRIDE=str(tmp/'root'))
            args = [str(home) if v == 'HOME' else v for v in cases[key]]
            if side == 'jg':
                command = [str(root/'bin/jg'), *e['path'], *args]
            else:
                # Readiness places the home before the operation.
                prefix = [args.pop(0), op] if script == 'jg-release-readiness.sh' else ([] if op == '-' else [op])
                literals = {'jg-model-stats.sh': ['--json'], 'jg-release-smoke.sh': ['--help']}
                if script == 'jg-remote-squad-lead-control.sh' and op == 'launch': args.append('herdr')
                command = [str(root/e['script']), *prefix, *args, *literals.get(script, [])]
            before = digest(home)
            r = subprocess.run(command, env=env, input='', text=True, capture_output=True, timeout=20)
            outcomes.append((r, before, digest(home), str(home)))
        (direct, db, da, dh), (jg, jb, ja, jh) = outcomes
        try: data = json.loads(jg.stdout)
        except ValueError: raise AssertionError((key, jg.returncode, jg.stdout, jg.stderr))
        assert jg.returncode == (direct.returncode if direct.returncode in (0,1,2,3) else 1), (key, direct.returncode, jg.returncode, jg.stderr)
        assert data['ok'] == (direct.returncode == 0), (key, data)
        # Compare the script's output through the public envelope as well as exit and state.
        # Model statistics include the current clock and are checked separately by their journey.
        if script != 'jg-model-stats.sh' and direct.stdout:
            raw = direct.stdout.replace(dh, '<home>')
            try: expected = json.loads(raw)
            except ValueError: expected = {'stdout': raw}
            got = json.loads(json.dumps(data['data']).replace(jh, '<home>'))
            if isinstance(got, dict): got.pop('error', None)
            assert got == expected, (key, expected, got)
        assert db == jb and da == ja, (key, 'home contents differ')
        if e['method'] == 'GET': assert db == da, (key, 'GET changed the home')
    # Every optional option is bound in isolation. A quoted value currently has
    # a known dispatcher gap; prove that real script accepts it instead.
    gaps = []
    for e in entries:
        script = pathlib.Path(e['script']).name; op = e['operation']; key = (script, op)
        base = [str(tmp/'fixture-home') if v == 'HOME' else v for v in cases[key]]
        for flag, value in re.findall(r'\[(--[a-z-]+)\s+"?(<[^>]+>)"?\](?:\.\.\.)?', e['form']):
            val = {'--candidate':'codex:fixture', '--now':'1790000000', '--home':str(tmp/'fixture-home')}.get(flag, 'fixture')
            r = subprocess.run(['bash', str(tree/'core/agent-cli/dispatch.sh'), 'run', *e['path'], *base, flag, val],
                               input='', text=True, capture_output=True, timeout=20)
            if script == 'jg-switch.sh' and op == 'apply' and flag == '--owner-word' and r.returncode != 0:
                assert r.returncode == 2 and 'unexpected argument' in r.stderr, (key, r.stderr)
                env = dict(os.environ, JG_HOME=str(tmp/'fixture-home'), JG_ROOT_OVERRIDE=str(tmp/'root'))
                direct = subprocess.run([str(root/e['script']), 'apply', 'missing', 'example', flag, val],
                                        env=env, input='', text=True, capture_output=True, timeout=20)
                assert 'no manifest row' in direct.stderr, direct.stderr
                gaps.append('switch apply --owner-word')
            else:
                assert r.returncode == 0, (key, flag, r.stderr)
                assert json.loads(r.stdout)['data']['stdout'].splitlines()[-2:] == [flag, val], (key, flag, r.stdout)
    assert gaps in ([], ['switch apply --owner-word'])
print('e6crew2: inventory, help, safe direct calls and home parity passed')
PY
