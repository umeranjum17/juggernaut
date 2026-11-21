#!/usr/bin/env bash
# Exercise report operations through the real scripts and dispatcher on isolated homes.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, datetime, hashlib, json, os, pathlib, re, sqlite3, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6report2']
f = json.loads((root/'core/agent-cli/contract/e6report2.json').read_text())
entries = f['entries']
assert len(rows) == 31
for row in rows:
    matches = [e for e in entries if (e['script'], e['operation']) == ('bin/'+row['script'], row['operation'])]
    assert len(matches) == 1, row
    e = matches[0]
    assert (e['path'], e['form'], e['method'], e['aliases']) == (row['path'].split(), row['form'], row['method'], [] if row['aliases']=='-' else row['aliases'].split(',')), row
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext

def digest(home):
    result={}
    for p in home.rglob('*'):
        if not p.is_file(): continue
        data=p.read_bytes()
        if p.suffix == '.db':
            with sqlite3.connect(f'file:{p}?mode=ro', uri=True) as db:
                data='\n'.join(db.iterdump()).encode()
        if p.name=='tokens-retro.check-trust':
            assert data.decode().splitlines()[1] == hashlib.sha256((p.parent/'tokens-retro.check.sh').read_bytes()).hexdigest()
            data=b'<verified trust>'
        data=data.replace(str(home).encode(),b'<home>')
        result[str(p.relative_to(home))]=re.sub(rb'\b1[0-9]{9}\b', b'<time>', data)
    return result
# One fixture per form, with missing task IDs preventing lifecycle operations.
cases = {
 'jg-loss-claim-check.sh': {'-':['REPORT']},
 'jg-outcome-ledger.sh': {'build':[], 'columns':[], 'publications':[], 'show':['jg-missing'], 'summary':[]},
 'jg-overwatch-kpi.sh': {'hook':['claude'], 'tag':['feedback'], 'record':['fixture'], 'pending':[], 'scorecard':[]},
 'jg-ready-trace.sh': {'-':['HOME']},
 'jg-report-opening-check.sh': {'-':['REPORT','--card','CARD'], '--card':['REPORT','--card','CARD'], '--filer':['REPORT','--filer','jg-missing'], '--board':['REPORT','--filer','jg-missing','--board','BOARD'], '--key':['REPORT','--filer','jg-missing','--key','fixture']},
 'jg-report-page.sh': {'build':['jg-missing'], 'check':['jg-missing']},
 'jg-retired-catalog-check.sh': {'-':[], '--base':['--base','HEAD'], '--root':['--root','ROOT'], '--self-test':['--self-test']},
 'jg-tokens-retro.sh': {'arm':[], 'show':[], 'disarm':[]},
 'jg-unit-claim.sh': {'claim':[], 'may-install':[], 'status':[], 'refuse':[]},
 'jg-whats-left.sh': {'-':[]},
}
options = {
 ('jg-outcome-ledger.sh','build'):[['fixture']], ('jg-outcome-ledger.sh','publications'):[['fixture']], ('jg-outcome-ledger.sh','summary'):[['fixture']],
 ('jg-overwatch-kpi.sh','tag'):[['--message','1'], ['fixture-link']], ('jg-overwatch-kpi.sh','record'):[['--id','fixture'], ['--']], ('jg-overwatch-kpi.sh','scorecard'):[['--json'],['--landed']],
 ('jg-report-opening-check.sh','--filer'):[['--board','BOARD'],['--key','fixture']], ('jg-report-opening-check.sh','--board'):[['--key','fixture']], ('jg-report-opening-check.sh','--key'):[['--board','BOARD']],
 ('jg-retired-catalog-check.sh','--base'):[['--root','ROOT']], ('jg-retired-catalog-check.sh','--root'):[['--base','HEAD']], ('jg-whats-left.sh','-'):[['show'],['write']],
}
with tempfile.TemporaryDirectory(prefix='jg-e6report2-') as tmp:
    tmp = pathlib.Path(tmp)
    report=tmp/'report.md'; report.write_text('# Answer\n\nFixture answer.\n')
    card=tmp/'card.json'; card.write_text('{}\n')
    board=tmp/'board.json'; board.write_text('[]\n')
    for index, e in enumerate(entries):
        script=pathlib.Path(e['script']).name; op=e['operation']
        for trial, extra in enumerate([[]]+options.get((script,op),[])):
            results=[]
            now=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            for name in ('direct','jg'):
                home=tmp/(str(index)+'-'+str(trial))/name
                for part in ('state','config','data','projects'): (home/part).mkdir(parents=True,exist_ok=True)
                env=dict(os.environ, HOME=str(tmp), XDG_CONFIG_HOME=str(tmp/'xdg'), TMPDIR=str(tmp), JG_HOME=str(home), JG_ROOT_OVERRIDE=str(tmp/'root'), JG_STATE_OVERRIDE=str(home/'state'), JG_DATA_OVERRIDE=str(home/'data'), JG_CONFIG_OVERRIDE=str(home/'config'), JG_BEARINGS_NOW=now)
                tokens=cases[script][op]+extra
                if script == 'jg-overwatch-kpi.sh' and op in ('tag','record') and extra and extra[0].startswith('--'):
                    tokens=extra+cases[script][op]
                args=[{'HOME':str(home),'ROOT':str(root),'REPORT':str(report),'CARD':str(card),'BOARD':str(board)}.get(x,x) for x in tokens]
                # Options can appear before positional arguments; the parser preserves their meaning.
                cmd=([str(root/e['script'])]+([] if op=='-' or op.startswith('--') else [op])+args if name=='direct' else [str(root/'bin/jg'),*e['path']]+args)
                before=digest(home)
                p=subprocess.run(cmd,env=env,text=True,capture_output=True,timeout=60)
                if script == 'jg-whats-left.sh' and p.returncode == 0:
                    assert ('Updated '+now+'.') in (home/'state/whats-left.md').read_text()
                    if 'show' in args: assert ('Updated '+now+'.') in p.stdout
                results.append((p,before,digest(home),str(home)))
            (a,ab,aa,ah),(b,bb,ba,bh)=results
            norm=lambda s,h:s.replace(h,'<home>')
            try: envelope=json.loads(b.stdout)
            except ValueError: raise AssertionError((e['form'],args,b.returncode,b.stdout,b.stderr))
            assert norm(a.stderr,ah)==norm(b.stderr,bh), (e['form'],args,a.stderr,b.stderr)
            assert b.returncode==(a.returncode if a.returncode in (0,1,2,3,4,5) else 1), (e['form'],args,a.returncode,b.returncode)
            envelope['data'].pop('error',None)
            try: expected=json.loads(a.stdout)
            except ValueError: expected={'stdout':a.stdout}
            assert re.sub(r'\b1[0-9]{9}\b','<time>',norm(json.dumps(envelope['data'],sort_keys=True),bh)) == re.sub(r'\b1[0-9]{9}\b','<time>',norm(json.dumps(expected,sort_keys=True),ah)), (e['form'],args,a.stdout,envelope)
            assert ab==bb and aa==ba, (e['form'],args,'home state differs', sorted(k for k in set(aa)|set(ba) if aa.get(k)!=ba.get(k)))
            if e['method']=='GET': assert ab==aa, (e['form'],args,'GET changed home')
            assert 'usage:' not in a.stderr.lower(), (e['form'],args,a.stderr)
print('e6report2: forms and isolated parity passed')
PY
