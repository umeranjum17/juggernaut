#!/usr/bin/env bash
# Integration: notification contract coverage and safe command parity on isolated homes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
python3 - "$ROOT" <<'PY'
import csv, hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]); contract=root/'core/agent-cli/contract/e6radio2.json'
f=json.loads(contract.read_text()); rows=[r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(),delimiter='\t') if r['owner']=='e6radio2']
entries={(e['script'].removeprefix('bin/'),e['operation']):e for e in f['entries']}; dropped={(e['script'].removeprefix('bin/'),e['operation']):e for e in f['dropped']}
assert len(entries)==len(f['entries']) and len(dropped)==len(f['dropped'])
assert set(entries).isdisjoint(dropped) and set(entries)|set(dropped)=={(r['script'],r['operation']) for r in rows}
for r in rows:
 k=(r['script'],r['operation'])
 if k in dropped:
  assert r['review']=='pending' and dropped[k]['reason']; continue
 e=entries[k]; assert e['form']==r['form'] and ' '.join(e['path'])==r['path'] and e['method']==r['method']
subprocess.run(['bash',str(root/'core/agent-cli/dispatch.sh'),'check'],check=True)
helptext=subprocess.check_output([str(root/'bin/jg'),'help'],text=True)
for e in entries.values(): assert 'jg '+' '.join(e['path'])+' - '+e['meaning'] in helptext
# Dangerous long-lived, startup, network and remote actions are checked only at their parser boundary.
# Each remaining case uses two fresh homes. Direct output is compared to the jg envelope.
cases={
 ('jg-machine-guard.sh','edge'):['fixture','old','new'],
 ('jg-machine-guard.sh','flip'):['fixture','1'],
 ('jg-machine-guard.sh','enforced'):['fixture'],
 ('jg-machine-guard.sh','fact'):['reuse'],
 ('jg-path-guard.sh','-'):['--mask','hello'],
 ('jg-startup-growth-check.sh','arm'):[],
 ('jg-startup-growth-check.sh','disarm'):[],
 ('jg-startup-memory-budget.sh','read'):[],
 ('jg-startup-memory-budget.sh','report'):[],
 ('jg-startup-network.sh','report'):[],
 ('jg-startup-network.sh','wait'):['0'],
 ('jg-subagent-pretool-check.sh','-'):[],
 ('jg-subagent-pretool-check.sh','--tool'):['example'],
 ('jg-sessionstart-agy.sh','-'):[],
}
def digest(home):
 return {str(p.relative_to(home)):hashlib.sha256(p.read_bytes().replace(str(home).encode(),b'HOME')).hexdigest() for p in home.rglob('*') if p.is_file()}
with tempfile.TemporaryDirectory(prefix='e6radio2-') as td:
 t=pathlib.Path(td)
 def home(name):
  h=t/name
  for d in ('config','data','state','projects','tmp'): (h/d).mkdir(parents=True)
  (h/'config/startup-memory-budget').write_text('10000\n')
  (h/'data/captain.md').write_text('fixture\n')
  return h
 def run(h,argv):
  env={**os.environ,'HOME':str(h),'TMPDIR':str(h/'tmp'),'JG_HOME':str(h),'JG_STATE_OVERRIDE':str(h/'state'),'JG_DATA_OVERRIDE':str(h/'data'),'JG_CONFIG_OVERRIDE':str(h/'config'),'JG_PROJECTS_OVERRIDE':str(h/'projects')}
  return subprocess.run(argv,env=env,cwd=h,input='',text=True,capture_output=True,timeout=25)
 for key,args in cases.items():
  e=entries[key]; a=home(key[0]+key[1]); snapshot=t/'snapshot'; shutil.copytree(a,snapshot); beforea=digest(a)
  op=[] if key[1]=='-' else [key[1]]
  direct=run(a,[str(root/'bin'/key[0]),*op,*args]); aftera=digest(a)
  shutil.rmtree(a); shutil.copytree(snapshot,a); shutil.rmtree(snapshot); beforeb=digest(a)
  via=run(a,[str(root/'bin/jg'),*e['path'],*args]); afterb=digest(a)
  try: payload=json.loads(via.stdout)
  except ValueError: raise AssertionError(f'{key}: jg did not return JSON: {via.stderr}')
  assert direct.returncode==via.returncode, (key,direct.returncode,via.returncode,direct.stderr,via.stderr)
  try: expected=json.loads(direct.stdout)
  except ValueError: expected={'stdout':direct.stdout}
  if direct.returncode: expected['error']=direct.stderr
  assert payload['data']==expected, (key,direct.stdout,payload)
  if e['method']=='GET': assert aftera==beforea and afterb==beforeb, key
  else: assert aftera==afterb, (key,aftera,afterb)
 # Safe argument checks for commands that can start a worker, reach a host or run a long-lived process.
 for key in (('jg-session-start.sh','-'),('jg-startup-network.sh','start'),('jg-startup-network.sh','run'),('jg-supervise-daemon.sh','-'),('jg-supervision-host.sh','park')):
  h=home(key[0]+key[1]+'-boundary'); e=entries[key]
  rejected=run(h,[str(root/'bin/jg'),*e['path'],'--unrecognised-fixture'])
  assert rejected.returncode==2 and 'unknown option' in rejected.stderr, (key,rejected.stderr)
 # The optional flag and optional positional ID must arrive at the real parsers.
 h=home('options'); x=run(h,[str(root/'bin/jg'),'radio','machine-guard','edge','fixture','old','new','fixture-id']); assert x.returncode==0, x.stderr
 x=run(h,[str(root/'bin/jg'),'radio','subagent-pretool-check','tool','example','--claude']); assert x.returncode==0, x.stderr
 x=run(h,[str(root/'bin/jg'),'radio','on','--stdin','missing','jg-path-guard.sh']); assert x.returncode==1 and 'no remote' in x.stderr, x.stderr
 # The variadic dispatcher defect is tracked separately: the direct parser accepts the value.
 h=home('remote'); direct=run(h,[str(root/'bin/jg-on.sh'),'missing','jg-path-guard.sh','example'])
 assert direct.returncode==1 and 'no remote' in direct.stderr
 via=run(h,[str(root/'bin/jg'),'radio','on','missing','jg-path-guard.sh','example'])
 if via.returncode==2: assert 'unexpected argument example' in via.stderr
 # Pending fake operations are input text, while no-argument sentinel is usage.
 for value in ('0','1'):
  assert run(h,[str(root/'bin/jg-lavish-guard.sh'),value]).returncode==0
 sentinel=run(h,[str(root/'bin/jg-sentinel.sh')]); assert sentinel.returncode==2 and 'Usage' in sentinel.stderr
print('e6radio2: coverage, safe parity, read-only digests and dispatcher-gap evidence passed')
PY
