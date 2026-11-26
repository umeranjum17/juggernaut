#!/usr/bin/env bash
# Exercise the worker command fragment against the real scripts in isolated fixture homes.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
python3 -I - "$ROOT" <<'PY'
import csv, hashlib, importlib.util, json, os, re, sqlite3, subprocess, sys, tempfile
root=sys.argv[1]
spec=importlib.util.spec_from_file_location('parse',root+'/core/agent-cli/inventory/parse.py')
p=importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
contract=json.load(open(root+'/core/agent-cli/contract/e6crew1.json'))
rows=[r for r in csv.DictReader(open(root+'/core/agent-cli/operations.tsv'),delimiter='\t') if r['owner']=='e6crew1']
entries={(e['script'].removeprefix('bin/'),e['operation']):e for e in contract['entries']}
dropped={(e['script'].removeprefix('bin/'),e['operation']):e for e in contract['dropped']}
assert len(entries)+len(dropped)==len(rows)
assert set(entries)|set(dropped)=={(r['script'],r['operation']) for r in rows}
assert not set(entries)&set(dropped)
for d in dropped.values(): assert d['reason'] and d['run']
subprocess.run(['bash',root+'/core/agent-cli/dispatch.sh','check'],check=True)
helptext=subprocess.check_output([root+'/bin/jg','help'],text=True)
for r in rows:
 k=(r['script'],r['operation'])
 if k in entries:
  e=entries[k]
  assert e['form']==r['form'],k
  assert e['path']==r['path'].split(),k
  assert 'jg '+' '.join(e['path'])+' - '+e['meaning'] in helptext,k
def snapshot(path):
 result={}
 for base, dirs, files in os.walk(path):
  dirs.sort()
  for name in sorted(files):
   file=os.path.join(base,name)
   if os.path.islink(file): result[os.path.relpath(file,path)]=('link',os.readlink(file))
   elif os.path.relpath(file,path)=='state/kv.db':
    db=sqlite3.connect('file:'+file+'?mode=ro',uri=True)
    records=db.execute('select bucket,key,value,revision from kv order by bucket,key').fetchall()
    db.close()
    result[os.path.relpath(file,path)]=records
   else:
    with open(file,'rb') as f: data=f.read()
    if os.path.relpath(file,path)=='data/primary-relaunches.tsv':
     data=re.sub(rb'(?m)^\d+\t',b'<epoch>\t',data)
    result[os.path.relpath(file,path)]=hashlib.sha256(data).hexdigest()
 return result

def remove_operation(argv, operation):
 if operation=='-': return argv
 words=operation.split()
 for i in range(len(argv)-len(words)+1):
  if argv[i:i+len(words)]==words: return argv[:i]+argv[i+len(words):]
 raise AssertionError((operation,argv))

def differences(a,b,path=''):
 if isinstance(a,dict) and isinstance(b,dict):
  return sum((differences(a.get(k),b.get(k),path+'/'+k) for k in sorted(set(a)|set(b))),[])
 if isinstance(a,list) and isinstance(b,list) and len(a)==len(b):
  return sum((differences(x,y,path+'/'+str(i)) for i,(x,y) in enumerate(zip(a,b))),[])
 return [] if a==b else [(path,a,b)]

def snapshot_times(value):
 if isinstance(value,dict):
  for key,item in value.items():
   if key=='observed_at' and isinstance(item,str):
    assert re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ',item),item
    value[key]='<observed-time>'
   else: snapshot_times(item)
 elif isinstance(value,list):
  for item in value: snapshot_times(item)

with tempfile.TemporaryDirectory(prefix='e6crew1-') as tmp:
 lab=p.Lab(root,tmp+'/fixture')
 # Refuse the installer before its download and temporary-directory cleanup.
 with open(lab.stub+'/uname','w') as f: f.write('#!/bin/sh\nprintf unsupported\\n\n')
 os.chmod(lab.stub+'/uname',0o755)
 with open(lab.stub+'/date','w') as f:
  f.write('#!/bin/sh\nif [ "${JG_E6_LEASE_CLOCK:-}" = 1 ] && [ "$1" = +%s ]; then printf "1795000000\\n"; else exec /bin/date "$@"; fi\n')
 os.chmod(lab.stub+'/date',0o755)
 gaps=[]
 for r in rows:
  k=(r['script'],r['operation'])
  if k in dropped: continue
  e=entries[k]
  opts={'id':'jg-none','task-id':'jg-none','task':'jg-none','session':'default',
        'brief-file':lab.values['file'],'destination-directory':lab.values['dir'],
        'herdr arguments...':'status','label':'fixture'}
  groups=[None]+[g for g in p.optional_groups(r['form']) if '<' in g]
  for group in groups:
   argv,why=p.render(lab,r['form'],opts,script=r['script'],keep=group)
   assert not why,(k,group,why)
   script_argv=argv[1:]
   user_argv=remove_operation(script_argv,r['operation'])
   def run(command):
    lab.reset()
    env=lab.env.copy()
    if r['script']=='jg-lease.sh':
     env['JG_LEASE_HOLDER_PID']=str(os.getpid())
     env['JG_E6_LEASE_CLOCK']='1'
     with open(lab.home+'/state/.lock','w') as f: f.write(str(os.getpid())+'\n')
    before=snapshot(lab.home)
    proc=subprocess.run(command,text=True,capture_output=True,env=env,cwd=lab.run_dir,timeout=30)
    after=snapshot(lab.home)
    lease=None
    if k==('jg-lease.sh','claim') and proc.returncode==0:
     reader=subprocess.run([lab.tree+'/bin/jg-lease.sh','check','jg-none'],text=True,capture_output=True,env=env,cwd=lab.run_dir)
     assert reader.returncode==0 and reader.stdout.strip()==f'main {os.getpid()} 1795000000 live',(k,reader.stdout,reader.stderr)
     other=env.copy(); other['JG_SUPERVISION_ACTOR']='branch'
     contender=subprocess.run([lab.tree+'/bin/jg-lease.sh','claim','jg-none','--actor','branch'],text=True,capture_output=True,env=other,cwd=lab.run_dir)
     assert contender.returncode==6 and 'leased to the main' in contender.stderr,(k,contender.returncode,contender.stderr)
     lease=reader.stdout
    return proc,after,before,lease
   direct, after_direct, before, direct_lease=run([lab.tree+'/'+argv[0]]+script_argv)
   assert not (direct.returncode and p.PARSE_ERROR.search(direct.stderr)),(k,group,argv,direct.stderr)
   if e['method']=='GET': assert after_direct==before,(k,group,'GET changed fixture')
   routed, after_routed, before_routed, routed_lease=run([lab.tree+'/bin/jg']+e['path']+user_argv)
   if routed.returncode==2 and ('Usage:' in routed.stderr or 'unknown' in routed.stderr):
    gaps.append((k,group,routed.stderr.strip().splitlines()[-1]))
    continue
   assert routed.stdout,(k,group,'no dispatcher envelope',routed.stderr)
   result=json.loads(routed.stdout)
   assert result['ok']==(direct.returncode==0),(k,group,direct.returncode,routed.returncode,routed.stderr)
   assert routed.stderr==direct.stderr,(k,group,'stderr differs',direct.stderr,routed.stderr)
   assert after_direct==after_routed,(k,group,'durable result differs',after_direct,after_routed,direct.stderr,routed.stderr)
   assert direct_lease==routed_lease,(k,group,'lease reader differs')
   try: expected=json.loads(direct.stdout)
   except ValueError: expected={'stdout':direct.stdout}
   actual=result['data']
   if direct.returncode and isinstance(actual,dict): actual={key:value for key,value in actual.items() if key!='error'}
   if k in (('jg-fleet-snapshot.sh','-'),('jg-fleet-view.sh','--json')) and direct.returncode==0:
    assert re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ',expected['generated'])
    assert re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ',actual['generated'])
    expected['generated']=actual['generated']='<observed-time>'
    snapshot_times(expected); snapshot_times(actual)
   if k==('jg-herdr-lab.sh','name'):
    for value in (expected,actual):
     assert re.fullmatch(r'jg-lab-fixture-\d+-\d+\n',value['stdout']),(k,value)
     value['stdout']='<generated-name>'
   if actual!=expected:
    gaps.append((k,group,'output differs: '+repr(differences(expected,actual)[:5])))
   if e['method']=='GET': assert after_routed==before_routed,(k,group,'routed GET changed fixture')
 for gap in gaps: print('DISPATCHER GAP:',gap)
 print(f'e6crew1: {len(entries)} entries exercised; {len(dropped)} dropped; {len(gaps)} dispatcher gaps')
PY
