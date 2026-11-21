#!/usr/bin/env bash
# Exercise the proof command inventory against the scripts in an isolated home.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 - <<'PY'
import csv, hashlib, json, os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path(os.environ['ROOT'])
frag=json.loads((root/'core/agent-cli/contract/e6proof2.json').read_text())
rows=[r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(),delimiter='\t') if r['owner']=='e6proof2']
entries=frag['entries']
assert len(rows)==len(entries)==43
assert frag['owner']=='e6proof2'
for row in rows:
    found=[e for e in entries if e['script']=='bin/'+row['script'] and e['operation']==row['operation']]
    assert len(found)==1, row
    e=found[0]
    assert e['form']==row['form'] and e['path']==row['path'].split() and e['method']==row['method'], row
subprocess.run(['bash',str(root/'core/agent-cli/dispatch.sh'),'check'],check=True)
helptext=subprocess.check_output([str(root/'bin/jg'),'help'],text=True)
for e in entries:
    assert 'jg '+' '.join(e['path'])+' - '+e['meaning'] in helptext

with tempfile.TemporaryDirectory(prefix='jg-e6proof2-') as t:
    t=pathlib.Path(t); home=t/'home'; base=t/'base'; home.mkdir(); base.mkdir()
    for name in ('state','config','data','projects'):
        (base/name).mkdir()
    (base/'data'/'fixture').mkdir()
    (base/'data'/'fixture'/'report.md').write_text('Fixture report\n')
    (base/'config'/'backlog-intake-loose').touch()
    snapshot=t/'snapshot.json'; snapshot.write_text('{}\n')
    source=t/'source'; source.mkdir()
    (source/'core'/'machines').mkdir(parents=True)
    (source/'bin').mkdir()
    (source/'core'/'machines'/'fixture.states').write_text('stage\tready\tFixture\n')
    (source/'core'/'machines'/'bare-states.baseline').write_text('0\n')
    (t/'user').mkdir()
    output=t/'output'; output.write_text('fixture\n')
    env=os.environ.copy()
    env.update(HOME=str(t/'user'),TMPDIR=str(t),JG_HOME=str(home),JG_STATE_OVERRIDE=str(home/'state'),
               JG_DATA_OVERRIDE=str(home/'data'),JG_CONFIG_OVERRIDE=str(home/'config'),
               JG_WAR_ROOM_NEXT='0',JG_TEST_CACHE_DIR=str(home/'state'/'test-cache'))
    def reset():
        if home.exists(): shutil.rmtree(home)
        shutil.copytree(base,home)
    def digest():
        return sorted((str(p.relative_to(home)),hashlib.sha256(p.read_bytes()).hexdigest())
                      for p in home.rglob('*') if p.is_file())
    def call(argv):
        return subprocess.run(argv,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=180)
    # Each entry has its own fixture. Dangerous test runs and remote shards stop at argument validation.
    cases={
      'recon-handoff draft':['missing'], 'recon-handoff assign':['missing','--critic','critic'],
      'recon-handoff verdict':['missing','--critic','critic','--hash','0'*64,'--gaps','0'],
      'recon-handoff revise':['missing'], 'recon-handoff assignee':['fixture'],
      'recon-handoff phase':['fixture'], 'recon-handoff show':['fixture'],
      'run-owned':['--owner','fixture','--limit','0','--','/bin/true'],
      'run-owned owner':['--owner','fixture','--limit','0','--','/bin/true'],
      'runner-shard':['badcommit','badbase','--','--list','--all'],
      'scratch register':['fixture',str(source)], 'scratch list':['fixture'],
      'squad-lead-reconcile request':['--snapshot',str(snapshot)],
      'squad-lead-reconcile process-requests':[],
      'squad-lead-reconcile notify':['--snapshot',str(snapshot)],
      'squad-lead-reconcile nudged':['fixture'],
      'state-lint':['--list','--root',str(source)],
      'status-states-lint text':[str(output)], 'status-states-lint commit':[],
      'stow-cascade':['--help'],
      'test-cache key':['missing'], 'test-cache lookup':['missing',str(output)],
      'test-cache store':['missing','1',str(output)], 'test-cache prune':['14'],
      'test-ignored-reads start':[str(source),str(home/'state'/'ignored')],
      'test-ignored-reads finish':[str(home/'state'/'ignored')],
      'test-ignored-reads stop':[str(home/'state'/'ignored')],
      'test-run all':['--list'], 'test-run family':['pure-contract-unit','--list'],
      'test-run changed':['--base','HEAD','--list'],
      'test-run lane':['portable-parallel-1','--list'],
      'test-run proven-isolated':['--list'],
      'test-run list':['--all'], 'test-run list-scheduled':['--family','pure-contract-unit'],
      'test-run list-families':[], 'test-run list-concurrent-safe-families':[],
      'test-run concurrent-safe-family-jobs-max':['pure-contract-unit'],
      'test-run list-lanes':[], 'test-run check-coverage':[], 'test-run show-limits':[],
      'test-run aggregate-json':[str(home/'state'/'out.json'),str(output)],
    }
    # These start the full suite or real shards: only exercise their argument checks.
    unsafe={'test-run':[], 'test-run required-shards':[]}
    for e in entries:
        key=' '.join(e['path'][1:]); args=cases.get(key)
        if key in unsafe:
            if key.endswith('required-shards'):
                direct=call([str(root/e['script']),'--required-shards'])
                assert 'needs <base-ref> <output-dir>' in direct.stderr
                out=call([str(root/'bin/jg'),*e['path']])
                assert out.returncode==2 and 'missing' in out.stderr, (key,out.stderr)
            else:
                direct=call([str(root/e['script']),'--help'])
                assert '--all' in direct.stdout + direct.stderr
            continue
        assert args is not None, key
        reset(); before=digest()
        script=[str(root/e['script'])]
        # For option-named operations the option belongs to the script invocation.
        if e['operation']!='-':
            if e['operation'].startswith('--') and args and args[0]==e['operation']:
                script+=args
            else:
                script+=[e['operation'],*args]
        else: script+=args
        direct=call(script); direct_files=digest()
        reset(); dispatched=call([str(root/'bin/jg'),*e['path'],*args]); dispatch_files=digest()
        if key=='runner-shard':
            assert 'not a full commit id' in direct.stderr
            assert 'unexpected argument --all' in dispatched.stderr
            continue  # documented dispatcher gap; no remote work was started
        assert dispatched.stdout, (key,dispatched.stderr)
        data=json.loads(dispatched.stdout)
        expected=e['exits'].get(str(direct.returncode), 0 if direct.returncode==0 else 1)
        assert dispatched.returncode==expected, (key,direct.returncode,dispatched.returncode,direct.stderr,dispatched.stderr)
        assert dispatched.stderr==direct.stderr, (key,direct.stderr,dispatched.stderr)
        try: expected_output=json.loads(direct.stdout)
        except ValueError: expected_output={'stdout':direct.stdout}
        if direct.returncode: expected_output['error']=direct.stderr
        assert data['data']==expected_output, (key,data,expected_output)
        assert direct_files==dispatch_files, (key,direct_files,dispatch_files)
        if e['method']=='GET': assert before==dispatch_files, key
    print('PASS: e6proof2 inventory, help, isolated reads and script parity (runner gap recorded)')
PY
