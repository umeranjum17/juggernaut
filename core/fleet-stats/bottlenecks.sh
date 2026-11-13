#!/usr/bin/env bash
# bottlenecks.sh - one bottleneck report a day from the records the landing path already writes (H41).
#
#   bottlenecks.sh [--home <dir>] [--project <name>] [--day <YYYY-MM-DD>] [--days <n>] [--script-days <n>]
#                  [--budget-secs <n>] [--fail-pct <n>] [--min-runs <n>] [--daily] [--file-tickets]
#
# The report covers the UTC day --day (default today) and the --days days up to its end (default 1), in five parts:
#   landing steps   queue, landing and gate seconds per landing (count, median, p90, total), from data/trunk-latency.tsv
#   verify          the nightly whole-run seconds, from data/trunk/nightly-<project>-<day>.md
#   queue wait      landings and queue seconds by recorded reason (queue_why)
#   host load       the one-minute load at each landing (latency rows) and at each gate shard (data/trunk/load-<project>.tsv)
#   test scripts    runs, failed runs, fail rate, mean seconds and total seconds of each test script over the last
#                   --script-days days (default 7), from the timing records data/trunk/required-fast.*/*.json; most
#                   total seconds first. A skipped run (gate_skip) is not a run.
# A script is over budget when its mean is above --budget-secs (default 120) over at least 3 runs, and a high-fail script
# failed more than --fail-pct percent (default 40) of at least --min-runs runs (default 30).
#   --daily         write the report to data/metrics/bottlenecks-<project>-<day>.md once a UTC day; a second run
#                   the same day prints "already reported <day>" and writes nothing. Without it nothing is written.
#   --file-tickets  file one fix ticket for each over-budget or high-fail script, with its numbers, through
#                   core/trunk-landing/quarantine.sh ticket (its key is the script path, so a second ticket is never
#                   filed while one is open; JG_BOTTLENECKS_QUARANTINE names another filer). Needs --daily.
# Read-only except for those two outputs. Exit 2: usage error or a home that cannot be read.
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$SELF_DIR/../.." && pwd -P)
JG_HOME="${JG_HOME:-$ROOT}"
die() { echo "bottlenecks: $*" >&2; exit 2; }
usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
num() { [[ ${2:-} =~ ^[0-9]+$ ]] || die "$1 needs a whole number, got '${2:-}'"; }

PROJECT=${JG_QUARANTINE_PROJECT:-juggernaut} DAY=$(date -u +%F) DAYS=1 SDAYS=7 BUDGET=120 FAILPCT=40 MINRUNS=30 DAILY=0 FILE=0
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --home) [ -d "${2:-}" ] || die "--home needs a directory"; JG_HOME=$2; shift 2 ;;
    --project) PROJECT=${2:-}; shift 2 ;;
    --day) [[ ${2:-} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--day needs YYYY-MM-DD"; DAY=$2; shift 2 ;;
    --days) num "$1" "${2:-}"; DAYS=$2; shift 2 ;;
    --script-days) num "$1" "${2:-}"; SDAYS=$2; shift 2 ;;
    --budget-secs) num "$1" "${2:-}"; BUDGET=$2; shift 2 ;;
    --fail-pct) num "$1" "${2:-}"; FAILPCT=$2; shift 2 ;;
    --min-runs) num "$1" "${2:-}"; MINRUNS=$2; shift 2 ;;
    --daily) DAILY=1; shift ;;
    --file-tickets) FILE=1; shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ $PROJECT =~ ^[A-Za-z0-9._-]+$ ]] || die "the project name has characters a file name cannot hold: $PROJECT"
[ "$FILE" -eq 0 ] || [ "$DAILY" -eq 1 ] || die "--file-tickets needs --daily, so one day files once"
[ "$DAYS" -ge 1 ] && [ "$SDAYS" -ge 1 ] || die "--days and --script-days need at least 1"
[ -d "$JG_HOME" ] || die "no home at $JG_HOME"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
FILER="${JG_BOTTLENECKS_QUARANTINE:-$ROOT/core/trunk-landing/quarantine.sh}"

OUTF="$DATA/metrics/bottlenecks-$PROJECT-$DAY.md"
if [ "$DAILY" -eq 1 ] && [ -f "$OUTF" ]; then echo "already reported $DAY"; exit 0; fi

END=$(( $(date -u -d "$DAY" +%s 2>/dev/null) + 86400 )) || die "bad day $DAY"
[ "$END" -gt 86400 ] || die "bad day $DAY"

REPORT=$(python3 -I - "$DATA" "$PROJECT" "$END" "$DAYS" "$SDAYS" "$BUDGET" "$FAILPCT" "$MINRUNS" "$DAY" <<'PY'
import csv, glob, json, os, re, sys
from datetime import datetime, timezone

data, project, end, days, sdays, budget, failpct, minruns, day = sys.argv[1:]
end, days, sdays, budget, failpct, minruns = map(int, (end, days, sdays, budget, failpct, minruns))
start, sstart = end - days * 86400, end - sdays * 86400
out = []

def epoch(s):
    try: return int(datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
    except ValueError: return 0

def num(s):
    try: return float(s)
    except (TypeError, ValueError): return None

def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else 0

def stat(label, v):
    if not v: return f"  {label:<10} none recorded"
    return f"  {label:<10} n={len(v)} median={pct(v, .5):.0f}s p90={pct(v, .9):.0f}s total={sum(v):.0f}s"

rows = []
try:
    with open(os.path.join(data, "trunk-latency.tsv"), newline="") as f:
        for r in csv.DictReader(f, delimiter="\t"):
            if start <= (num(r.get("landed")) or 0) < end: rows.append(r)
except OSError:
    pass

out.append(f"Bottleneck report for {project}, UTC day {day} ({days} day{'s' if days != 1 else ''} to its end)")
out.append(""); out.append(f"Landing steps ({len(rows)} landings)")
for col, name in (("queue_secs", "queue"), ("landing_secs", "landing"), ("gate_secs", "gate")):
    out.append(stat(name, [n for n in (num(r.get(col)) for r in rows) if n is not None]))
held = {}
for r in rows:
    if r.get("stage"): held[r["stage"]] = held.get(r["stage"], 0) + 1
out.append("  held most: " + (", ".join(f"{k} {v}" for k, v in sorted(held.items(), key=lambda x: -x[1])) or "none recorded"))

out.append(""); out.append("Verify")
secs = []
for p in sorted(glob.glob(os.path.join(data, "trunk", f"nightly-{project}-*.md"))):
    d = re.search(r"-(\d{4}-\d{2}-\d{2})\.md$", p)
    if not d: continue
    t = epoch(d.group(1) + "T00:00:00Z")
    if not (start - 86400 < t < end): continue
    m = re.search(r"^- seconds: (\d+)", open(p).read(), re.M)
    if m: secs.append((d.group(1), int(m.group(1))))
out += [f"  nightly {d}: {s}s" for d, s in secs] or ["  none recorded"]

out.append(""); out.append("Queue wait by reason")
why = {}
for r in rows:
    q = num(r.get("queue_secs"))
    if q is None or q <= 0: continue
    k = r.get("queue_why") or "not recorded"
    c, s = why.get(k, (0, 0)); why[k] = (c + 1, s + q)
for k, (c, s) in sorted(why.items(), key=lambda x: -x[1][1]):
    out.append(f"  {k}: {c} landings, {s:.0f}s")
if not why: out.append("  none recorded")

out.append(""); out.append("Host load")
ll = [n for n in (num(r.get("load")) for r in rows) if n is not None]
out.append("  at landings: " + (f"n={len(ll)} mean={sum(ll)/len(ll):.1f} max={max(ll):.1f}" if ll else "none recorded"))
sl, cpus = [], set()
try:
    for line in open(os.path.join(data, "trunk", f"load-{project}.tsv")):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 7 and start <= (num(f[0]) or 0) < end and num(f[5]) is not None:
            sl.append(num(f[5])); cpus.add(f[6])
except OSError:
    pass
out.append("  at gate shards: " + (f"n={len(sl)} mean={sum(sl)/len(sl):.1f} max={max(sl):.1f} on {'/'.join(sorted(cpus))} cpus" if sl else "none recorded"))

runs = {}
for p in glob.glob(os.path.join(data, "trunk", "required-fast.*", "*.json")):
    try: d = json.load(open(p))
    except (OSError, ValueError): continue
    if not isinstance(d, dict) or not sstart <= epoch(d.get("finished_at", "")) < end: continue
    for s in d.get("scripts") or []:
        if s.get("gate_skip") or not s.get("path"): continue
        runs.setdefault(s["path"], []).append((s.get("exit") not in (0, None), (s.get("duration_ms") or 0) / 1000))
table, flagged = [], []
for path, rs in runs.items():
    n, bad, tot = len(rs), sum(1 for b, _ in rs if b), sum(t for _, t in rs)
    table.append((tot, path, n, bad, tot / n))
    why_ = []
    if n >= 3 and tot / n > budget: why_.append(f"mean {tot/n:.0f}s is over the {budget}s budget")
    if n >= minruns and bad * 100 > failpct * n: why_.append(f"failed {bad} of {n} runs ({100*bad/n:.0f}%), over {failpct}% of at least {minruns} runs")
    if why_: flagged.append((path, f"{path}: " + "; ".join(why_) + f" (last {sdays} days, {n} runs, {tot:.0f}s in total)"))
out.append(""); out.append(f"Test scripts (last {sdays} days, {len(runs)} scripts; top 15 by total seconds)")
for tot, path, n, bad, mean in sorted(table, key=lambda x: (-x[0], x[1]))[:15]:
    out.append(f"  {path}: runs={n} failed={bad} ({100*bad/n:.0f}%) mean={mean:.1f}s total={tot:.0f}s")
if not table: out.append("  none recorded")
out.append(""); out.append("Scripts for a fix ticket")
out += [f"  {m}" for _, m in sorted(flagged)] or ["  none"]
print("\n".join(out))
print("@@FLAGS@@")
for path, m in sorted(flagged): print(f"{path}\t{m}")
PY
) || die "could not read the records"
FLAGS=${REPORT#*@@FLAGS@@}; FLAGS=${FLAGS#$'\n'}; REPORT=${REPORT%%$'\n'@@FLAGS@@*}

if [ "$DAILY" -eq 1 ]; then
  mkdir -p "$DATA/metrics" || die "could not make $DATA/metrics"
  printf '%s\n' "$REPORT" > "$OUTF" || die "could not write $OUTF"
fi
printf '%s\n' "$REPORT"

if [ "$FILE" -eq 1 ] && [ -n "$FLAGS" ]; then
  [ -x "$FILER" ] || die "no ticket filer at $FILER"
  rc=0
  while IFS=$'\t' read -r script why; do
    if id=$(JG_HOME="$JG_HOME" "$FILER" ticket "$script" --project "$PROJECT" --why "$why"); then echo "ticket $id for $script"
    else echo "bottlenecks: could not file a ticket for $script" >&2; rc=1; fi
  done <<<"$FLAGS"
  exit "$rc"
fi
