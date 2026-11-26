#!/usr/bin/env bash
# Exercise landing operations in isolated fixture homes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, shutil, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6land1']
fragment = json.loads((root/'core/agent-cli/contract/e6land1.json').read_text())
entries = fragment['entries']
assert len(rows) == len(entries) == 26
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
# Each route gets the same isolated home and argument values. Network tools are stand-ins;
# a lab start is stopped by the real harness argument validation.
cases = {
 ('jg-branch-prompt.sh','-'): [], ('jg-check-live-pipeline.sh','-'): [],
 ('jg-ci-rerun.sh','-'): ['123', '--repo', 'fixture/repo'], ('jg-config-push.sh','-'): [],
 ('jg-forge-detect.sh','-'): ['/missing-project'],
 ('jg-git-strip-ai-trailers.sh','install'): ['/missing-hooks','/missing-project'],
 ('jg-git-strip-ai-trailers.sh','upstream-hooks'): ['/missing-hooks','/missing-project'],
 ('jg-git-strip-ai-trailers.sh','refresh'): ['/missing-state'],
 ('jg-git-strip-ai-trailers.sh','env-file'): ['/missing-hooks','/missing-output'],
 ('jg-live-lab.sh','up'): ['--harness','invalid'],
 ('jg-live-lab.sh','check'): ['/missing-lab'], ('jg-live-lab.sh','say'): ['/missing-lab','fixture'],
 ('jg-live-lab.sh','pane'): ['/missing-lab'], ('jg-live-lab.sh','down'): ['/missing-lab'],
 ('jg-live-lab.sh','claude-config'): ['/missing-parent/config'], ('jg-merge-local.sh','-'): ['jg-missing'],
 ('jg-migration-live.sh','-'): [], ('jg-post-merge-ci.sh','-'): ['jg-missing','invalid-url','invalid-sha'],
 ('jg-post-merge-ci.sh','--main'): [], ('jg-pr-check.sh','-'): ['jg-missing','invalid-url'],
 ('jg-pr-check.sh','--from-status'): ['jg-missing'], ('jg-pr-merge.sh','-'): ['jg-missing','invalid-url'],
 ('jg-pr-state.sh','-'): ['invalid-url'], ('jg-pr-wait.sh','set'): ['invalid-url','fixture'],
 ('jg-pr-wait.sh','clear'): ['invalid-url'], ('jg-trunk-live-home.sh','-'): ['/missing-project','invalid-sha'],
}
options = {
 ('jg-check-live-pipeline.sh','-'): [['HOMEFIX']],
 ('jg-ci-rerun.sh','-'): [['--failed']], ('jg-config-push.sh','-'): [['--help']],
 ('jg-live-lab.sh','up'): [['--mate'],['--worker'],['--model','fixture'],['--effort','low'],
     ['--supervision-host','off'],['--expect-host','no'],['--source','/missing-source'],['--ref','HEAD'],['--timeout','1']],
 ('jg-live-lab.sh','say'): [['--window','fixture']],
 ('jg-live-lab.sh','pane'): [['--window','fixture'],['--lines','1']],
 ('jg-migration-live.sh','-'): [['--quiet'],['--link']],
 ('jg-post-merge-ci.sh','--main'): [['--restore','/missing-project'],['fixture-workflow']],
 ('jg-pr-merge.sh','-'): [['--attended-override'],['--allow-red','fixture'],['--allow-missing','fixture'],['--allow-orphans','fixture']],
 ('jg-pr-state.sh','-'): [['--all'],['--waiting-for']], ('jg-pr-wait.sh','clear'): [['fixture']],
}
def digest(home):
    return {str(p.relative_to(home)): hashlib.sha256(p.read_bytes().replace(str(home).encode(), b'<home>')).hexdigest()
            for p in home.rglob('*') if p.is_file()}
with tempfile.TemporaryDirectory(prefix='jg-e6land1-') as td:
    tmp = pathlib.Path(td)
    stub = tmp/'stub'; stub.mkdir()
    for name in ('gh','gh-axi','glab','tea','no-mistakes','tmux','ssh','curl','wget','herdr','treehouse','claude','pi','systemctl'):
        path = stub/name; path.write_text('#!/bin/sh\nexit 1\n'); path.chmod(0o755)
    date = stub/'date'; date.write_text('#!/bin/sh\nexec /bin/date -d @1795000000 "$@"\n'); date.chmod(0o755)
    for e in entries:
        key = (pathlib.Path(e['script']).name,e['operation'])
        assert key in cases, key
        for extra in [[]] + options.get(key, []):
            results=[]
            for kind in ('direct','jg'):
                home=tmp/kind
                if home.exists(): shutil.rmtree(home)
                for part in ('state','config','data','projects'): (home/part).mkdir(parents=True,exist_ok=True)
                env={'PATH':str(stub)+':/usr/bin:/bin', 'HOME':str(tmp), 'TMPDIR':str(tmp),
                     'JG_HOME':str(home), 'JG_ROOT_OVERRIDE':str(tmp/'root'), 'JG_STATE_OVERRIDE':str(home/'state'),
                     'JG_DATA_OVERRIDE':str(home/'data'), 'JG_CONFIG_OVERRIDE':str(home/'config'),
                     'JG_CI_RERUN_GH':str(stub/'gh'), 'JG_POST_MERGE_CI_DEADLINE':'0', 'LANG':'C.UTF-8'}
                before=digest(home)
                args=[str(home) if a=='HOMEFIX' else a for a in cases[key]+extra]
                # Direct operation words belong in the same positions as the original forms.
                direct=[str(root/e['script'])]
                if key[0]=='jg-pr-state.sh': direct += extra + cases[key]
                elif key[0]=='jg-pr-wait.sh': direct += [args[0],key[1]]+args[1:]
                else: direct += ([] if key[1]=='-' else [key[1]])+args
                command=direct if kind=='direct' else [str(root/'bin/jg'),*e['path'],*args]
                result=subprocess.run(command,env=env,cwd=tmp,input='',text=True,capture_output=True,timeout=20)
                results.append((result,before,digest(home),str(home)))
            (direct,db,da,dh),(jg,jb,ja,jh)=results
            normalize=lambda text,home: text.replace(home,'<home>')
            if key == ('jg-check-live-pipeline.sh','-') and extra == ['HOMEFIX']:
                assert direct.returncode == 0 and jg.returncode == 2 and 'unexpected argument' in jg.stderr
                continue
            assert jg.stdout, (key, extra, jg.returncode, jg.stderr)
            envelope=json.loads(jg.stdout)
            assert normalize(jg.stderr,jh)==normalize(direct.stderr,dh), (key,extra,direct.stderr,jg.stderr)
            assert jg.returncode==(direct.returncode if direct.returncode in (0,1,2,3) else 1), (key,extra,direct.returncode,jg.returncode)
            assert envelope['ok']==(direct.returncode==0), (key,extra,envelope)
            assert normalize(envelope['data'].get('stdout',''),jh)==normalize(direct.stdout,dh), (key,extra,direct.stdout,envelope)
            assert db==jb and da==ja, (key,extra,'durable results differ')
            if e['method']=='GET': assert db==da, (key,extra,'GET changed home')
print('e6land1: inventory, forms, help and isolated parity passed')
PY
