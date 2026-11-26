#!/usr/bin/env bash
# Exercise outside-channel routes with isolated homes and relay dry runs.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6relay3']
f = json.loads((root/'core/agent-cli/contract/e6relay3.json').read_text())
entries, dropped = f['entries'], f['dropped']
assert len(rows) == len(entries) + len(dropped)
for row in rows:
    matches = [e for e in entries + dropped if (e['script'], e['operation']) == ('bin/'+row['script'], row['operation'])]
    assert len(matches) == 1, row
    e = matches[0]
    if 'reason' in e:
        assert row['review'] == 'pending' and e['run'] and e['reason']
        continue
    assert e['path'] == row['path'].split() and e['method'] == row['method']
    assert e['form'] == row['form'] or row['operation'] == 'rechain'
    assert e['aliases'] == ([] if row['aliases'] == '-' else row['aliases'].split(','))
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext
cases = {
 ('jg-public-followup.sh','active'): [],
 ('jg-public-followup.sh','register'): ['fixture','--relation','relation','--work-home','main','--work-id','missing','--generation','1'],
 ('jg-public-followup.sh','brief'): ['fixture'],
 ('jg-public-followup.sh','consume'): [], ('jg-public-followup.sh','pending'): [],
 ('jg-public-followup.sh','deliver'): ['fixture'],
 ('jg-public-followup.sh','record-posted'): ['fixture','--attempt','1','--chunks','1'],
 ('jg-public-followup.sh','guard-work'): ['main','missing'],
 ('jg-public-followup.sh','rechain'): ['fixture','--from','source','--work-home','main','--work-id','missing','--expected','report-ready'],
 ('jg-public-followup.sh','retire'): ['fixture','--reason','fixture'],
 ('jg-x-dismiss.sh','-'): ['request'], ('jg-x-followup.sh','-'): ['missing','--text-file','TEXT'],
 ('jg-x-link.sh','-'): ['missing','request'],
 ('jg-x-link.sh','--carry-ts'): ['missing','request','--carry-count','1','--carry-ts','1'],
 ('jg-x-reply.sh','-'): ['request','fixture reply'],
}
options = {
 ('jg-public-followup.sh','register'): [['--platform','x'],['--request','request']],
 ('jg-public-followup.sh','deliver'): [['--text-file','TEXT']],
 ('jg-public-followup.sh','rechain'): [['--deliverable-key','report_path']],
 ('jg-public-followup.sh','retire'): [['--force']],
 ('jg-x-followup.sh','-'): [['--image','TEXT'],['--final']],
 ('jg-x-link.sh','-'): [['--carry-count','1','--carry-ts','1'], ['--carry-count','1','--carry-ts','1','--carry-platform','x'], ['--carry-count','1','--carry-ts','1','--carry-max','280']],
 ('jg-x-link.sh','--carry-ts'): [['--carry-platform','x'],['--carry-max','280']],
 ('jg-x-reply.sh','-'): [['--followup'],['--image','TEXT'],['--receipt-file','RECEIPT']],
}
def digest(home):
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
with tempfile.TemporaryDirectory(prefix='jg-e6relay3-') as tmp:
    tmp = pathlib.Path(tmp)
    textfile = tmp/'message'; textfile.write_text('fixture reply\n')
    for e in entries:
        key = (pathlib.Path(e['script']).name,e['operation'])
        assert key in cases, key
        variants=[cases[key]+extra for extra in [[]] + options.get(key, [])]
        if key == ('jg-x-reply.sh','-'):
            variants.append(['request','--text-file','TEXT'])
        for index, variant in enumerate(variants):
            results=[]
            for mode in ('direct','jg'):
                home=tmp/('fixture-'+str(entries.index(e))+'-'+str(index))/mode
                for part in ('state','data','config','projects'): (home/part).mkdir(parents=True)
                env=dict(os.environ, HOME=str(tmp), TMPDIR=str(tmp), JG_HOME=str(home), JG_ROOT_OVERRIDE=str(tmp/'root'), JG_STATE_OVERRIDE=str(home/'state'), JG_DATA_OVERRIDE=str(home/'data'), JG_CONFIG_OVERRIDE=str(home/'config'), FMX_PAIRING_TOKEN='', FMX_DRY_RUN='1')
                args=[str(textfile) if v=='TEXT' else str(home/'receipt') if v=='RECEIPT' else v for v in variant]
                cmd=([str(root/e['script'])] + ([] if e['operation'] in ('-','--carry-ts') else [e['operation']])) if mode=='direct' else [str(root/'bin/jg'),*e['path']]
                before=digest(home)
                result=subprocess.run(cmd+args,env=env,text=True,capture_output=True,timeout=20)
                results.append((result,before,digest(home),str(home)))
            (direct,db,da,dh),(jg,jb,ja,jh)=results
            assert 'usage:' not in direct.stderr.lower(), (key,variant,direct.stderr)
            try: envelope=json.loads(jg.stdout)
            except ValueError as exc:
                raise AssertionError((key,variant,jg.stderr)) from exc
            norm=lambda s,h:s.replace(h,'<home>')
            if norm(jg.stderr,jh)!=norm(direct.stderr,dh) or jg.returncode != (direct.returncode if direct.returncode in (0,1,2,3) else 1) or da != ja:
                raise AssertionError((key,variant,direct.returncode,jg.returncode,direct.stderr,jg.stderr,da,ja))
            assert db==jb and envelope['ok']==(direct.returncode==0)
            assert norm(envelope['data'].get('stdout',''),jh)==norm(direct.stdout,dh)
            if e['method']=='GET': assert db==da
    for d in dropped:
        env=dict(os.environ,HOME=str(tmp),JG_HOME=str(tmp),FMX_PAIRING_TOKEN='')
        result=subprocess.run([str(root/d['script']),d['operation']],env=env,text=True,capture_output=True,timeout=20)
        assert result.returncode==0 and not result.stdout and not result.stderr, d
print('e6relay3: isolated direct calls and dispatch comparison complete')
PY
