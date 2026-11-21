#!/usr/bin/env bash
# Check proof command coverage and exercise the public contract on isolated fixtures.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
python3 - "$ROOT" <<'PY'
import csv,json,sys
from pathlib import Path
root=Path(sys.argv[1]); contract=root/'core/agent-cli/contract/e6proof1.json'
rows=[r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(),delimiter='\t') if r['owner']=='e6proof1']
data=json.loads(contract.read_text()); entries=data['entries']; dropped=data.get('dropped',[])
assert data['owner']=='e6proof1'
for row in rows:
    found=[e for e in entries if e['script']=='bin/'+row['script'] and e['operation']==row['operation']]
    removed=[e for e in dropped if e['script']=='bin/'+row['script'] and e['operation']==row['operation']]
    assert len(found)+len(removed)==1, row
    if removed:
        assert row['review']=='pending' and removed[0]['reason'] and removed[0]['run'], row
        continue
    entry=found[0]
    assert entry['form']==row['form'] and ' '.join(entry['path'])==row['path'] and entry['method']==row['method'], row
assert len(entries)+len(dropped)==len(rows)
PY
bash "$ROOT/core/agent-cli/dispatch.sh" check
python3 - "$ROOT" <<'PY'
import importlib.util, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
root=Path(sys.argv[1]); inv=root/'core/agent-cli/inventory/parse.py'
spec=importlib.util.spec_from_file_location('parse',inv); parser=importlib.util.module_from_spec(spec); spec.loader.exec_module(parser)
entries=json.loads((root/'core/agent-cli/contract/e6proof1.json').read_text())['entries']
class Values:
    def __init__(self,home): self.home=home
    def value(self,n,overrides,script=None):
        return {'jg-home':str(self.home),'state-dir':str(self.home/'state'),'brief':str(self.home/'brief'),
          'project-dir':str(self.home/'project'),'first-draft-receipt':str(self.home/'receipt'),
          'options-folder-or-file':str(self.home/'option'),'task-id':'missing','session':'invalid',
          'hc arguments...':'status','id':'missing','word':'owner-rule-fixture','none':'none',
          'sha':'0'*40,'head':'0'*40,'quick|standard|deep':'quick','epoch':'1','n':'1',
          'file':str(self.home/'trial'),'dir':str(self.home/'output'),'seconds':'1'}.get(n,'fixture')
def digest(path):
    import hashlib
    return sorted((str(p.relative_to(path)),hashlib.sha256(p.read_bytes()).hexdigest()) for p in path.rglob('*') if p.is_file())
with tempfile.TemporaryDirectory(prefix='e6proof1-') as tmp:
    home=Path(tmp)/'home'
    for part in ('state','data','config','project'): (home/part).mkdir(parents=True)
    (home/'config'/'proof-bypass').write_text('bp-fixture\tticket\tmissing\towner-rule-fixture\t1\t-\tstanding\t0\t-\t-\n')
    (home/'config'/'migration-card').write_text('critical=fixture\nproject=project\n')
    probe=Path(tmp)/'probe'; probe.write_text('#!/bin/sh\nprintf "fixture\\tlive\\tready\\t-\\n"\n'); probe.chmod(0o755)
    (home/'brief').write_text('# Setup\nMigration row: none\n')
    (home/'data'/'legacy').mkdir(); (home/'data'/'legacy'/'report.md').write_text('Critic: legacy\nRound 1: new gaps 0\n')
    env={**os.environ,'HOME':tmp,'TMPDIR':tmp,'JG_HOME':str(home),'JG_STATE_OVERRIDE':str(home/'state'),
         'JG_DATA_OVERRIDE':str(home/'data'),'JG_CONFIG_OVERRIDE':str(home/'config'),'JG_TASK_ID':'fixture',
         'JG_MIGRATION_LIVE_BIN':str(probe),'XDG_CONFIG_HOME':tmp+'/xdg-config','XDG_DATA_HOME':tmp+'/xdg-data','XDG_STATE_HOME':tmp+'/xdg-state'}
    snapshot=Path(tmp)/'snapshot'; shutil.copytree(home,snapshot)
    for e in entries:
        # An invalid home count stops load journeys before they start.
        script=e['script']; form=e['form']; values=Values(home)
        overrides={'bypass-id':'bp-fixture'} if e['method']=='GET' else {}
        argv,why=parser.render(values,form,overrides=overrides,script=Path(script).name)
        if why: raise AssertionError((form,why))
        args=argv[1:]; operation=e['operation']
        if script.endswith('jg-load-journey.sh') and operation=='run': args += ['--homes','0']
        # Path words replace the script's operation word for the public call.
        callargs=args[1:] if operation!='-' else args
        stdin='what is this?\n' if script.endswith('jg-recon-depth.sh') else ''
        shutil.rmtree(home); shutil.copytree(snapshot,home)
        before=digest(home)
        direct=subprocess.run([str(root/script),*args],input=stdin,text=True,capture_output=True,env=env,cwd=tmp,timeout=20)
        if direct.returncode==2 and 'usage:' in direct.stderr.lower():
            raise AssertionError(f'{form}: script {direct.stderr.strip()}')
        after_direct=digest(home)
        shutil.rmtree(home); shutil.copytree(snapshot,home)
        p=subprocess.run([str(root/'bin/jg'),*e['path'],*callargs],input=stdin,text=True,capture_output=True,env=env,cwd=tmp,timeout=20)
        if p.returncode==2 and ('Usage:' in p.stderr or 'usage:' in p.stderr):
            raise AssertionError(f'{form}: {p.stderr.strip()}')
        after_jg=digest(home)
        if e['method']=='GET': assert after_direct==before and after_jg==before, form
        else: assert after_direct==after_jg, (form,after_direct,after_jg)
        expected=e['exits'].get(str(direct.returncode),1)
        assert p.returncode==expected, (form,direct.returncode,p.returncode,direct.stderr,p.stderr)
        if not p.stdout.strip().startswith('{'): raise AssertionError((form,p.returncode,p.stdout,p.stderr))
        json.loads(p.stdout)
        for group in parser.optional_groups(form):
            rendered,why=parser.render(values,form,overrides=overrides,script=Path(script).name,keep=group)
            if why: raise AssertionError((form,group,why))
            optional=rendered[1:]
            if script.endswith('jg-load-journey.sh') and operation=='run': optional += ['--homes','0']
            public=optional[1:] if operation!='-' else optional
            shutil.rmtree(home); shutil.copytree(snapshot,home)
            direct_opt=subprocess.run([str(root/script),*optional],input=stdin,text=True,capture_output=True,env=env,cwd=tmp,timeout=20)
            shutil.rmtree(home); shutil.copytree(snapshot,home)
            public_opt=subprocess.run([str(root/'bin/jg'),*e['path'],*public],input=stdin,text=True,capture_output=True,env=env,cwd=tmp,timeout=20)
            if direct_opt.returncode==2 and 'usage:' in direct_opt.stderr.lower():
                raise AssertionError(f'{form} {group}: script {direct_opt.stderr.strip()}')
            if public_opt.returncode==2 and 'usage:' in public_opt.stderr.lower():
                raise AssertionError(f'{form} {group}: jg {public_opt.stderr.strip()}')
print('proof commands: isolated required forms exercised; load journey uses boundary checks only')
PY
