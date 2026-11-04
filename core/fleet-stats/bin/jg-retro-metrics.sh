#!/usr/bin/env bash
# jg-retro-metrics.sh - the retro metrics, computed from a home's stored records, with one written definition each.
# Usage:
#   jg-retro-metrics.sh definitions
#   jg-retro-metrics.sh compute --home <dir> [--days N] [--now <unix-seconds>] [--retro <id>]
#   jg-retro-metrics.sh show    --home <dir> [--retro <id>]
#
# compute reads <home>/data/metrics/prs.tsv (one row per merged PR) and daily.tsv (steers, decisions,
# blocks per home per day) and prints JSON: the last N UTC calendar days beside the N days before.
# With --retro it also writes the result to <home>/data/metrics/retro-index.jsonl, one line per retro,
# replacing a line with the same id. show prints a stored line (the newest without --retro), so a later
# retro reads the prior window instead of recomputing it. Nothing else is written and no state/ is read.
# The collectors that fill prs.tsv and daily.tsv are not part of this script.
#
# First-pass has exactly one definition, printed by `definitions`. Every figure called first_pass is
# that one, stored with its count (first_pass_n of first_pass_of) so a reader can check it. A figure
# built another way (for example "green on the first CI run") needs its own metric name.
set -eu
exec python3 - "$@" <<'PY'
import json, os, statistics, sys
from datetime import datetime, timedelta, timezone

SCHEMA = 'jg-retro-metrics.v1'
DEFINITIONS = {
    'merged': 'Merged PRs by merge date (UTC day), bots included.',
    'first_pass': 'Percent (rounded down) of merged non-bot PRs with no commit authored after the PR opened, not reverted and not escaped. '
                  'Rebases and merges of main are not commits after open. Stored with first_pass_n (count) and first_pass_of (non-bot merged PRs).',
    'p50_hours': 'Median hours from PR creation to merge, non-bot PRs.',
    'p90_hours': 'The 90th-percentile hours from PR creation to merge: sorted value at index int(0.9 * (n - 1)), non-bot PRs.',
    'p50_build': 'Median hours from first commit authored to merge, non-bot PRs.',
    'rework_ci': 'Commits authored after open whose parent commit failed CI, non-bot PRs.',
    'rework_pipeline': 'Commits authored after open that are no-mistakes fix commits, non-bot PRs.',
    'rework_other': 'Other commits authored after open, non-bot PRs.',
    'escaped': 'Merged PRs that a later merged "fix" PR in the same repo names as the cause, bots included.',
    'reverted': 'Merged PRs that a later merged "Revert" PR names, bots included.',
    'interventions_per_merge': '(steers + decisions + blocks) / merged, from daily.tsv.',
    'corrections_per_merge': 'Steers tagged correct / merged, from daily.tsv.',
}
USAGE = 'usage: jg-retro-metrics.sh definitions | compute --home DIR [--days N] [--now SEC] [--retro ID] | show --home DIR [--retro ID]'
DAILY = ('steers', 'decisions', 'blocks', 's_correct')

def die(msg):
    sys.exit(f'jg-retro-metrics.sh: {msg}\n{USAGE}')

def read_tsv(path):
    if not os.path.exists(path):
        return []
    lines = open(path, errors='replace').read().splitlines()
    return [dict(zip(lines[0].split('\t'), l.split('\t'))) for l in lines[1:] if l] if lines else []

def day_of(stamp):
    return datetime.fromisoformat(stamp.replace('Z', '+00:00')).astimezone(timezone.utc).strftime('%F')

def num(row, key):
    try:
        return float(row.get(key) or 0)
    except ValueError:
        return 0.0

def window(prs, daily, lo, hi, home):
    ps = [p for p in prs if lo <= day_of(p['merged']) < hi and home in ('ALL', p['home'])]
    hs = [p for p in ps if p.get('bot') != '1']  # bot PRs count in merged, escaped and reverted only
    ds = [r for r in daily if lo <= r.get('day', '') < hi and home in ('ALL', r.get('home'))]
    hrs = sorted(num(p, 'hours_to_merge') for p in hs)
    bld = sorted(num(p, 'build_hours') for p in hs)
    steps = {k: int(sum(num(r, k) for r in ds)) for k in DAILY}
    n = len(ps)
    fp = sum(p.get('first_pass') == '1' for p in hs)
    per = lambda v: round(v / n, 2) if n else None
    return dict(
        merged=n, first_pass=(100 * fp // len(hs)) if hs else None, first_pass_n=fp, first_pass_of=len(hs),
        p50_hours=statistics.median(hrs) if hrs else None, p90_hours=hrs[int(0.9 * (len(hrs) - 1))] if hrs else None,
        p50_build=statistics.median(bld) if bld else None,
        rework_ci=int(sum(num(p, 'rework_ci') for p in hs)), rework_pipeline=int(sum(num(p, 'rework_pipeline') for p in hs)),
        rework_other=int(sum(num(p, 'rework_other') for p in hs)),
        escaped=sum(num(p, 'escaped') > 0 for p in ps), reverted=int(sum(num(p, 'reverted') for p in ps)),
        interventions_per_merge=per(steps['steers'] + steps['decisions'] + steps['blocks']),
        corrections_per_merge=per(steps['s_correct']))

def compute(home, days, now, retro):
    metrics = os.path.join(home, 'data', 'metrics')
    prs, daily = read_tsv(os.path.join(metrics, 'prs.tsv')), read_tsv(os.path.join(metrics, 'daily.tsv'))
    today = datetime.fromtimestamp(now, timezone.utc).date()
    cut = (today - timedelta(days=days - 1)).isoformat()
    prev = (today - timedelta(days=2 * days - 1)).isoformat()
    end = (today + timedelta(days=1)).isoformat()
    names = sorted({p['home'] for p in prs}) + ['ALL']
    return dict(schema=SCHEMA, retro=retro, now=now, days=days,
                window={'from': cut, 'to': end}, prior={'from': prev, 'to': cut},
                metrics={h: dict(window=window(prs, daily, cut, end, h), prior=window(prs, daily, prev, cut, h)) for h in names})

def index_path(home):
    return os.path.join(home, 'data', 'metrics', 'retro-index.jsonl')

def stored(home):
    out = []
    if os.path.exists(index_path(home)):
        for l in open(index_path(home), errors='replace'):
            if l.strip():
                out.append(json.loads(l))
    return out

def store(home, entry):
    kept = [e for e in stored(home) if e.get('retro') != entry['retro']] + [entry]
    path = index_path(home)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + '.tmp', 'w') as f:
        f.writelines(json.dumps(e, sort_keys=True) + '\n' for e in kept)
    os.replace(path + '.tmp', path)

def main(argv):
    if not argv:
        die('a command is required')
    cmd, opts, it = argv[0], {}, iter(argv[1:])
    if cmd == 'definitions':
        for k, v in DEFINITIONS.items():
            print(f'{k}: {v}')
        return
    if cmd not in ('compute', 'show'):
        die(f'unknown command {cmd}')
    for flag in it:
        if flag not in ('--home', '--days', '--now', '--retro'):
            die(f'unknown option {flag}')
        try:
            opts[flag[2:]] = next(it)
        except StopIteration:
            die(f'{flag} needs a value')
    if 'home' not in opts:
        die('--home is required')
    home = opts['home']
    if cmd == 'show':
        rows = [e for e in stored(home) if 'retro' not in opts or e.get('retro') == opts['retro']]
        if not rows:
            sys.exit('jg-retro-metrics.sh: no stored retro' + (f' {opts["retro"]}' if 'retro' in opts else '') + f' in {index_path(home)}')
        print(json.dumps(rows[-1], sort_keys=True, indent=2))
        return
    try:
        days = int(opts.get('days', 7))
        now = int(opts['now']) if 'now' in opts else int(datetime.now(timezone.utc).timestamp())
    except ValueError:
        die('--days and --now must be whole numbers')
    if days < 1:
        die('--days must be at least 1')
    entry = compute(home, days, now, opts.get('retro'))
    if opts.get('retro'):
        store(home, entry)
    print(json.dumps(entry, sort_keys=True, indent=2))

main(sys.argv[1:])
PY
