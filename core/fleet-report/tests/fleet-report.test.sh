#!/usr/bin/env bash
# Host test table for fleet-report.sh and fleet-alerts-ledger.sh over fixture records.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
bin=$here/../bin
d=$(mktemp -d); trap 'rm -rf -- "$d"' EXIT
home=$d/home; mkdir -p "$home/data/metrics" "$home/state" "$home/config"
NOW=1793271000
printf '4\n' > "$home/config/lane-target"
{ printf 'home\ttask\tkind\tproject\tmodels\tstarted\tended\toutcome\tpr\n'
  printf 'm\ta\tship\talpha\tx\t1\t%s\tmerged\thttps://h/o/r/pull/1\n' $((NOW - 100))
  printf 'm\tb\tship\talpha\tx\t1\t%s\tmerged\thttps://h/o/r/pull/2\n' $((NOW - 200))
  printf 'm\tc\tship\tbeta\tx\t1\t%s\tmerged\thttps://h/o/r/pull/3\n' $((NOW - 300))
  printf 'm\td\tship\tbeta\tx\t1\t%s\tmerged\thttps://h/o/r/pull/4\n' $((NOW - 200000))
  printf 'm\te\tship\tbeta\tx\t1\t%s\tclosed\t-\n' $((NOW - 100)); } > "$home/data/metrics/task-outcomes.tsv"
cat > "$d/flow.json" <<J
{"lanes":[
 {"open":true,"stage":"working","task":"w1","home":"m","seconds_in_stage":10,"reason":"x"},
 {"open":true,"stage":"working","task":"w2","home":"m","seconds_in_stage":10,"reason":"PR https://h/o/r/pull/9"},
 {"open":true,"stage":"blocked","task":"s1","home":"m","seconds_in_stage":20000,"reason":"https://h/o/r/pull/1 https://h/o/r/pull/9"},
 {"open":true,"stage":"paused","task":"s2","home":"m","seconds_in_stage":500,"reason":"y"},
 {"open":false,"stage":"blocked","task":"gone","home":"m","seconds_in_stage":99999,"reason":"z"}],
 "queue":[{"hold_kind":"-","why":"unknown: dispatch admission not recorded"},
  {"hold_kind":"-","why":"unknown: dispatch admission not recorded"},
  {"hold_kind":"-","why":"dependency: q"},{"hold_kind":"captain","why":"hold: c"}]}
J
# Alert ledger: queue rows, then one clears, then a repeat of the same key stem.
q=$home/state/.wake-queue
printf '%s\t1\tcheck\tsquad-lead-supervision-L1-%s\tp\n' $((NOW - 1000)) $((NOW - 1000)) > "$q"
printf '%s\t2\tcheck\tother-alert\tp\n' $((NOW - 900)) >> "$q"
printf '%s\t3\theartbeat\thb\tp\n' $((NOW - 900)) >> "$q"
bash "$bin/fleet-alerts-ledger.sh" "$home" --now $((NOW - 800))
sed -i '1d' "$q"
bash "$bin/fleet-alerts-ledger.sh" "$home" --now $((NOW - 700))
printf '%s\t4\tcheck\tsquad-lead-supervision-L1-%s\tp\n' $((NOW - 600)) $((NOW - 600)) >> "$q"
bash "$bin/fleet-alerts-ledger.sh" "$home" --now $((NOW - 500))
bash "$bin/fleet-alerts-ledger.sh" "$home" --now $((NOW - 400))
rep=$d/report.json
bash "$bin/fleet-report.sh" "$home" --flow "$d/flow.json" --now $NOW --hours 24 --json > "$rep"
fail=0
ok() { # ok <label> <command...>
  local l=$1; shift
  if "$@"; then echo "PASS $l"; else echo "FAIL $l"; fail=1; fi
}
check() { # check <label> <jq expr> <expected>
  local got; got=$(jq -c "$2" "$rep")
  if [ "$got" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got $got want $3"; fail=1; fi
}
check 'merges per project, window only' '[.merges[]|"\(.project)=\(.merges)"]' '["alpha=2","beta=1"]'
check 'merge total' '.merges_total' '3'
check 'open PRs skip merged ones' '.open_prs' '["https://h/o/r/pull/9"]'
check 'lanes working vs target' '[.lanes.working,.lanes.target]' '[2,4]'
check 'ready not started counts unheld only' '.ready_not_started' '2'
check 'stuck by age, closed lane left out' '[.stuck[]|"\(.task)=\(.bucket)"]' '["s1=4-24h","s2=<1h"]'
check 'captain asks waiting' '.captain_asks' '1'
check 'alerts total, heartbeat left out' '.alerts.total' '3'
check 'repeat of a cleared alert is false' '.alerts.false_alarms' '1'
check 'supervision stem groups the lead id and epoch' '[.alerts.by_type[]|select(.type=="check:squad-lead-supervision")|.count]' '[2]'
check 'median clear time' '[.alerts.by_type[]|select(.type=="check:squad-lead-supervision")|.median_clear_secs]' '[300]'
check 'still queued alert is uncleared' '[.alerts.by_type[]|select(.type=="check:other-alert")|.uncleared]' '[1]'
ok 'text line' grep -q '^Merges: 3 (alpha 2, beta 1)$' < <(bash "$bin/fleet-report.sh" "$home" --flow "$d/flow.json" --now $NOW)
# post: stub the board tool and confirm card key, files and a bounded failure.
mkdir -p "$d/board"; echo "$d/board/board.json" > "$home/config/fleet-board"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/post.args"\n' "$d" > "$d/stub"; chmod +x "$d/stub"
JG_REPORT_POST=$d/stub bash "$bin/fleet-report.sh" "$home" post --flow "$d/flow.json" --now $NOW --hours 4
ok 'post card' grep -q -- '--kind report' "$d/post.args"
# tick: posts both cards once, then stays quiet until the gap passes.
rm -f "$d/post.args"
JG_FLOW=/nonexistent JG_REPORT_POST=$d/stub bash "$bin/fleet-report.sh" "$home" tick --now $NOW
ok 'tick marks 4h' test -f "$home/state/.fleet-report-4h.last"
ok 'tick marks 24h' test -f "$home/state/.fleet-report-24h.last"
rm -f "$d/post.args"
JG_FLOW=/nonexistent JG_REPORT_POST=$d/stub bash "$bin/fleet-report.sh" "$home" tick --now $((NOW + 60))
ok 'tick quiet inside gap' test ! -e "$d/post.args"
exit "$fail"
