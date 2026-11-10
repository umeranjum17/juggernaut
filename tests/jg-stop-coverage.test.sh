#!/usr/bin/env bash
# Coverage gate for wait sources and check/stale wake sites.
set -euo pipefail
ROOT=${JG_STOP_COVERAGE_ROOT:-$(cd "$(dirname "$0")/.." && pwd -P)}
python3 - "$ROOT" "$@" <<'PY'
import collections, fnmatch, json, os, pathlib, re, subprocess, sys, tempfile, shutil
root = pathlib.Path(sys.argv[1])
mode = sys.argv[2] if len(sys.argv) > 2 else 'test'
base = 'a2cfad19950f7466ad18e44cbb111647e5571249'

def files(path):
    for folder in ('bin', 'core'):
        p = path / folder
        if p.exists():
            for f in p.rglob('*'):
                if f.is_file() and (folder == 'bin' or f.name == 'wiring.sh' or f.suffix in ('.sh', '')):
                    yield f

def sites(path):
    found = collections.Counter()
    for f in files(path):
        try: lines = re.sub(r'\\\n\s*', ' ', f.read_text()).splitlines()
        except (UnicodeError, OSError): continue
        rel = f.relative_to(path).as_posix()
        for line in lines:
            s = line.strip()
            if s.startswith('#'): continue
            m = re.search(r'\bjg_wake_(append_locked|append|settle)\s+(check|stale)\s+(\S+)', s)
            if m: found[(rel, m.group(0))] += 1
            if f.name == 'wiring.sh':
                for key in re.findall(r'([a-zA-Z0-9_-]+)\.check\.sh', s):
                    found[(rel, 'wiring:' + key)] += 1
    return found

def rows(path):
    s = (path/'core/wait-timers/bin/jg-wait-actions-lib.sh').read_text()
    m = re.search(r"JG_WAIT_OWNER_TABLE='(.*?)'", s, re.S)
    if not m: raise ValueError('owner table missing')
    return {a[0]: a for l in m.group(1).splitlines() if (a := l.split('\t'))}

def sources(path):
    return {v['name'] for v in json.loads((path/'core/bus/workflows/escalation-wait-timers.json').read_text())['spec']['sources']}

def check(path, old_sites, old_rows, old_sources):
    failures = []
    now_rows = rows(path)
    waiver = path/'core/wait-timers/source-waivers.tsv'
    waived = {l.split('\t')[0] for l in waiver.read_text().splitlines() if '\t' in l and l.split('\t',1)[1].strip()} if waiver.exists() else set()
    # Initial waivers record why existing sources have no same-named owner row.
    initial_waivers = {
        'herdr-blocked': 'runtime backstop awaits N19', 'prompt': 'prompt actions await N19',
        'question': 'owner judgement awaits N19', 'account': 'handled by account-down',
        'quota': 'handled by account-down', 'errors': 'error action awaits N19',
        'supervision': 'supervision states await B1', 'greenpr': 'merge action awaits N19',
        'decision': 'owner judgement has no automatic answer', 'pause': 'recheck awaits N19',
    }
    for name in sources(path) - set(now_rows) - waived - set(initial_waivers):
        failures.append('source without row or waiver: ' + name)
    for name, fields in now_rows.items():
        if fields == old_rows.get(name): continue
        if len(fields) < 7 or any(not x.strip() for x in fields[4:7]): failures.append('row missing timer, repeat or clear-by: ' + name)
    alarms = path/'core/wait-timers/alarms.tsv'
    entries = []
    if alarms.exists():
        for line in alarms.read_text().splitlines():
            if not line or line.startswith('#'): continue
            parts = line.split('\t')
            if len(parts) != 2 or not (parts[1] == 'event' or parts[1].startswith('stop:')):
                failures.append('invalid alarm row: ' + line); continue
            entries.append(parts)
            if parts[1].startswith('stop:') and parts[1][5:] not in now_rows:
                failures.append('alarm state without row: ' + parts[1][5:])
    for (rel, call), count in (sites(path) - old_sites).items():
        key = call[7:] if call.startswith('wiring:') else call.split(None, 2)[2].strip('"\'')
        if not any(fnmatch.fnmatchcase(key, pattern) for pattern, _ in entries):
            failures.append('alarm without row: ' + rel + ': ' + call + ' (' + str(count) + ')')
    return failures

# This snapshot was captured from a2cfad19950f7466ad18e44cbb111647e5571249.
# Removing an exemption requires updating this snapshot; it must never gain sites.
import base64, zlib
snapshot = json.loads(zlib.decompress(base64.b64decode(
    "eNqtWEuP2zYQ/iuBoEMPZjeboC2gW4EGRR8o0qQ9bQKDosYSY4rU8mHVXeS/Z0hJNrWWZcvJjfLM93E4nBf9lBhuwSTZw0OSc3n3qSQttaz63lTJKvlUrlu6hTVtGpDFC1YB2774kKRSWb7Zr7ew/5Akq1cfV1eAjaUCPLjl0qN+XIjymNdXYQYzG2UsqUGXQJgAKl1DUl54nvsFPI0mjRKCaLBcQw3SXsQbsBat7vAaqK4RbZzeUAbLNseDm4rXS212kls8M+X14u3Y8r2osxW6hTNqoSB4YxYd7mVmGRN6qtiTVuntMhwtam4MV9Lfkd4vA/tfSMFLMHbhrmZLCthQJ06AyJg7Qxqtcpj39j8/v//jucOtdnI7CwsapFY7dHf69i+SPrVU2uxldv/qM35UdAfdx63Uljfoy4HcavhKPg070HYg/K7RXNrNbVQCo0uyPUnvbzdmOFhOi687l1SkROfIni+s+2vwhUuc8Pqg4TJX/xHB8ysK3g8RGCXaYg2TYH2OzJj3THNsA2ZZA/rs/ofQPPFv40yFnqESO4ZPtssn4LJQ7QmNVgzDQdr52j1oZViys9TA4208ad+jRsioL/CrOwjH5mHhpBR3UuUsUzVc9GrQLnwbIunvv67fvlv/++7PE0rKxRTLWii2hehsQTZxwBBh1zAExWyiKXJJmeU7wGhhSjIuYLGXNwLAEuwNyuwlm4WPVUPqwFSrBsMo5r8PPh/XG6FaM0scAboSf6b4LCb2ByaqlaCf21iAQL/pPdZQNpejQzWTBZflmAI9bjXPnbfHXHONMYBM3UWOWcsqvMxG6fl8MQ6Lw46Hblr56MeW6rTM0vdv/j5hVVQXBOtBC3reXbEmcbL24iJYSlJqD7xMabj7n3Ly6JSl3Qxx13K8sLKj79bZQSXGOdm7HpkxfrSdQv72SwwZdZQp9ZHCCImXC9YQH6+TwEjeD8jLcD4FbgH2g24MDZ2I+HxWcgoay+MzdpewwWKEg4a+7E1Zk0JTLs9pvr5KU4kiNr5WeKukxBuYUj5KY0P6kiy73nzZcMFrHJexn9SNDVPVFRAcVQlGMzRTukfpCNPlOmGYC5OoSB7jfJZwSUDuzmfEc50YXyoqiFBq0tSDMEZ09TjExRQmEp+iGicMnEcFcYzCCwR8L5TujFdieRwYTHP/4hDnzRxrxHvmlG2FKokvo77D+YfSFMOUXrL66cBDGVNO4qGUmrRA41jgn0IY6vH2oTqZu6HbhxhGTVpeMT/EymlFTTUunlU3sNRK7wf+6CdiaN3g5jOv1Ug75jX+fSdBDKTD9wzToEJyoNigSEjsI2NLMecsx1w9eCL66fJ46iN+PGN/M9rjNPDtuVOBMytW25Lynv3jKtE4biTZU9JFbJI9DKvVcbFRug0pkPjqkiDK4FQmrdfuVxh3OLyAxoUPv5UGQR32/QgzRCzO5dIjR9+I92/ejgDnvl1YddDPuJ9ymoW/igYYSgtgYVjAJWitND75k1B2G49FrkKTvBtX8Luhzmd/0tVaXDw6HMo6eN/Qj4eJRhHc/wvp/XfZ")))
baseline = collections.Counter({(p, call): n for p, call, n in snapshot['sites']})
old_rows, old_sources = snapshot['rows'], set(snapshot['sources'])
if True:
    if mode == '--check':
        failures = check(root, baseline, old_rows, old_sources)
        print('\n'.join(failures) if failures else 'PASS stop coverage')
        sys.exit(bool(failures))
    failures = check(root, baseline, old_rows, old_sources)
    if failures: print('\n'.join(failures)); sys.exit(1)
    with tempfile.TemporaryDirectory(prefix='jg-stop-fixture-') as d:
        fixture = pathlib.Path(d)
        for folder in ('bin', 'core'):
            shutil.copytree(root/folder, fixture/folder, symlinks=True)
        def run_gate():
            env = dict(os.environ, JG_STOP_COVERAGE_ROOT=str(fixture))
            return subprocess.run(['bash', str(root/'tests/jg-stop-coverage.test.sh'), '--check'], env=env, text=True, capture_output=True)
        for i, raiser in enumerate(('append', 'append_locked', 'settle')):
            f = fixture/'bin'/('coverage-fixture-' + str(i) + '.sh')
            f.write_text('jg_wake_' + raiser + ' check unlisted-' + str(i) + ' reason\n')
            result = run_gate()
            if result.returncode != 1 or 'unlisted-' + str(i) not in result.stdout: raise SystemExit('FAIL unlisted ' + raiser)
            f.unlink()
        f = fixture/'bin/coverage-fixture.sh'
        f.write_text('jg_wake_append stale unlisted-stale reason\n')
        if (r := run_gate()).returncode != 1 or 'unlisted-stale' not in r.stdout: raise SystemExit('FAIL stale')
        f.unlink()
        f = fixture/'core/coverage-fixture/wiring.sh'; f.parent.mkdir()
        f.write_text('SHIM=$HOME/state/unlisted-check.check.sh\n')
        if (r := run_gate()).returncode != 1 or 'unlisted-check' not in r.stdout: raise SystemExit('FAIL check script')
        f.unlink()
        workflow = fixture/'core/bus/workflows/escalation-wait-timers.json'
        doc = json.loads(workflow.read_text()); doc['spec']['sources'].append({'name':'unlisted-source'})
        workflow.write_text(json.dumps(doc))
        if (r := run_gate()).returncode != 1 or 'unlisted-source' not in r.stdout: raise SystemExit('FAIL source')
        table = fixture/'core/wait-timers/bin/jg-wait-actions-lib.sh'
        table.write_text(table.read_text().replace("JG_WAIT_OWNER_TABLE='", "JG_WAIT_OWNER_TABLE='unlisted-source\tworker\t-\tlead\n"))
        if (r := run_gate()).returncode != 1 or 'missing timer' not in r.stdout: raise SystemExit('FAIL incomplete row')
        table.write_text(table.read_text().replace('unlisted-source\tworker\t-\tlead\n', 'unlisted-source\tworker\t-\tlead\t30\t60\tcleared\n'))
        if (r := run_gate()).returncode != 0: raise SystemExit('FAIL complete row: ' + r.stdout)
        alarm = fixture/'core/wait-timers/alarms.tsv'
        existing_alarms = alarm.read_text() if alarm.exists() else ''
        alarm.write_text(existing_alarms + 'new-key\tstop:missing-state\n')
        if (r := run_gate()).returncode != 1 or 'missing-state' not in r.stdout: raise SystemExit('FAIL alarm state')
        alarm.write_text(existing_alarms + 'new-key\tevent\n')
        f = fixture/'bin/coverage-fixture.sh'; f.write_text('jg_wake_append check new-key reason\n')
        if (r := run_gate()).returncode != 0: raise SystemExit('FAIL listed alarm: ' + r.stdout)
    print('PASS stop coverage and unlisted-site journeys')
PY
