#!/usr/bin/env python3
"""Compose the interval gate's inputs; missing or bounded sources stay explicit.

Stall episodes, when recorded, are data/trunk-stalls.tsv rows of project, home,
start epoch and end epoch. This reader never creates or infers stall episodes.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parent
home = Path(os.environ['JG_HOME'])
data = Path(os.environ['JG_DATA_OVERRIDE'])
ticket = sys.argv[1]
now = int(time.time())
out = {'ticket': ticket, 'as_of': now, 'homes': [], 'coverage': {},
       'arrivals': [], 'stalls': [], 'installed_at': None,
       'patch_identity': False, 'reverted': None, 'missing': []}


def missing(text):
    if text not in out['missing']:
        out['missing'].append(text)


def rows(name):
    try:
        lines = (data / name).read_text().splitlines()
        if not lines:
            missing(name + ' history')
        return [line.split('\t') for line in lines if line and not line.startswith('#')]
    except OSError:
        missing(name + ' history')
        return []


def command(*args):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


for source in ('trunk-landings.tsv', 'trunk-in-use.tsv', 'trunk-stalls.tsv'):
    rows(source)
if out['missing']:
    print(json.dumps(out))
    sys.exit(0)

try:
    ledger = command(str(root / 'jg-outcome-ledger.sh'), 'build')
    entries = [x.split('\t') for x in ledger.splitlines()]
    target = [x for x in entries if len(x) >= 9 and x[1] == ticket and x[4] == 'landed' and x[7] != 'duplicate']
    if len(target) != 1:
        missing('one unambiguous ticket landing')
        raise ValueError('landing')
    project, commit = target[0][2:4]
    out['reverted'] = any(x[1] == ticket and x[3] == commit and x[4] == 'reverted' for x in entries if len(x) >= 9)
    repo = home / 'projects' / project
    land = [x for x in rows('trunk-landings.tsv') if len(x) >= 5 and x[1] == project and x[3].isdigit() and not x[4].startswith('reverts-')]
    use = [x for x in rows('trunk-in-use.tsv') if len(x) >= 4 and (x[0] == project or x[0].startswith(project + ':')) and x[2].isdigit() and x[3].split(',')[0] in ('live', 'canary')]
    stall = [x for x in rows('trunk-stalls.tsv') if len(x) >= 4 and x[0] == project and x[2].isdigit() and x[3].isdigit()]
    names = sorted({x[0] for x in use})
    out['homes'] = names
    if not names:
        missing('installation homes')
    # The measurement is as of the latest instant every source is known
    # through, so coverage can never claim time its records do not hold.
    ends = [max((int(x[3]) for x in land), default=None), max((int(x[2]) for x in use), default=None),
            max((int(x[3]) for x in stall), default=None)]
    if None in ends:
        missing('source history through the measurement time')
        raise ValueError('no history')
    out['as_of'] = now = min([now] + ends)
    land = [x for x in land if int(x[3]) <= now]
    use = [x for x in use if int(x[2]) <= now]
    stall = [x for x in stall if int(x[2]) < now]
    stall = [x[:3] + [str(min(int(x[3]), now))] for x in stall]
    # Read the stable patch identity for each candidate revision and all
    # ancestors of each installed revision. Unreadable git history is missing.
    def patch(rev):
        diff = command('git', '-C', str(repo), 'show', '--format=', '--no-ext-diff', rev)
        result = subprocess.run(['git', 'patch-id', '--stable'], input=diff, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.split()
        if not result:
            raise ValueError('empty patch identity')
        return result[0]
    ids = {x[2]: patch(x[2]) for x in land}
    ancestors = {}
    for x in use:
        ancestors.setdefault(x[1], command('git', '-C', str(repo), 'rev-list', x[1]).splitlines())
    pids = {}
    for revs in ancestors.values():
        for rev in revs:
            if rev not in pids:
                try:
                    pids[rev] = patch(rev)
                except ValueError:
                    pids[rev] = None
    def installed(sha, since):
        return min((int(x[2]) for x in use if int(x[2]) >= since and ids[sha] in {pids[r] for r in ancestors[x[1]]}), default=None)
    matches = [x for x in land if x[2].startswith(commit)]
    if len(matches) == 1:
        out['installed_at'] = installed(matches[0][2], int(matches[0][3]))
        out['patch_identity'] = out['installed_at'] is not None
    else:
        missing('ticket patch identity')
    # Each landing is one arrival, assigned to the project's recorded local
    # stream. Multiple home streams require the shared collector to join them.
    if len(names) != 1:
        missing('arrival home attribution')
    else:
        h = names[0]
        out['arrivals'] = [{'home': h, 'at': int(x[3]), 'installed_at': installed(x[2], int(x[3]))} for x in land]
    for x in stall:
        out['stalls'].append({'home': x[1], 'start': int(x[2]), 'end': int(x[3])})
    for source in ('arrivals', 'installs', 'stalls'):
        out['coverage'][source] = {}
        for h in names:
            if source == 'arrivals': stamps = [int(x[3]) for x in land] if len(names) == 1 else []
            elif source == 'installs': stamps = [int(x[2]) for x in use if x[0] == h]
            else: stamps = [int(x[i]) for x in stall if x[1] == h for i in (2, 3)]
            if stamps: out['coverage'][source][h] = [min(stamps), now]
            else: missing(source + ' coverage for ' + h)
except (subprocess.CalledProcessError, OSError, ValueError, IndexError) as exc:
    missing('outcome ledger or git history: ' + str(exc))
print(json.dumps(out))
