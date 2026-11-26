#!/usr/bin/env bash
# Exercise the process-event contract on isolated homes, through both public interfaces.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
exec python3 - "$ROOT" <<'PY'
import csv, hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]); contract=root/'core/agent-cli/contract/e6relay2.json'
assert contract.is_file(), 'e6relay2 contract missing'
c=json.loads(contract.read_text()); rows=[r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(),delimiter='\t') if r['owner']=='e6relay2']
assert c['owner']=='e6relay2'
assert len(c['entries'])==len(rows)
bykey={(e['script'].removeprefix('bin/'),e['operation']):e for e in c['entries']}
assert len(bykey)==len(rows)
for r in rows:
 e=bykey[(r['script'],r['operation'])]
 assert e['form']==r['form'] and e['path']==r['path'].split() and (e['method']==r['method'] or (r['operation']=='list' and e['method']=='POST')), r
subprocess.run(['bash',str(root/'core/agent-cli/dispatch.sh'),'check'],check=True)
helptext=subprocess.check_output([str(root/'bin/jg'),'help'],text=True)
for e in c['entries']: assert 'jg '+' '.join(e['path'])+' - '+e['meaning'] in helptext
args={
 ('jg-procevent-when.sh','arm'):['bad/name','--condition','/bin/true','--action','/bin/true'],
 ('jg-procevent-when.sh','classify'):['RESULT'], ('jg-procevent-when.sh','terminal'):['RESULT'],
 ('jg-procevent-when.sh','source-id'):['sample'], ('jg-procevent-when.sh','retire'):['missing'],
 ('jg-procevent-when.sh','rebind-all'):[], ('jg-procevent-when.sh','run'):['missing'],
 ('jg-procevent.sh','register'):['invalid','missing','--','/bin/true'],
 ('jg-procevent.sh','register-task'):['invalid','missing','missing','--','/bin/true'],
 ('jg-procevent.sh','register-extension'):['invalid','missing','--config-ref','fixture'],
 ('jg-procevent.sh','start'):['missing'], ('jg-procevent.sh','ensure-listening'):['missing'],
 ('jg-procevent.sh','reconcile'):[], ('jg-procevent.sh','classify'):['RESULT'],
 ('jg-procevent.sh','handled'):['missing','1'], ('jg-procevent.sh','retire'):['missing'],
 ('jg-procevent.sh','sweep-home'):[], ('jg-procevent.sh','binding-retirement-preflight'):['fixture'],
 ('jg-procevent.sh','extension-retirement'):['binding','fixture'],
 ('jg-procevent.sh','extension-bind'):['bind','fixture'],
 ('jg-procevent.sh','extension-process-event'):['fixture'], ('jg-procevent.sh','list'):[]}
assert set(args)==set(bykey)
def digest(home):
 return {str(p.relative_to(home)):hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file() and '.lock.owner.' not in str(p)}
with tempfile.TemporaryDirectory(prefix='e6relay2-') as t:
 t=pathlib.Path(t)
 for key,e in bykey.items():
  homes=[t/'direct',t/'jg']; outputs=[]
  for home in homes:
   if home.exists(): shutil.rmtree(home)
   for part in ('state','config','data','tmp'): (home/part).mkdir(parents=True)
   result=home/'result'; result.write_text('status: fired\noutput:\n')
   env=os.environ.copy(); env.update(HOME=str(home),TMPDIR=str(home/'tmp'),JG_HOME=str(home),JG_STATE_OVERRIDE=str(home/'state'),JG_DATA_OVERRIDE=str(home/'data'),JG_CONFIG_OVERRIDE=str(home/'config'))
   argv=[str(result) if x=='RESULT' else x for x in args[key]]
   if key==('jg-procevent.sh','list'):
    fixture=subprocess.run([str(root/'bin/jg-procevent.sh'),'register','when','fixture','--','/bin/true'],env=env,capture_output=True,text=True)
    assert fixture.returncode==0, fixture.stderr
   before=digest(home)
   cmd=([str(root/'bin'/key[0]),key[1]] if home.name=='direct' else [str(root/'bin/jg'),*e['path']])+argv
   p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=15)
   assert 'usage:' not in p.stderr.lower() and 'usage:' not in p.stdout.lower(), (key,cmd,p.stderr,p.stdout)
   if e['method']=='GET': assert digest(home)==before, (key,'GET changed home')
   if key==('jg-procevent.sh','list'):
    assert digest(home)!=before, 'list should refresh the owner lease in a populated home'
   after=digest(home); after.pop('result',None)
   if 'state/procevent/.owner-lease' in after: after['state/procevent/.owner-lease']='monotonic timestamp'
   outputs.append((p,after))
  direct,via=outputs
  assert direct[0].returncode==via[0].returncode, (key,direct[0].returncode,via[0].returncode,via[0].stderr)
  assert direct[1]==via[1], (key,'durable effects differ',direct[1],via[1])
  envelope=json.loads(via[0].stdout); assert envelope['data'].get('stdout','')==direct[0].stdout or not direct[0].stdout, key
 # Each optional arm option reaches the real parser with no worker started.
 home=t/'options'; [ (home/part).mkdir(parents=True,exist_ok=True) for part in ('state','data','config','tmp') ]
 env=os.environ.copy(); env.update(HOME=str(home),TMPDIR=str(home/'tmp'),JG_HOME=str(home),JG_STATE_OVERRIDE=str(home/'state'),JG_DATA_OVERRIDE=str(home/'data'),JG_CONFIG_OVERRIDE=str(home/'config'))
 for option in [None,'--interval','--stable','--deadline','--condition-timeout','--action-timeout','--error-budget']:
  argv=['arm','watch']+([option,'1'] if option else [])+['--condition','/bin/true','--action','/does-not-exist']
  for cmd in ([str(root/'bin/jg-procevent-when.sh'),*argv],[str(root/'bin/jg'),'relay','procevent-when',*argv]):
   p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=15)
   assert p.returncode==1 and 'action executable is unavailable: /does-not-exist' in p.stderr, (cmd,p.stdout,p.stderr)
 for option in [[],['--if-absent'],['--if-owner','fixture'],['--if-matches','invalid','--','/bin/true']]:
  for cmd in ([str(root/'bin/jg-procevent.sh'),'retire','missing',*option],[str(root/'bin/jg'),'relay','procevent','retire','missing',*option]):
   p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=15)
   assert 'usage:' not in (p.stdout+p.stderr).lower() and 'unknown option' not in p.stderr.lower(), (cmd,p.stdout,p.stderr)
 for cmd in ([str(root/'bin/jg-procevent.sh'),'sweep-home','--preflight'],[str(root/'bin/jg'),'relay','procevent','sweep-home','--preflight']):
  p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=15)
  assert 'usage:' not in (p.stdout+p.stderr).lower(), (cmd,p.stdout,p.stderr)
 for n in ('0','1','2'):
  p=subprocess.run([str(root/'bin/jg-procevent.sh'),n],env=env,capture_output=True,text=True)
  assert p.returncode and 'unknown command: '+n in p.stderr
 assert {d['operation'] for d in c['dropped']}=={'0','1','2'}
print('ok - process-event contract and isolated command parity')
PY
