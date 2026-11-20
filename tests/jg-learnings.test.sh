#!/usr/bin/env bash
# Per-home learning access on the ticket tables: exact bytes, stale and competing edits, the owner check.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(jg_test_tmproot jg-learnings)
export LEARNING_TEST_ROOT=$T LEARNING_REPO=$ROOT
python3 - <<'PY'
import json, os, subprocess, sys
from pathlib import Path
t, repo = Path(os.environ['LEARNING_TEST_ROOT']), Path(os.environ['LEARNING_REPO'])
home = t/'home'
for p in (home/'config', home/'data', home/'state'):
    p.mkdir(parents=True)
env = {k:v for k,v in os.environ.items() if k not in ('JG_CONFIG_OVERRIDE','JG_DATA_OVERRIDE')}
env.update(JG_HOME=str(home))
def run(command, *args, body=None, ok=True, custom=env):
    p = subprocess.run([*command, *map(str,args)], input=body, capture_output=True, env=custom)
    if ok and p.returncode: raise AssertionError(p.stderr.decode()+p.stdout.decode())
    if not ok: assert p.returncode, 'command unexpectedly succeeded'
    return p.stdout if ok else p.stderr
def bd(*args, **kw): return run([sys.executable,'-I',str(repo/'core/item-store/adapters/bd_compat.py')], *args, **kw)
def learning(*args, **kw): return run([sys.executable,str(repo/'bin/jg-learnings.py')], *args, **kw)
body = ('Preamble must survive.\n# Learnings\n\n- Same title\n  first α, "quote" \\ <!--g-->\r\n'
        '- Same title\n  different fact\n## '+'complete name '*15+'\n  '+'long β '*8000+'\nfinal no-newline 尾').encode()
ident=json.loads(bd('create','--title','Home learnings','--status','pinned','--labels','juggernaut-learning',
                    '--metadata',json.dumps({'learning_home':str(home)}),'--body-file','-','--json',body=body))['id']
(home/'config/learnings-beads').write_text(json.dumps({'id':ident}))
assert learning('read')==body
assert int(learning('measure'))==len(body)
expected=learning('sha').strip().decode()
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
bd('update',ident,'--metadata','{"learning_home":"another-home"}')
assert b'owner' in learning('read',ok=False)
print('PASS: byte-faithful UTF8/long-body/tail, edits, concurrent stale refusal and the owner check on the ticket tables')
if os.environ.get('DONE_DONE_EVIDENCE_ROOT'):
    out=Path(os.environ['DONE_DONE_EVIDENCE_ROOT']); out.mkdir(exist_ok=True,parents=True)
    (out/'learning-result.txt').write_text('PASS: learning journey on the ticket tables; exact bytes, guarded edits, owner check\n')
    (out/'steps.json').write_text(json.dumps({'target':{'version':subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()},'start':'one throwaway home','steps':['Read exact multi-entry document','Edit with expected hash; reject stale and competing edit','Refuse a row another home owns'],'result':'All preservation assertions passed'}))
PY
