#!/usr/bin/env bash
# Exercise the homes command contract in isolated fixtures.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6homes']
contract = json.loads((root/'core/agent-cli/contract/e6homes.json').read_text())
entries = contract['entries']
assert len(rows) == len(entries) + len(contract['dropped']) == 33
for row in rows:
    found = [e for e in entries + contract['dropped'] if e['script'] == 'bin/'+row['script'] and e['operation'] == row['operation']]
    assert len(found) == 1, row
    e = found[0]
    if e in contract['dropped']:
        assert row['review'] == 'pending' and e['reason'] and e['run'], row
        continue
    assert e['path'] == row['path'].split() and e['method'] == row['method'], row
    assert e['aliases'] == ([] if row['aliases'] == '-' else row['aliases'].split(',')), row
    if row['path'] != 'home update base':
        assert e['form'] == row['form'], row
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext
# Exercise each read with a home that contains data, and compare all file bytes.
def digest(home):
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in home.rglob('*') if p.is_file()}
with tempfile.TemporaryDirectory(prefix='jg-e6homes-') as tmp:
    tmp = pathlib.Path(tmp)
    home = tmp/'home'
    for part in ('state', 'config', 'data', 'projects'):
        (home/part).mkdir(parents=True)
    (home/'data'/'fixture').write_text('fixture\n')
    env = dict(PATH=os.environ['PATH'], HOME=str(tmp), TMPDIR=str(tmp), JG_HOME=str(home),
               XDG_CONFIG_HOME=str(tmp/'xdg-config'), XDG_DATA_HOME=str(tmp/'xdg-data'),
               XDG_CACHE_HOME=str(tmp/'xdg-cache'), XDG_STATE_HOME=str(tmp/'xdg-state'),
               JG_STATE_OVERRIDE=str(home/'state'),
               JG_DATA_OVERRIDE=str(home/'data'), JG_CONFIG_OVERRIDE=str(home/'config'),
               JG_PROJECTS_OVERRIDE=str(home/'projects'))
    reads = {'home home-health check': [str(home)], 'home lead-daemon status': [],
             'home pref list': [], 'home pref get': ['peak-hours']}
    assert set(reads) == {' '.join(e['path']) for e in entries if e['method'] == 'GET'}
    for path, args in reads.items():
        before = digest(home)
        entry = next(e for e in entries if ' '.join(e['path']) == path)
        direct = subprocess.run([str(root/entry['script']), entry['operation'], *args], env=env, cwd=home,
                                capture_output=True, text=True, timeout=30)
        assert digest(home) == before, (path, 'direct GET changed home')
        run = subprocess.run([str(root/'bin/jg'), *path.split(), *args], env=env, cwd=home,
                             capture_output=True, text=True, timeout=30)
        assert digest(home) == before, (path, 'GET changed home')
        data = json.loads(run.stdout)
        assert direct.returncode == run.returncode and direct.stderr == run.stderr, (path, direct.stderr, run.stderr)
        try:
            expected = json.loads(direct.stdout)
        except ValueError:
            expected = {'stdout': direct.stdout}
        if direct.returncode != 0:
            expected['error'] = direct.stderr
        assert data['data'] == expected, (path, direct.stdout, run.stdout)
        if path.startswith('home pref '):
            assert data['ok'], (path, run.stdout, run.stderr)
    # Health check options each preserve the read-only home and reach the script.
    before_file = tmp/'before'; before_file.write_text('')
    for extra in (['--all'], ['--before', str(before_file)], ['--grace', '1'],
                  ['--session-max', '1'], ['--wait', '0'], ['0'*40]):
        results = []
        for command in ([str(root/'bin/jg-home-health.sh'), 'check'],
                        [str(root/'bin/jg'), 'home', 'home-health', 'check']):
            before = digest(home)
            run = subprocess.run(command + [str(home), *extra], env=env, cwd=home,
                                 capture_output=True, text=True, timeout=30)
            assert digest(home) == before, extra
            results.append(run)
        direct, wrapped = results
        data = json.loads(wrapped.stdout)
        assert wrapped.returncode == direct.returncode and wrapped.stderr == direct.stderr, (extra, wrapped.stderr)
        assert data['data'].get('stdout', '') == direct.stdout, (extra, direct.stdout, wrapped.stdout)
    # Each optional busy-event field is parsed independently, including no options.
    for n, extra in enumerate(([], ['--state', 'idle'], ['--source', 'fixture'], ['--event', 'fixture'])):
        for label in ('direct-busy', 'jg-busy'):
            state = tmp/(label+str(n)); state.mkdir()
            command = ([str(root/'bin/jg-busy-event.sh'), 'arm'] if label == 'direct-busy'
                       else [str(root/'bin/jg'), 'misc', 'busy-event', 'arm'])
            run = subprocess.run(command + [str(state), 'fixture', *extra], env=env, cwd=home,
                                 capture_output=True, text=True, timeout=30)
            assert run.returncode == 0, (label, extra, run.stdout, run.stderr)
            record = (state/'fixture.busy-state').read_text()
            generation = (state/'fixture.busy-gen').read_text().strip()
            assert 'gen='+generation in record and 'seq=1' in record, record
            for key, value in (('state', 'idle' if '--state' in extra else 'busy'),
                               ('source', 'fixture' if '--source' in extra else 'jg-spawn'),
                               ('event', 'fixture' if '--event' in extra else 'launch-brief')):
                assert key+'='+value in record, record
    # A real change through each entry point creates the same worker configuration.
    configs = []
    for label in ('direct', 'jg'):
        state = tmp/label/'state'; state.mkdir(parents=True)
        command = ([str(root/'bin/jg-devin-config.sh')] if label == 'direct'
                   else [str(root/'bin/jg'), 'home', 'devin-config'])
        run = subprocess.run(command + [str(state), 'fixture', 'generation'], env=env,
                             cwd=home, capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, (label, run.stderr, run.stdout)
        content = (state/'fixture.devin-config.json').read_text().replace(str(state), '<state>')
        configs.append(json.loads(content))
    assert configs[0] == configs[1], 'worker configuration differs through jg'
    # Preference changes use the documented no-push seam and stay in fixture homes.
    states = []
    for label in ('direct-pref', 'jg-pref'):
        ph = tmp/label
        for part in ('state', 'config', 'data', 'projects'):
            (ph/part).mkdir(parents=True)
        pe = dict(env, JG_HOME=str(ph), JG_STATE_OVERRIDE=str(ph/'state'),
                  JG_DATA_OVERRIDE=str(ph/'data'), JG_CONFIG_OVERRIDE=str(ph/'config'),
                  JG_PROJECTS_OVERRIDE=str(ph/'projects'), JG_PREF_NO_PUSH='1')
        command = ([str(root/'bin/jg-pref.sh'), 'set'] if label == 'direct-pref'
                   else [str(root/'bin/jg'), 'home', 'pref', 'set'])
        run = subprocess.run(command + ['peak-hours.utcHours', '10-12'], env=pe,
                             cwd=ph, capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, (label, run.stdout, run.stderr)
        states.append(digest(ph))
    assert states[0] == states[1] and states[0], 'preference changes differ through jg'
    # Compare independent copies for actions whose fixture cannot reach a worker or network.
    cases = [
        ('home home-seed validate', 'bin/jg-home-seed.sh', ['validate'], []),
        ('home pref validate', 'bin/jg-pref.sh', ['validate'], []),
        ('home update', 'bin/jg-update.sh', [], ['--help']),
        ('home update base', 'bin/jg-update.sh', [],
         ['--base', '0000000000000000000000000000000000000000', '--project', '/nonexistent-fixture', '--branch', 'fixture']),
        ('home update base', 'bin/jg-update.sh', [],
         ['--base', '0000000000000000000000000000000000000000', '--project', '/nonexistent-fixture', '--branch', 'fixture', '--home', '/nonexistent-lead']),
        ('misc claude-stop-autoarm', 'bin/jg-claude-stop-autoarm.sh', [], []),
        ('home lead-daemon start', 'bin/jg-lead-daemon.sh', ['start'], []),
        ('home pref swap', 'bin/jg-pref.sh', ['swap'], ['peak-hours', '/nonexistent-fixture']),
        ('home remote-inherit put', 'bin/jg-remote-inherit.sh', ['put'],
         ['not-allowlisted', '0', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', '1']),
        ('home remote-home-seed', 'bin/jg-remote-home-seed.sh', [],
         ['bad/id', 'fixture', '/missing-root', '/missing-home', '--no-projects']),
        ('home bootstrap install', 'bin/jg-bootstrap.sh', ['install'], ['invalid-fixture-tool']),
        ('home squad-lead-dormant sweep', 'bin/jg-squad-lead-dormant.sh', ['sweep'], []),
        ('home pref reset', 'bin/jg-pref.sh', ['reset'], ['peak-hours']),
        ('home role-pack', 'bin/jg-role-pack.sh', [], ['worker']),
        ('home tool-update-check arm', 'bin/jg-tool-update-check.sh', ['arm'], []),
        ('home tool-update-check disarm', 'bin/jg-tool-update-check.sh', ['disarm'], []),
        ('home lock status', 'bin/jg-lock.sh', ['status'], []),
        ('home migrate', 'bin/jg-migrate.sh', [], ['--home', '@home', '--check']),
        ('home migrate', 'bin/jg-migrate.sh', [], ['--home', '@home', '--check', '--slice', 'fixture']),
        ('home home-health verify', 'bin/jg-home-health.sh', ['verify'],
         ['/nonexistent-fixture', '0000000000000000000000000000000000000000', '--project', 'fixture', '--key', 'fixture']),
        ('home home-health pinback', 'bin/jg-home-health.sh', ['pinback'],
         ['/nonexistent-fixture', '--project', 'fixture', '--key', 'fixture', '--reason', 'fixture']),
        ('home squad-lead-dormant wake', 'bin/jg-squad-lead-dormant.sh', ['wake'], ['no-such-lead']),
        ('home squad-lead-dormant stop-idle', 'bin/jg-squad-lead-dormant.sh', ['stop-idle'], ['no-such-lead']),
        ('home remote-inherit absent', 'bin/jg-remote-inherit.sh', ['absent'],
         ['not-allowlisted', '0', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', '1']),
    ]
    for case_number, (path, script, prefix, args) in enumerate(cases):
        outcomes = []
        for label in ('d', 'j'):
            ph = tmp/('case-'+str(case_number)+'-'+label)
            for part in ('state', 'config', 'data', 'projects'):
                (ph/part).mkdir(parents=True)
            pe = dict(env, JG_HOME=str(ph), JG_STATE_OVERRIDE=str(ph/'state'),
                      JG_DATA_OVERRIDE=str(ph/'data'), JG_CONFIG_OVERRIDE=str(ph/'config'),
                      JG_PROJECTS_OVERRIDE=str(ph/'projects'), JG_PREF_NO_PUSH='1',
                      JG_ROOT_OVERRIDE=str(tmp/'empty-root'))
            command = ([str(root/script), *prefix] if label == 'd'
                       else [str(root/'bin/jg'), *path.split()])
            call_args = args[:1] + args[2:] if label == 'j' and path == 'home remote-inherit absent' else args
            run = subprocess.run(command + [str(ph) if a == '@home' else a for a in call_args],
                                 env=pe, cwd=ph, capture_output=True, text=True, timeout=30)
            if label == 'j':
                assert run.stdout, (path, run.returncode, run.stderr)
                data = json.loads(run.stdout)
                output = data['data'].get('stdout', '')
            else:
                output = run.stdout
            durable = digest(ph)
            if path == 'home update base' and (ph/'data/trunk-in-use.tsv').exists():
                row = (ph/'data/trunk-in-use.tsv').read_text().rstrip('\n').split('\t')
                assert row[2].isdigit(), row
                row[2] = '<time>'
                durable['data/trunk-in-use.tsv'] = '\t'.join(row)
            outcomes.append((run.returncode, output.replace(str(ph), '<home>'),
                             run.stderr.replace(str(ph), '<home>'), durable))
        assert outcomes[0] == outcomes[1], (path, outcomes)
    # A stand-in producer keeps summary refresh independent of live homes.
    producer = tmp/'producer'
    producer.write_text("#!/bin/sh\njq -nc --arg home \"$JG_HOME\" "
        "'{schema:\"jg-squad-lead-home-summary.v1\",hold_classifier_schema:\"jg-captain-hold-buckets.v1\","
        "home:$home,generated:\"fixture\",generated_epoch:1,valid:true,state:\"idle\",invalidity:{},"
        "active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],counts:{},omitted:[]}'\n")
    producer.chmod(0o755)
    for best, direct_flag in ((False, False), (True, False), (True, True)):
        summaries = []
        for label in ('direct', 'jg'):
            sh = tmp/('summary-'+str(best)+'-'+str(direct_flag)+'-'+label)
            for part in ('state', 'config', 'data', 'projects'):
                (sh/part).mkdir(parents=True)
            se = dict(env, JG_HOME=str(sh), JG_STATE_OVERRIDE=str(sh/'state'), JG_DATA_OVERRIDE=str(sh/'data'),
                      JG_CONFIG_OVERRIDE=str(sh/'config'), JG_PROJECTS_OVERRIDE=str(sh/'projects'),
                      JG_HOME_SUMMARY_PRODUCER=str(producer), JG_HOME_SUMMARY_FOREGROUND='1',
                      JG_ROOT_OVERRIDE=str(tmp/'empty-root'))
            command = ([str(root/'bin/jg-home-summary-refresh.sh')] + (['--best-effort'] if best else [])
                       if label == 'direct' else [str(root/'bin/jg'), 'home', 'home-summary-refresh']
                       + (['--best-effort'] if direct_flag else ['best-effort'] if best else []))
            run = subprocess.run(command, env=se, cwd=sh, capture_output=True, text=True, timeout=30)
            assert run.returncode == 0, (label, best, run.stdout, run.stderr)
            ledger = json.loads((sh/'state/home-summary.json').read_text())
            ledger['home'] = '<home>'
            summaries.append(ledger)
        assert summaries[0] == summaries[1], ('summary mismatch', best)
    # The verify script accepts check options although its inventory form abbreviates them.
    health_args = ['/nonexistent-fixture', '0'*40, '--project', 'fixture', '--key', 'fixture', '--grace', '1']
    health = subprocess.run([str(root/'bin/jg-home-health.sh'), 'verify', *health_args], env=env,
                            cwd=home, capture_output=True, text=True, timeout=30)
    assert 'unknown option --grace' not in health.stderr, health.stderr
    health_jg = subprocess.run([str(root/'bin/jg'), 'home', 'home-health', 'verify', *health_args],
                               env=env, cwd=home, capture_output=True, text=True, timeout=30)
    assert health_jg.returncode == 2 and 'unknown option --grace' in health_jg.stderr
    # This historical form names an optional operand without angle brackets.
    # The direct script accepts it; the dispatcher gap is retained for the owner.
    project = tmp/'project'; project.mkdir()
    direct = subprocess.run([str(root/'bin/jg-ensure-agents-md.sh'), str(project)], env=env,
                            cwd=home, capture_output=True, text=True)
    assert direct.returncode == 0 and (project/'AGENTS.md').is_file(), direct.stderr
    dispatched = subprocess.run([str(root/'bin/jg'), 'home', 'ensure-agents-md', str(project)],
                                env=env, cwd=home, capture_output=True, text=True)
    assert dispatched.returncode == 2 and 'unexpected argument' in dispatched.stderr
print('e6homes: contract coverage, help, read-only fixtures and optional operand gap passed')
PY
