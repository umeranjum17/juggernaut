#!/usr/bin/env bash
# Goal meter through its real callers: `fleet-report.sh <home> --goal` over a fixture home (3 landings, 2 blocked lines of
# which 1 is from a Recon lane, 1 leftover record), and core/fleet-report/wiring.sh, which registers the check that records
# the row. Names core/fleet-report/bin/fleet-report.sh, core/fleet-report/bin/goal-meter.sh and core/fleet-report/wiring.sh.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
d=$(mktemp -d "${TMPDIR:-/tmp}/jg-goal-meter.XXXXXX"); trap 'rm -rf -- "$d"' EXIT
home=$d/home; mkdir -p "$home/data/metrics" "$home/state" "$home/config"
ln -s "$here/bin" "$home/bin"; ln -s "$here/core" "$home/core"
NOW=1794000000
fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: want '$3' got '$2'" >&2; fail=1; fi; }
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
{ tab task head commit first_done ready gate_start launch landed minutes stage gate_secs load
  tab a h1 c1 0 0 '' '' $((NOW - 600)) 2 queue 100 ''
  tab b h2 c2 0 0 '' '' $((NOW - 500)) 4 gate 200 ''
  tab c h3 c3 0 0 '' '' $((NOW - 400)) 20 queue 300 ''; } > "$home/data/trunk-latency.tsv"
tab a p1 c1 $((NOW - 600)) full > "$home/data/trunk-landings.tsv"
printf 'kind=ship\n' > "$home/state/a.meta"; printf 'kind=ship\n' > "$home/state/live.meta"; printf 'kind=scout\n' > "$home/state/recon-x.meta"
row() { printf '{"at":%s,"kind":"status","from":"%s","text":"%s [at=%s]: x"}\n' "$4" "$1" "$2" "$3"; }
{ row lane-w blocked $((NOW - 3000)) $((NOW - 3000)); row lane-w resolved $((NOW - 2800)) $((NOW - 2800))
  row recon-x needs-decision $((NOW - 2000)) $((NOW - 2000)); } > "$home/state/chat.jsonl"

out=$(bash "$here/core/fleet-report/bin/fleet-report.sh" "$home" --goal --now "$NOW" --json)
for pair in '.landings.count=3' '.landings.within_5_min=2' '.landings.pct_within_5=67' '.landings.pass=false' '.gate_p90_secs=200' \
  '.stops.count=1' '.stops.answered_in_300_s=1' '.stops.median_answer_secs=200' '.stops.never_closed=0' \
  '.stops.recon_lines=1' '.stops.recon_lanes=1' '.leftover_records=1'; do
  ck "${pair%%=*}" "$(jq -c "${pair%%=*}" <<<"$out")" "${pair#*=}"
done
text=$(bash "$here/core/fleet-report/bin/fleet-report.sh" "$home" --goal --now "$NOW")
case $text in *'Landings inside 5 min: 2 of 3 (67%)'*'Recon lines: 1 from 1 lanes'*'Leftover records: 1'*) echo 'ok - text rows' ;; *) echo "not ok - text rows: $text" >&2; fail=1 ;; esac

# The wiring registers the check, and the registered check records one row a day.
JG_HOME=$home bash "$here/core/fleet-report/wiring.sh" > "$d/wire.log"
ck 'check shim is private' "$(stat -c %a "$home/state/fleet-report.check.sh")" 700
ck 'check is registered' "$([ -f "$home/state/fleet-report.check-trust" ] && echo yes || echo no)" yes
JG_HOME=$home bash "$here/core/fleet-report/wiring.sh" > "$d/wire2.log"
ck 'second wiring keeps no backup' "$(find "$home/state" -name '*bak-fleet-report*' | wc -l)" 0
JG_REPORT_POST=true JG_FLOW="$here/core/fleet-flow/bin/jg-flow.sh" bash "$home/state/fleet-report.check.sh" > "$d/tick.log" 2>&1 || true
ck 'tick wrote one goal row' "$(grep -c . "$home/data/metrics/goal-meter.tsv" 2>/dev/null || echo 0)" 2
bash "$here/core/fleet-report/bin/fleet-report.sh" "$home" --goal --record >/dev/null
bash "$here/core/fleet-report/bin/fleet-report.sh" "$home" --goal --record >/dev/null
ck 'a second record the same day adds no row' "$(grep -c . "$home/data/metrics/goal-meter.tsv")" 2
[ "$fail" = 0 ] && echo 'jg-goal-meter: all ok'
exit "$fail"
