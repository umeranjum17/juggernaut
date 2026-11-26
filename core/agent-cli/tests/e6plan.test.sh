#!/usr/bin/env bash
# Integration checks for the planning command fragment on isolated homes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
. "$ROOT/tests/wake-helpers.sh"
T=$(jg_test_tmproot e6plan)
export ROOT T
python3 -I - <<'PY'
import csv, json, os, pathlib, subprocess, hashlib, shutil
root=pathlib.Path(os.environ['ROOT']); t=pathlib.Path(os.environ['T'])
rows=[r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(),delimiter='\t') if r['owner']=='e6plan']
frag=json.loads((root/'core/agent-cli/contract/e6plan.json').read_text())
entries=frag['entries']; assert len(rows)==13 and len(entries)==len(rows)
for row in rows:
    found=[e for e in entries if e['script']=='bin/'+row['script'] and e['operation']==row['operation']]
    assert len(found)==1, row
    e=found[0]
    assert e['form']==row['form'] and ' '.join(e['path'])==row['path'] and e['method']==row['method'], row
helpout=subprocess.check_output([root/'bin/jg','help'],text=True)
for e in entries: assert 'jg '+' '.join(e['path'])+' - '+e['meaning'] in helpout
subprocess.run(['bash',root/'core/agent-cli/dispatch.sh','check'],check=True)
# Arguments reach the real parsers, and POST paths have the same output and file effects.
cases={
 ('jg-plan-gate.sh','add'):['missing','--tool','missing','--min','1'],
 ('jg-plan-gate.sh','close'):[],
 ('jg-plan-gate.sh','approve'):['missing.json','--harness','codex','--model','fixture','--effort','low'],
 ('jg-plan-route.sh','-'):['missing.json'],
 ('jg-swarm-arm.sh','-'):['missing.json'],
 ('jg-swarm-check.sh','status'):['missing'],
 ('jg-swarm-check.sh','check'):['HOME'],
 ('jg-swarm-plan-check.sh','-'):['missing.json'],
 ('jg-swarm-plan-check.sh','--ref'):['missing.json','--repo','REPO','--ref','HEAD'],
 ('jg-swarm-words.sh','-'):['HOME'],
 ('jg-swarm.sh','run'):['missing.json','--harness','codex','--model','fixture','--effort','low'],
 ('jg-war-room.sh','next'):['missing'],
 ('jg-war-room.sh','approve'):['missing','--words','yes'],
}
def digest(home):
    return [(str(p.relative_to(home)),hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(home.rglob('*')) if p.is_file()]
def run(e,args,dispatch,tag):
    home=t/tag/'home'; home.mkdir(parents=True)
    for d in ('state','data','config','projects'): (home/d).mkdir()
    env=dict(os.environ,HOME=str(t/tag),JG_HOME=str(home),JG_STATE_OVERRIDE=str(home/'state'),JG_DATA_OVERRIDE=str(home/'data'),JG_CONFIG_OVERRIDE=str(home/'config'),JG_SWARM_ARM_KICK='0')
    args=[str(home) if a=='HOME' else str(root) if a=='REPO' else a for a in args]
    before=digest(home)
    cmd=[str(root/'bin/jg'),*e['path'],*args] if dispatch else [str(root/e['script']),*args]
    result=subprocess.run(cmd,env=env,cwd=t/tag,text=True,capture_output=True)
    after=digest(home)
    if e['method']=='GET': assert before==after, (e['path'],before,after)
    if dispatch:
        try: envelope=json.loads(result.stdout)
        except ValueError: raise AssertionError((cmd,result.stdout,result.stderr))
        assert 'schema' in envelope, (cmd,result.stderr)
    return result,after
variants={('jg-plan-route.sh','-'):[['--dry-run']], ('jg-swarm-arm.sh','-'):[['--agents','2'],['--with-others']], ('jg-swarm-check.sh','status'):[['--short']], ('jg-swarm-plan-check.sh','-'):[['--repo','REPO','--ref','HEAD']], ('jg-swarm.sh','run'):[['--order','Main1'],['--agents','2'],['--with-others'],['--wait']], ('jg-war-room.sh','approve'):[['--by','tester']]}
for i,e in enumerate(entries):
    key=(e['script'].split('/')[-1],e['operation']); args=cases[key]
    # Script literals are supplied by the dispatcher; invoke the direct script in its documented form.
    literal={'add':['add'],'close':['close'],'approve':['approve'],'status':['status'],'check':['check'],'run':['run'],'next':['next']}.get(e['operation'],[])
    a,da=run(e,args,True,'jg'+str(i)); b,db=run(e,literal+args,False,'direct'+str(i))
    assert a.returncode==b.returncode, (key,a.returncode,b.returncode,a.stderr,b.stderr)
    assert da==db, (key,da,db)
    payload=json.loads(a.stdout)['data']
    output=payload.get('stdout', '') if isinstance(payload,dict) else payload
    normalize=lambda s: s.replace(str(t/('jg'+str(i))/'home'),'HOME').replace(str(t/('direct'+str(i))/'home'),'HOME')
    assert normalize(output)==normalize(b.stdout), (key,output,b.stdout)
    assert normalize(a.stderr)==normalize(b.stderr), (key,a.stderr,b.stderr)
    assert 'usage:' not in b.stderr.lower(), (key,b.stderr)
    for j,extra in enumerate(variants.get(key,[])):
        x,_=run(e,args+extra,True,f'variant{i}-{j}')
        y,_=run(e,literal+args+extra,False,f'variant-direct{i}-{j}')
        assert x.returncode==y.returncode and 'usage:' not in y.stderr.lower(), (key,extra,x.stderr,y.stderr)
print('planning contract: inventory, help, parsing, read-only and parity passed')
PY
