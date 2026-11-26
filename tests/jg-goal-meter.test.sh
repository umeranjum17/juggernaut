#!/usr/bin/env bash
# Goal meter through its real callers: `fleet-report.sh <home> --goal` over a fixture home (3 landings, 2 blocked lines of
# which 1 is from a Recon lane, 1 leftover record), and the watcher's registered check that records the daily row.
# Names core/fleet-report/bin/fleet-report.sh, core/fleet-report/bin/goal-meter.sh and core/fleet-report/wiring.sh.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/wake-helpers.sh
. "$here/tests/wake-helpers.sh"
# shellcheck source=tests/lib-ledger.sh
. "$here/tests/lib-ledger.sh"
d=$(jg_test_tmproot jg-goal-meter)
TMP_ROOT=$d
home=$(make_case home); mkdir -p "$home/data/metrics" "$d/user" "$d/tmp"
ln -sn "$here/bin" "$home/bin"; ln -sn "$here/core" "$home/core"
ledger_home "$home"
NOW=$(date +%s)
fail=0
ck() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1: want '$3' got '$2'" >&2; fail=1; fi; }
# Three landings in the ledger: the minutes are the ready time to the landing, the gate seconds are the payload's.
C1=1111111111111111111111111111111111111111 C2=2222222222222222222222222222222222222222 C3=3333333333333333333333333333333333333333
ledger_landing "$home" lane-a "$C1" "$C1" $((NOW - 600)) $((NOW - 720)) queue 60 20 100 - -
ledger_landing "$home" lane-b "$C2" "$C2" $((NOW - 500)) $((NOW - 740)) gate - - 200 - -
ledger_landing "$home" lane-c "$C3" "$C3" $((NOW - 400)) $((NOW - 1600)) queue 900 200 300 - -
# Landings can name a worker lane instead of its ticket id. A row without a matching land event adds no timing.
JG_HOME=$home python3 -I "$here/core/item-store/adapters/bd_compat.py" update lane-b --set-metadata task=worker-b >/dev/null
awk 'BEGIN {FS=OFS="\t"} $1 == "lane-b" {$1="worker-b"} 1' "$home/data/trunk-landings.tsv" > "$d/landings"
mv "$d/landings" "$home/data/trunk-landings.tsv"
printf 'worker-b\tdemo\t%s\t%s\tfull\n' "$C1" $((NOW - 499)) >> "$home/data/trunk-landings.tsv"
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

# The watcher runs the registered check with its normal deadline and records one row a day.
JG_HOME=$home bash "$here/core/fleet-report/wiring.sh" > "$d/wire.log"
ck 'check shim is private' "$(stat -c %a "$home/state/fleet-report.check.sh")" 700
ck 'check is registered' "$([ -f "$home/state/fleet-report.check-trust" ] && echo yes || echo no)" yes
JG_HOME=$home bash "$here/core/fleet-report/wiring.sh" > "$d/wire2.log"
ck 'second wiring keeps no backup' "$(find "$home/state" -name '*bak-fleet-report*' | wc -l)" 0
cat > "$d/count-backlog.sh" <<'SH'
printf '%s\n' "$*" >> "$JG_BACKLOG_CALLS"
exec bash "$JG_REAL_BACKLOG" "$@"
SH
: > "$d/lookups"
printf '%s\n' "$d/board.json" > "$home/config/fleet-board"
touch "$home/state/.last-fast-check"
HOME="$d/user" XDG_CONFIG_HOME="$d/user/config" XDG_DATA_HOME="$d/user/data" TMPDIR="$d/tmp" PATH="$home/fakebin:$PATH" \
  JG_HOME="$home" JG_POLL=1 JG_CHECK_INTERVAL=300 JG_CHECK_TIMEOUT=30 JG_FAST_CHECK_INTERVAL=999999 \
  JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
  JG_TRUNK_LATENCY_BACKLOG="$d/count-backlog.sh" JG_BACKLOG_CALLS="$d/lookups" JG_REAL_BACKLOG="$here/bin/jg-backlog.sh" \
  JG_REPORT_POST=true bash "$here/bin/jg-watch.sh" > "$d/tick.log" 2>&1 &
watcher=$!
for ((i=0; i<600; i++)); do
  if [ -e "$home/state/.last-check" ] || ! kill -0 "$watcher" 2>/dev/null; then break; fi
  sleep 0.1
done
kill "$watcher" 2>/dev/null || true
wait_for_exit "$watcher" 100 >/dev/null 2>&1 || true
[ -e "$home/state/.last-check" ] || { cat "$d/tick.log" >&2; fail 'watcher did not finish its check sweep'; }
ck 'watcher captured a successful fleet-report check' "$([ -f "$home/state/.jg-check-output-fleet-report" ] &&
  [ ! -e "$home/state/.watch-check-failures/fleet-report" ] && echo yes)" yes
ck 'tick wrote one goal row' "$(grep -c . "$home/data/metrics/goal-meter.tsv" 2>/dev/null || echo 0)" 2
ck 'tick counted all four landings' "$(awk -F '\t' 'NR == 2 { print $3 }' "$home/data/metrics/goal-meter.tsv")" 4
ck 'tick reads all landings in one backlog invocation' "$(wc -l < "$d/lookups")" 1
bash "$here/core/fleet-report/bin/fleet-report.sh" "$home" --goal --record >/dev/null
bash "$here/core/fleet-report/bin/fleet-report.sh" "$home" --goal --record >/dev/null
ck 'a second record the same day adds no row' "$(grep -c . "$home/data/metrics/goal-meter.tsv")" 2
[ "$fail" = 0 ] && echo 'jg-goal-meter: all ok'
exit "$fail"
