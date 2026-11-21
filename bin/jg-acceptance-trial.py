#!/usr/bin/env python3
"""Measure the acceptance trial of report section 11 from data/<task>/trial.md and bin/jg-ask-record.sh.

The trial file holds `T0: <epoch>`, `Deadline: ... = <epoch>` and a roster, one ask per line after the `## Roster` heading:
    ask id | requested_at (epoch or ISO UTC) | home | original message | intended homes (comma separated)
An ask counts only with all five fields and a requested_at in [T0, deadline]. Nothing is invented, split or excluded.
Measured here: count, use, speed (nearest-rank p90), the proof count and recorded turns of efficiency. Quality, no-repeat, waited-for,
load and the separate suite result have other sources and are listed in `unmeasured`; they are never counted as passed.
"""
import calendar
import json
import math
import os
import re
import subprocess
import sys
import time

NEED = 10


def usage():
    print('usage: jg-acceptance-trial.sh [--trial <file>] [--now <epoch>] [--json]', file=sys.stderr)
    raise SystemExit(64)


def moment(s):
    s = s.strip()
    if re.fullmatch(r'\d+', s):
        return int(s)
    try:
        return calendar.timegm(time.strptime(s, '%Y-%m-%dT%H:%M:%SZ'))
    except ValueError:
        return None


def parse(path):
    t0 = deadline = None
    roster, rejected, in_roster = [], [], False
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('## Roster'):
            in_roster = True
        elif in_roster:
            if not line.strip() or line.startswith(('(', '#')):
                continue
            f = [x.strip() for x in line.split('|')]
            at = moment(f[1]) if len(f) == 5 else None
            (roster if at is not None and all(f) else rejected).append(
                {'ask': f[0], 'requested_at': at, 'home': f[2], 'intended_homes': [h.strip() for h in f[4].split(',') if h.strip()]}
                if at is not None and all(f) else line)
        else:
            m = re.match(r'(T0|Deadline):.*?(\d{10})\s*(?:\(|$)', line)
            if m:
                if m.group(1) == 'T0':
                    t0 = int(m.group(2))
                else:
                    deadline = int(m.group(2))
    return t0, deadline, roster, rejected


def pct(xs, p):
    xs = sorted(xs)
    return xs[max(0, math.ceil(p / 100 * len(xs)) - 1)]


def record(ask):
    r = subprocess.run([os.path.join(os.path.dirname(os.path.abspath(__file__)), 'jg-ask-record.sh'), 'show', ask],
                       capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None


def main(argv):
    trial = os.path.join(os.environ['JG_HOME'], 'data', 'jg-ftplan-9', 'trial.md')
    now, as_json, i = int(time.time()), False, 0
    while i < len(argv):
        if argv[i] == '--trial' and i + 1 < len(argv):
            trial, i = argv[i + 1], i + 2
        elif argv[i] == '--now' and i + 1 < len(argv) and argv[i + 1].isdigit():
            now, i = int(argv[i + 1]), i + 2
        elif argv[i] == '--json':
            as_json, i = True, i + 1
        else:
            usage()
    try:
        t0, deadline, roster, rejected = parse(trial)
    except OSError as e:
        print('acceptance trial: cannot read the trial record: %s' % e, file=sys.stderr)
        return 1
    if t0 is None or deadline is None:
        print('acceptance trial: the trial record has no T0 or deadline', file=sys.stderr)
        return 1
    qualified = [a for a in roster if t0 <= a['requested_at'] <= deadline]
    out_of_window = [a['ask'] for a in roster if a not in qualified]
    broken, gaps = [], []   # a measured bound that fails; a value no record shows yet
    rows = []
    for a in qualified:
        r = record(a['ask'])
        if r is None:
            gaps.append('%s: no ask record' % a['ask'])
            continue
        if r.get('requested_at') is None or r['requested_at'] < t0:
            broken.append('%s: its ticket was requested before T0' % a['ask'])
            continue
        rows.append((a, r))
        by_home = {h['home']: h for h in r.get('homes', [])}
        for h in a['intended_homes']:
            row = by_home.get(h)
            if row is None or row.get('status') != 'live':
                gaps.append('%s: not in use in %s' % (a['ask'], h))
            elif row.get('behavior') == 'fail':
                broken.append('%s: behaviour failed in %s' % (a['ask'], h))
            elif row.get('behavior') != 'pass':
                gaps.append('%s: behaviour unobserved in %s' % (a['ask'], h))
        if (r.get('proofs_per_candidate') or 0) > 1:
            broken.append('%s: %d proofs for one candidate' % (a['ask'], r['proofs_per_candidate']))
        if r.get('model_turns') is None:
            gaps.append('%s: model turns unrecorded' % a['ask'])
        for k in ('ask_to_in_use_min', 'ready_to_in_use_min'):
            if r.get(k) is None:
                gaps.append('%s: %s unrecorded' % (a['ask'], k))
    speed = {}
    for k, med_max, p90_max in (('ask_to_in_use_min', 240, 480), ('ready_to_in_use_min', 15, 30)):
        xs = [r[k] for _, r in rows if r.get(k) is not None]
        if len(xs) == NEED:
            speed[k] = {'median': pct(xs, 50), 'p90': pct(xs, 90), 'median_max': med_max, 'p90_max': p90_max}
            if speed[k]['median'] > med_max or speed[k]['p90'] > p90_max:
                broken.append('%s: median %s p90 %s over the bound %s/%s' % (k, speed[k]['median'], speed[k]['p90'], med_max, p90_max))
    n = len(qualified)
    late = now > deadline
    if n < NEED and late:
        verdict, why = 'FAIL', 'fewer than ten qualified asks at the deadline (%d)' % n
    elif broken:
        verdict, why = 'FAIL', '; '.join(broken)
    elif n < NEED:
        verdict, why = 'PENDING', '%d of %d asks recorded, %d s to the deadline' % (n, NEED, deadline - now)
    elif gaps and late:
        verdict, why = 'FAIL', 'a value no record shows at the deadline: ' + '; '.join(gaps)
    elif gaps:
        verdict, why = 'PENDING', '; '.join(gaps)
    else:
        verdict, why = 'MEASURED-PASS', 'every criterion this check measures holds'
    report = {
        'verdict': verdict, 'why': why, 't0': t0, 'deadline': deadline, 'now': now,
        'asks': {'required': NEED, 'qualified': n, 'out_of_window': out_of_window, 'malformed_lines': len(rejected)},
        'speed': speed,
        'efficiency': {'machine_minutes': {r['ticket']: (r.get('machine_minutes') or {}).get('total') for _, r in rows},
                       'model_turns': {r['ticket']: r.get('model_turns') for _, r in rows}},
        'broken': broken, 'gaps': gaps,
        'unmeasured': ['quality (rollback, false In-use claim, red post-merge runs)', 'no-repeat (closure gate per fix ticket)',
                       'waited-for work', 'load', 'manual unblocks and mechanical model turns', 'suite result (300 s)'],
    }
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print('acceptance trial: %s - %s' % (verdict, why))
        print('asks: %d of %d qualified (%d outside the window, %d malformed lines)' % (n, NEED, len(out_of_window), len(rejected)))
        for k, v in speed.items():
            print('%s: median %s (max %s), p90 %s (max %s)' % (k, v['median'], v['median_max'], v['p90'], v['p90_max']))
        for g in gaps + broken:
            print('  - ' + g)
        print('not measured here: ' + '; '.join(report['unmeasured']))
    return {'MEASURED-PASS': 0, 'FAIL': 1, 'PENDING': 2}[verdict]


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
