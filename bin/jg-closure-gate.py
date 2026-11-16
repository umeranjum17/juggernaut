#!/usr/bin/env python3
"""Evaluate data/closure-proofs/<ticket>.json; exit 0 only for a complete proof.

The record contains ticket, as_of, homes, installed_at, patch_identity, reverted,
coverage (installs, arrivals, stalls: each home -> [start,end]), arrivals
(home, at, installed_at or null), and stalls (home, start, end). Times are epoch
seconds. Coverage includes both endpoints of the two 24-hour windows. Each
arrival is counted once. An absent installation is right-censored at as_of.
"""
import json
import math
import sys
import time

DAY = 86400


def refuse(reason):
    print('closure gate: ' + reason, file=sys.stderr)
    raise SystemExit(1)


def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)


def main(path, ticket):
    try:
        if path == '-':
            r = json.load(sys.stdin)
        else:
            with open(path, encoding='utf-8') as f:
                r = json.load(f)
        if r.get('missing'):
            refuse('missing source: ' + ', '.join(r['missing']))
        if r['ticket'] != ticket:
            refuse('proof ticket does not match')
        t, now, homes = r['installed_at'], r['as_of'], r['homes']
        if not num(t) or not num(now) or not isinstance(homes, list) or not homes or any(not isinstance(h, str) or not h for h in homes) or len(set(homes)) != len(homes):
            refuse('invalid installation time or homes')
        if r['patch_identity'] is not True:
            refuse('installation by patch identity is missing')
        if r['reverted'] is not False:
            refuse('revert status is missing or reverted')
        if now < t + DAY:
            refuse('24-hour after-window has not elapsed')
        if not 0 <= time.time() - now <= 60:
            refuse('proof measurement is stale or in the future')
        for source in ('installs', 'arrivals', 'stalls'):
            for home in homes:
                span = r['coverage'][source][home]
                if not isinstance(span, list) or len(span) != 2 or not all(num(x) for x in span) or span[0] > t - DAY or span[1] < now:
                    refuse('missing or short %s coverage for %s' % (source, home))
        stalls = {h: [] for h in homes}
        for s in r['stalls']:
            h, start, end = s['home'], s['start'], s['end']
            if h not in stalls or not num(start) or not num(end) or start >= end or end > now:
                refuse('invalid stall episode')
            stalls[h].append((start, end))
        for intervals in stalls.values():
            intervals.sort()
            if any(a[1] > b[0] for a, b in zip(intervals, intervals[1:])):
                refuse('overlapping stall episodes')
        values = {view: [[], []] for view in ('raw', 'adjusted')}
        for a in r['arrivals']:
            h, start, end = a['home'], a['at'], a['installed_at']
            if h not in stalls or not num(start) or start > now or (end is not None and (not num(end) or end < start)):
                refuse('invalid arrival')
            if not t - DAY <= start < t + DAY:
                continue
            done = end is not None and end <= now
            stop = end if done else now
            elapsed = stop - start
            removed = sum(max(0, min(stop, b) - max(start, a)) for a, b in stalls[h])
            idx = int(start >= t)
            for view, value in (('raw', elapsed), ('adjusted', elapsed - removed)):
                values[view][idx].append((value, done))
        for view, windows in values.items():
            bounds = []
            for window in windows:
                if not window:
                    refuse('missing %s window arrivals' % view)
                k = (9 * len(window) + 9) // 10 - 1
                low = sorted(v for v, _ in window)[k]
                high = sorted(v if done else math.inf for v, done in window)[k]
                bounds.append((low, high))
            before, after = bounds
            if math.isinf(before[1]) or math.isinf(after[1]) or before[0] != before[1] or after[0] != after[1]:
                refuse('%s p90 interval is unresolved' % view)
            if after[1] > before[0]:
                refuse('%s p90 is worse' % view)
        print('CLOSED: complete 24-hour proof in both views')
    except (OSError, ValueError, TypeError, KeyError, IndexError) as exc:
        refuse('missing or invalid proof input: %s' % exc)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        refuse('usage: jg-closure-gate.py <proof.json> <ticket>')
    main(*sys.argv[1:])
