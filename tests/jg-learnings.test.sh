#!/usr/bin/env bash
# Real per-home Beads learning access, stale edits, native backup and isolated restore.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ -z "${JG_BEADS_TEST_BD:-}" ] || [ -z "${JG_BEADS_TEST_DOLT:-}" ]; then
  echo 'skip: set JG_BEADS_TEST_BD and JG_BEADS_TEST_DOLT to the pinned builds'; exit 0
fi
T=$(jg_test_tmproot jg-learnings)
export JG_BEADS_BD=$JG_BEADS_TEST_BD JG_BEADS_DOLT=$JG_BEADS_TEST_DOLT
export LEARNING_TEST_ROOT=$T LEARNING_REPO=$ROOT
python3 - <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path
t, repo = Path(os.environ['LEARNING_TEST_ROOT']), Path(os.environ['LEARNING_REPO'])
home, store = t/'home', t/'store'/'.beads'
for p in (home/'config', home/'data', store.parent, t/'other/config', t/'other-store', t/'restored', t/'wrong'):
    p.mkdir(parents=True)
env = {k:v for k,v in os.environ.items() if k not in ('JG_CONFIG_OVERRIDE','JG_DATA_OVERRIDE')}
env.update(JG_HOME=str(home), BEADS_DIR=str(store))
def run(command, *args, body=None, ok=True, custom=env):
    p = subprocess.run([*command, *map(str,args)], input=body, capture_output=True, env=custom)
    if ok and p.returncode: raise AssertionError(p.stderr.decode()+p.stdout.decode())
    if not ok: assert p.returncode, 'command unexpectedly succeeded'
    return p.stdout if ok else p.stderr
def bd(*args, **kw): return run([str(repo/'bin/jg-beads.sh')], *args, **kw)
def learning(*args, **kw): return run([sys.executable,str(repo/'bin/jg-learnings.py')], *args, **kw)
def rows(custom=env): return [json.loads(l) for l in bd('export', custom=custom).splitlines() if l.strip()]
bd('init','--prefix','jg')
(home/'config/beads-dir').write_text(str(store))
body = ('Preamble must survive.\n# Learnings\n\n- Same title\n  first α, "quote" \\ <!--g-->\r\n'
        '- Same title\n  different fact\n## '+'complete name '*15+'\n  '+'long β '*8000+'\nfinal no-newline 尾').encode()
def seed(body):
    r=json.loads(bd('create','--title','Home learnings','--status','pinned','--labels','juggernaut-learning',
                    '--metadata',json.dumps({'learning_home':str(home)}),'--body-file','-','--json',body=body))
    (home/'config/learnings-beads').write_text(json.dumps({'id':r['id']}))
    return r['id']
ident=seed(body)
held=json.loads(bd('create','--title','Held Umer task','--status','on_hold','--metadata','{"hold_reason":"retain this reason"}','--json'))['id']
child=json.loads(bd('create','--title','Dependent Umer task','--deps',held,'--json'))['id']
bd('remember','Unrelated native memory','--key','unrelated')
before=rows()
assert learning('read')==body
assert int(learning('measure'))==len(body)
expected=learning('sha').strip().decode()
learning('backup',t/'backup')
learning('backup',t/'backup')  # Recovery after an interrupted cut can repeat the snapshot.
assert b'outside' in learning('backup',store.parent/'bad-backup',ok=False)
changed=body+b'\n- Updated learning <!--11-08-->'
(t/'edit').write_bytes(changed)
learning('write',expected,t/'edit')
assert learning('read')==changed
assert b'stale' in learning('write',expected,t/'edit',ok=False)
# Two independent callers editing the same version have exactly one winner.
expected=learning('sha').strip().decode()
commands=[]
for i in range(2):
    p=t/f'edit{i}'; p.write_bytes(changed+str(i).encode())
    commands.append(subprocess.Popen([sys.executable,str(repo/'bin/jg-learnings.py'),'write',expected,str(p)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE))
answers=[(p.communicate(),p.returncode) for p in commands]
assert sorted(rc for _,rc in answers)==[0,2], answers
assert any(b'stale' in out[1] for out,rc in answers if rc)
learning('restore',t/'backup',t/'restored/.beads')
restored={**env,'BEADS_DIR':str(t/'restored/.beads')}
assert rows(restored)==before, 'backup lost issues, dependencies, holds or the learning row'
r=json.loads(bd('show',ident,'--json',custom=restored))[0]
assert r['description'].encode()==body, 'native backup does not contain exact learning bytes'
assert json.loads(bd('memories','--json',custom=restored))['unrelated']=='Unrelated native memory'
assert (home/'config/beads-dir').read_text()==str(store), 'restore changed active store'
assert b'new store' in learning('restore',t/'backup',store,ok=False)
other={**env,'JG_HOME':str(t/'other'),'BEADS_DIR':str(t/'other-store/.beads')}
bd('init','--prefix','jg',custom=other)
(t/'other/config/beads-dir').write_text(other['BEADS_DIR'])
bd('create','--title','Independent Umer home',custom=other)
untouched=rows(other)
assert b'different home' in learning('restore',t/'backup',t/'wrong/.beads',custom=other,ok=False)
assert not list((t/'wrong').iterdir())
meta=store/'metadata.json'; meta.rename(store/'metadata.saved'); meta.write_text('{broken')
assert b'jg-beads' in learning('read',ok=False), 'corrupt store was silently omitted'
os.replace(store/'metadata.saved',meta)
bd('update',ident,'--metadata','{"learning_home":"another-home"}')
assert b'owner' in learning('read',ok=False)
assert rows(other)==untouched, 'independent home changed'
(home/'config/beads-dir').write_text(str(t/'missing/.beads'))
assert learning('read',ok=False), 'unavailable store was silently omitted'
print('PASS: byte-faithful UTF8/long-body/tail, edits, concurrent stale refusal, external native backup, isolated restore, issues/relations/holds, corruption and independent home')
if os.environ.get('DONE_DONE_EVIDENCE_ROOT'):
    out=Path(os.environ['DONE_DONE_EVIDENCE_ROOT']); out.mkdir(exist_ok=True,parents=True)
    (out/'learning-result.txt').write_text('PASS: native learning journey; exact bytes, guarded edits, backup/restore, unrelated data and home preserved\n')
    (out/'steps.json').write_text(json.dumps({'target':{'version':subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()},'start':'two isolated embedded stores','steps':['Read exact multi-entry document','Edit with expected hash; reject stale and competing edit','Back up full database outside store','Restore into isolated replacement; compare every exported row and native memories','Refuse corrupt store and another home backup'],'result':'All preservation assertions passed; live homes unchanged'}))
PY
