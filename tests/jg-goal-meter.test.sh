#!/usr/bin/env bash
# Goal meter through its real callers: `fleet-report.sh <home> --goal` over a fixture home (3 landings, 2 blocked lines of
# which 1 is from a Recon lane, 1 leftover record), and core/fleet-report/wiring.sh, which registers the check that records
# the row. Names core/fleet-report/bin/fleet-report.sh, core/fleet-report/bin/goal-meter.sh and core/fleet-report/wiring.sh.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$here/tests/lib.sh"
# shellcheck source=tests/lib-ledger.sh
. "$here/tests/lib-ledger.sh"
d=$(jg_test_tmproot jg-goal-meter)
home=$d/home; mkdir -p "$home/data/metrics"
ln -sn "$here/bin" "$home/bin"; ln -sn "$here/core" "$home/core"
ledger_home "$home"
NOW=1794000000
fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: want '$3' got '$2'" >&2; fail=1; fi; }
# Three landings in the ledger: the minutes are the ready time to the landing, the gate seconds are the payload's.
C1=1111111111111111111111111111111111111111 C2=2222222222222222222222222222222222222222 C3=3333333333333333333333333333333333333333
ledger_landing "$home" lane-a "$C1" "$C1" $((NOW - 600)) $((NOW - 720)) queue 60 20 100 - -
ledger_landing "$home" lane-b "$C2" "$C2" $((NOW - 500)) $((NOW - 740)) gate - - 200 - -
ledger_landing "$home" lane-c "$C3" "$C3" $((NOW - 400)) $((NOW - 1600)) queue 900 200 300 - -
printf 'kind=ship\n' > "$home/state/lane-a.meta"; printf 'kind=ship\n' > "$home/state/live.meta"; printf 'kind=scout\n' > "$home/state/recon-x.meta"
row() { printf '{"at":%s,"kind":"status","from":"%s","text":"%s [at=%s]: x"}\n' "$4" "$1" "$2" "$3"; }
{ row lane-w blocked $((NOW - 3000)) $((NOW - 3000)); row lane-w resolved $((NOW - 2800)) $((NOW - 2800))
  row recon-x needs-decision $((NOW - 2000)) $((NOW - 2000)); } > "$home/state/chat.jsonl"

out=$(bash "$here/core/fleet-report/bin/fleet-report.sh" "$home" --goal --now "$NOW" --json)
for pair in '.landings.count=3' '.landings.within_5_min=2' '.landings.pct_within_5=67' '.landings.pass=false' '.gate_p90_secs=200' \
  '.stops.count=1' '.stops.answered_in_300_s=1' '.stops.median_answer_secs=200' '.stops.never_closed=0' \
  '.stops.recon_lines=1' '.stops.recon_lanes=1' '.leftover_records=1'; do
  ck "${pair%%=*}" "$(jq -c "${pair%%=*}" <<<"$out")" "${pair#*=}"
done
# The meter follows the ledger: one more landing in it moves the count, the landings inside 5 minutes and the gate p90.
C4=4444444444444444444444444444444444444444
ledger_landing "$home" lane-d "$C4" "$C4" $((NOW - 300)) $((NOW - 420)) gate - - 900 - -
out2=$(bash "$here/core/fleet-report/bin/fleet-report.sh" "$home" --goal --now "$NOW" --json)
ck 'edited ledger: landings' "$(jq -c .landings.count <<<"$out2")" 4
ck 'edited ledger: inside 5 min' "$(jq -c .landings.within_5_min <<<"$out2")" 3
ck 'edited ledger: gate p90' "$(jq -c .gate_p90_secs <<<"$out2")" 300
text=$(bash "$here/core/fleet-report/bin/fleet-report.sh" "$home" --goal --now "$NOW")
case $text in *'Landings inside 5 min: 3 of 4 (75%)'*'Recon lines: 1 from 1 lanes'*'Leftover records: 1'*) echo 'ok - text rows' ;; *) echo "not ok - text rows: $text" >&2; fail=1 ;; esac

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
