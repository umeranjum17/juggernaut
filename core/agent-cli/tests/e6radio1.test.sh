#!/usr/bin/env bash
# Exercise notification routes against their scripts in isolated homes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, re, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6radio1']
fragment = json.loads((root/'core/agent-cli/contract/e6radio1.json').read_text())
entries = fragment['entries']
assert len(rows) == len(entries) == 34
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

cases = {
 ('jg-afk-contract.sh','enter'): [], ('jg-afk-contract.sh','readback'): [],
 ('jg-afk-contract.sh','mode'): [], ('jg-afk-contract.sh','field'): ['mode'],
 ('jg-afk-contract.sh','words'): [], ('jg-afk-contract.sh','validate'): [],
 ('jg-afk-contract.sh','archive'): [], ('jg-afk-contract.sh','archived'): ['123'],
 ('jg-afk-launch.sh','enter'): [], ('jg-afk-launch.sh','start'): [],
 ('jg-afk-launch.sh','start-native'): [], ('jg-afk-launch.sh','stop'): [],
 ('jg-afk-launch.sh','reconcile'): [], ('jg-afk-launch.sh','quiet-check'): [],
 ('jg-afk-return.sh','begin'): [], ('jg-afk-return.sh','check'): [],
 ('jg-afk-return.sh','guard'): [], ('jg-afk-return.sh','catchup-summary'): [],
 ('jg-afk-start.sh','-'): [], ('jg-arm-pretool-check.sh','-'): [],
 ('jg-arm-pretool-check.sh','--command'): ['echo fixture'],
 ('jg-beat.sh','append'): ['STATE','task1','Stop'], ('jg-bus.sh','-'): [],
 ('jg-check-register.sh','-'): ['fixture'], ('jg-check-unregister.sh','-'): ['fixture'],
 ('jg-fleet-heartbeat.sh','check'): [], ('jg-fleet-heartbeat.sh','arm'): [],
 ('jg-guard.sh','-'): [], ('jg-home-guard.sh','install'): ['MISSING'],
 ('jg-home-guard.sh','refresh'): ['MISSING'], ('jg-home-guard.sh','check'): ['MISSING'],
 ('jg-home-guard.sh','uninstall'): ['MISSING'], ('jg-hook.sh','-'): ['Fixture','STATE','task1'],
 ('jg-host-wiring.sh','-'): ['MISSING'],
}
options = {
 ('jg-afk-contract.sh','enter'): [['--words-file','MISSING'],['--words','fixture']],
 ('jg-afk-launch.sh','enter'): [['--words-file','MISSING'],['--words','fixture'],['--expected-return','2030-01-01T00:00Z'],['--spend','2']],
 ('jg-beat.sh','append'): [['timeout']],
 ('jg-arm-pretool-check.sh','--command'): [['--background','false']],
 ('jg-host-wiring.sh','-'): [['--dry-run']],
 ('jg-home-guard.sh','install'): [['--tip','abc123'],['--pre','abc123']],
}
for op in ('mode','field','words','validate'):
    options[('jg-afk-contract.sh',op)] = [['--path','MISSING']]
def normalize(value, home):
    value = value.replace(str(home), '<home>')
    value = re.sub(r'\b\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\b', '<time>', value)
    return re.sub(r'\b1[0-9]{9}\b', '<epoch>', value)
def digest(home):
    files = {}
    for p in home.rglob('*'):
        if not p.is_file():
            continue
        value = p.read_text(errors='replace')
        if p.name.endswith('.check-trust'):
            check = p.with_name(p.name[:-6] + '.sh')
            lines = value.splitlines()
            assert lines == ['jg-custom-check-v1', hashlib.sha256(check.read_bytes()).hexdigest()]
            value = 'valid check trust'
        files[normalize(str(p.relative_to(home)), home)] = normalize(value, home)
    return files
with tempfile.TemporaryDirectory(prefix='e6radio1-', dir=os.environ.get('JG_E6RADIO_TMP')) as tmp:
    tmp = pathlib.Path(tmp)
    # Existing bus seam: this is a harmless stand-in, never the real bus or network.
    bus = tmp/'bus'; bus.write_text('#!/bin/sh\nprintf "fixture bus\\n"\n'); bus.chmod(0o755)
    index = 0
    for e in entries:
        key = (pathlib.Path(e['script']).name,e['operation'])
        assert key in cases, key
        for extra in [[]] + options.get(key, []):
            index += 1
            results = []
            for name in ('direct','jg'):
                home = tmp/str(index)/name
                for part in ('state','config','data','projects'):
                    (home/part).mkdir(parents=True, exist_ok=True)
                env = dict(os.environ, HOME=str(tmp), XDG_CONFIG_HOME=str(tmp/'xdg-config'), XDG_DATA_HOME=str(tmp/'xdg-data'),
                    TMPDIR=str(tmp), JG_HOME=str(home), JG_ROOT_OVERRIDE=str(tmp/'root'),
                    JG_STATE_OVERRIDE=str(home/'state'), JG_DATA_OVERRIDE=str(home/'data'),
                    JG_CONFIG_OVERRIDE=str(home/'config'), JG_AFK_STATE_PREPARED='1', JG_TEST_HARNESS='pi', JG_BUS_BIN=str(bus))
                args = [str(home/'state') if x == 'STATE' else str(tmp/'missing') if x == 'MISSING' else x for x in cases[key]+extra]
                command = [str(root/e['script'])] + ([] if e['operation'] == '-' else [e['operation']]) if name == 'direct' else [str(root/'bin/jg'), *e['path']]
                before = digest(home)
                result = subprocess.run(command+args, env=env, input='', text=True, capture_output=True, timeout=20)
                results.append((result,before,digest(home),str(home)))
            (direct, db, da, dh), (actual, jb, ja, jh) = results
            try: envelope = json.loads(actual.stdout)
            except ValueError: raise AssertionError((e['form'],extra,actual.returncode,actual.stdout,actual.stderr))
            assert actual.returncode == (direct.returncode if direct.returncode in (0,1,2,3) else 1), (e['form'],extra,direct.returncode,actual.returncode,direct.stderr,actual.stderr)
            assert 'usage:' not in direct.stderr.lower(), (e['form'], extra, direct.stderr)
            assert envelope['ok'] == (direct.returncode == 0), (e['form'],extra,envelope)
            assert normalize(actual.stderr,jh) == normalize(direct.stderr,dh), (e['form'],extra,direct.stderr,actual.stderr)
            assert normalize(envelope['data'].get('stdout',''),jh) == normalize(direct.stdout,dh), (e['form'],extra,direct.stdout,envelope)
            assert db == jb and da == ja, (e['form'],extra,'durable results differ',da,ja)
            if e['method'] == 'GET':
                assert db == da and jb == ja, (e['form'],'GET changed home')
print('e6radio1: 34 operations and isolated script parity passed')
PY
