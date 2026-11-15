"""Dwell per state, read from a move log: how long a ticket stayed in a state, counting only the stays the log shows whole."""
import collections, math, statistics, sys


def read_moves(path):
    """Per ticket, its (epoch, from, to) moves in time order (ties keep file order). A move line is `epoch TAB ticket TAB from TAB event TAB to`."""
    moves = collections.defaultdict(list)
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError as e:
        print(f"jg-machine: cannot read moves file {path}: {e.strerror}", file=sys.stderr)
        sys.exit(2)
    for line in lines:
        f = line.split("\t")
        if len(f) >= 5 and f[0].isdigit():
            moves[f[1]].append((int(f[0]), f[2], f[4]))
    return {t: sorted(v, key=lambda m: m[0]) for t, v in moves.items()}


def dwell(path):
    """Print per state: intervals, continuous ones (the later move starts in the state the earlier one entered), their median and p90
    seconds, and the tickets still open there. An interval that is not continuous had a move between its two moves that was never
    logged, so it is counted and never timed; a ticket's last move enters an open state, counted and never timed."""
    intervals, continuous, secs, open_ = collections.Counter(), collections.Counter(), collections.defaultdict(list), collections.Counter()
    for moves in read_moves(path).values():
        for a, b in zip(moves, moves[1:]):
            intervals[a[2]] += 1
            if b[1] == a[2]:
                continuous[a[2]] += 1
                secs[a[2]].append(b[0] - a[0])
        open_[moves[-1][2]] += 1
    print("state\tintervals\tcontinuous\tdiscontinuous\tmedian_s\tp90_s\topen")
    for state in sorted(set(intervals) | set(open_), key=lambda s: (-intervals[s], s)):
        x = sorted(secs[state])
        med = "-" if not x else "%.1f" % statistics.median(x)
        p90 = "-" if not x else "%.1f" % x[min(len(x) - 1, math.floor(0.9 * len(x)))]
        print(f"{state}\t{intervals[state]}\t{continuous[state]}\t{intervals[state] - continuous[state]}\t{med}\t{p90}\t{open_[state]}")
    n, c = sum(intervals.values()), sum(continuous.values())
    print(f"total\t{n}\t{c}\t{n - c}\t-\t-\t{sum(open_.values())}")
