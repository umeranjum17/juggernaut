#!/usr/bin/env bash
# Steering command inventory, parser, and isolated direct/dispatcher parity.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
export ROOT
python3 -I - <<'PY'
import csv, hashlib, json, os, pathlib, subprocess, tempfile
root = pathlib.Path(os.environ['ROOT'])
rows = [r for r in csv.DictReader((root/'core/agent-cli/operations.tsv').open(), delimiter='\t') if r['owner'] == 'e6steer']
f = json.loads((root/'core/agent-cli/contract/e6steer.json').read_text())
entries = f['entries']
assert len(rows) == len(entries) == 41
for row in rows:
    match = [e for e in entries if e['script'] == 'bin/'+row['script'] and e['operation'] == row['operation']]
    assert len(match) == 1, row
    e = match[0]
    expected = row['form'] + (' <wav>' if row['script'] == 'jg-chat-transcribe.sh' and row['operation'] == 'run' else '')
    method = 'POST' if row['script'] == 'jg-peek.sh' else row['method']
    assert (e['form'], e['path'], e['method']) == (expected, row['path'].split(), method), row
    assert e['aliases'] == ([] if row['aliases'] == '-' else row['aliases'].split(',')), row
subprocess.run(['bash', str(root/'core/agent-cli/dispatch.sh'), 'check'], check=True)
helptext = subprocess.check_output([str(root/'bin/jg'), 'help'], text=True)
for e in entries:
    assert 'jg ' + ' '.join(e['path']) + ' - ' + e['meaning'] in helptext
# Each action has an isolated fixture. Actions capable of network access or starting a
# worker stop at missing configuration, missing target, or an argument check.
cases = {
 'jg-captain-say.sh': {'-':['working [at=123]: fixture']},
 'jg-chat-transcribe.sh': {'run':['/missing.wav'], 'status':[]},
 'jg-delivery-style.sh': {'knob':['local'], 'task-mode':['local']},
 'jg-delivery-tick.sh': {'-':['/missing-home']},
 'jg-delivery.sh': {'handled':['jg-missing','1','--evidence','status:fixture'], 'failed':['jg-missing','1','--reason','fixture'], 'show':['jg-missing'], 'overdue':['jg-missing']},
 'jg-inbox.sh': {'note':['-'], 'announce':['missing'], 'approve':['missing','jg-missing'], 'primary-chat':['fixture','1','hello'], 'reply':['missing','-'], 'followup':['missing','-'], 'receipts':[], 'ready':[], 'say':[], 'status':[], 'ask':['fixture'], 'list':[], 'asks':[], 'outcomes':[], 'drain':[]},
 'jg-mail-check.sh': {'arm':[], 'disarm':[]},
 'jg-mail.sh': {'read':[], 'send':['nobody@example.invalid','fixture','body'], 'status':[], 'poll':[]},
 'jg-operational-input.sh': {'encode':['turn-end-guard'], 'kind':[], 'classify':[], 'body':[], 'record':['bad-kind'], 'doorbell-kind':[], 'doorbell-shaped':[], 'open':['/missing']},
 'jg-peek.sh': {'-':['jg-missing']}}
# setup downloads a model: its parser is checked by help only.
network_setup = ('jg-chat-transcribe.sh','setup')
def digest(home):
    return {str(p.relative_to(home)):hashlib.sha256(p.read_bytes()).hexdigest() for p in home.rglob('*') if p.is_file()}
with tempfile.TemporaryDirectory(prefix='jg-e6steer-') as td:
    t=pathlib.Path(td)
    for e in entries:
        script=pathlib.Path(e['script']).name; op=e['operation']
        if (script,op)==network_setup:
            assert 'setup' in subprocess.run([str(root/e['script']), '--help'], text=True, capture_output=True).stderr
            continue
        assert op in cases[script], (script,op)
        results=[]
        for name in ('direct','jg'):
            home=t/name
            for part in ('state','config','data','projects'): (home/part).mkdir(parents=True,exist_ok=True)
            env={'PATH':os.environ['PATH'],'HOME':str(t),'TMPDIR':str(t),'JG_HOME':str(home),
                 'JG_STATE_OVERRIDE':str(home/'state'),'JG_CONFIG_OVERRIDE':str(home/'config'),
                 'JG_DATA_OVERRIDE':str(home/'data'),'JG_ROOT_OVERRIDE':str(t/'missing-root'), 'LC_ALL':'C'}
            cmd=([str(root/e['script'])]+([] if op=='-' else [op])) if name=='direct' else [str(root/'bin/jg'),*e['path']]
            if script == 'jg-mail.sh' and op == 'status':
                env.update(JG_MAIL_USER='fixture',JG_MAIL_PASS='fixture',JG_IMAP_HOST='invalid',JG_SMTP_HOST='invalid')
                (home/'state/.mail-seen').write_text('fixture cursor\n')
            if script == 'jg-inbox.sh' and op in ('ready','status','list'):
                inbox=home/'state/inbox'; inbox.mkdir(); (inbox/'fixture.note').write_text('id=fixture\n--\nfixture message\n')
            if script == 'jg-peek.sh': (home/'state/.guard-watcher-stale-banner').write_text('fixture\n')
            before=digest(home)
            p=subprocess.run(cmd+cases[script][op],input='fixture\n',env=env,text=True,capture_output=True,timeout=15)
            after=digest(home)
            results.append((p,before,after,home))
        (direct,db,da,dh),(jg,jb,ja,jh)=results
        if script == 'jg-inbox.sh' and op == 'note':
            dn=list((dh/'state/inbox').glob('*.note')); jn=list((jh/'state/inbox').glob('*.note'))
            assert len(dn)==len(jn)==1 and dn[0].read_text().endswith('fixture\n') and jn[0].read_text().endswith('fixture\n')
        elif script == 'jg-mail-check.sh' and op == 'arm':
            for home in (dh,jh):
                shim=home/'state/mail.check.sh'; trust=(home/'state/mail.check-trust').read_text().splitlines()
                assert trust == ['jg-custom-check-v1',hashlib.sha256(shim.read_bytes()).hexdigest()]
            assert (dh/'state/mail.check.sh').read_text().replace(str(dh),'<home>') == (jh/'state/mail.check.sh').read_text().replace(str(jh),'<home>')
        else:
            assert db==jb and da==ja, (e['form'],'durable results differ',da,ja)
        if script == 'jg-peek.sh': assert db != da and 'state/.guard-watcher-stale-banner' not in da
        if e['method']=='GET': assert db==da, (e['form'],'GET changed home',db,da)
        try: envelope=json.loads(jg.stdout)
        except ValueError: raise AssertionError((e['form'],'dispatcher did not run',jg.stderr))
        assert jg.returncode==(direct.returncode if direct.returncode in (0,1,2,3) else 1), (e['form'],direct.returncode,jg.returncode,direct.stderr,jg.stderr)
        assert envelope['ok']==(direct.returncode==0), e['form']
        if script in ('jg-delivery-style.sh','jg-operational-input.sh') or (script == 'jg-mail.sh' and op == 'status'):
            assert envelope['data'].get('stdout','') == direct.stdout, (e['form'],direct.stdout,envelope)
        # Clear fixtures after each operation so each pair starts from the same state.
        import shutil
        shutil.rmtree(t/'direct'); shutil.rmtree(t/'jg')

# Render each optional value group through the real parser and dispatcher.
options = {
 ('jg-captain-say.sh','-'): [['--key','fixture'],['--link','https://example.invalid']],
 ('jg-delivery.sh','overdue'): [['--after','1'],['--since','1'],['--until','1']],
 ('jg-inbox.sh','note'): [['--request-id','fixture']],
 ('jg-inbox.sh','reply'): [['--attach','/missing']],
 ('jg-inbox.sh','followup'): [['--attach','/missing']],
 ('jg-inbox.sh','receipts'): [['--after','1']],
}
with tempfile.TemporaryDirectory(prefix='jg-e6steer-options-') as td:
    t=pathlib.Path(td)
    for e in entries:
        script=pathlib.Path(e['script']).name; op=e['operation']
        for option in options.get((script,op), []):
            for name in ('direct','jg'):
                home=t/name
                for part in ('state','config','data','projects'): (home/part).mkdir(parents=True,exist_ok=True)
                env={'PATH':os.environ['PATH'],'HOME':str(t),'TMPDIR':str(t),'JG_HOME':str(home),
                     'JG_STATE_OVERRIDE':str(home/'state'),'JG_CONFIG_OVERRIDE':str(home/'config'),
                     'JG_DATA_OVERRIDE':str(home/'data'),'JG_ROOT_OVERRIDE':str(t/'missing-root'),'LC_ALL':'C'}
                base=cases[script][op]
                # Options precede operands for scripts that parse flags before positionals.
                args=option+base if (script,op) in [('jg-captain-say.sh','-'),('jg-inbox.sh','note')] else base+option
                cmd=([str(root/e['script'])]+([] if op=='-' else [op])) if name=='direct' else [str(root/'bin/jg'),*e['path']]
                p=subprocess.run(cmd+args,input='fixture\n',env=env,text=True,capture_output=True,timeout=15)
                assert 'usage:' not in p.stderr.lower() and 'unknown option' not in p.stderr.lower(), (e['form'],option,name,p.stderr)
                if name=='jg': assert json.loads(p.stdout)['schema'].startswith('jg.v1 '), (e['form'],option,p.stdout)
                import shutil
                shutil.rmtree(home)

print('e6steer: inventory, help, isolated actions and GET digests passed')
PY
