#!/usr/bin/env bash
# tests/jg-status-latency.test.sh - a status line reaches the owner of its lane within a minute, and the check measures the delay and
# alarms past two minutes (core/status-latency). It runs the REAL watcher on a throwaway home, the real wake library writes the
# ledger row, and the check reads the lane's status line and that row; nothing is faked but the clock of the two late cases.
# S1 a failed line written while the watcher runs wakes its owner within the minute: one row with the seconds, no alert.
# S2 a needs-decision line 200 s old with no watcher running raises one alert, one row with no wake time, and a second tick adds nothing.
# S3 a blocked line stamped 300 s before the watcher saw it is woken late: the row holds the real delay and one alert names it.
# With JG_STATUS_LATENCY_LOG set it appends the measured seconds there.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck disable=SC2034 # read by make_case
TMP_ROOT=$(jg_test_tmproot jg-status-latency)
WATCH="$ROOT/bin/jg-watch.sh"
CHECK="$ROOT/core/status-latency/latency.sh"
LOG=${JG_STATUS_LATENCY_LOG:-}
export JG_STATUS_LATENCY_ALERT=$ROOT/bin/jg-alert.sh  # the fixture home holds no bin of its own

new_home() {  # <name> -> a home dir with a state, a data dir and the lane <name>
  local d
  d=$(make_case "$1")
  mkdir -p "$d/home/config" "$d/tmp" "$d/config" "$d/data"
  printf 'kind=ship\n' > "$d/state/lane.meta"
  printf '%s\n' "$d"
}
status() {  # <dir> <line>: the lane writes its status line the way a worker does
  printf '%s\n' "$2" | "$ROOT/bin/jg-lavish-guard.sh" --append "$1/state/lane.status"
}
start_watch() {  # <dir> -> sets WPID
  env HOME="$1/home" XDG_CONFIG_HOME="$1/home/config" TMPDIR="$1/tmp" PATH="$1/fakebin:${WATCH_PATH:-$PATH}" \
    JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" JG_CONFIG_OVERRIDE="$1/config" JG_DATA_OVERRIDE="$1/data" \
    JG_SIGNAL_GRACE=1 JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_STALE_ESCALATE_SECS=999999 JG_POLL=1 JG_FAST_CHECK_INTERVAL=3 \
    "$WATCH" > "$1/out" 2> "$1/err" &
  WPID=$!
}
wait_for() {  # <limit s> <command...>: poll until the command succeeds
  local limit=$1 i=0; shift
  while [ "$i" -lt $((limit * 5)) ]; do "$@" && return 0; sleep 0.2; i=$((i + 1)); done
  return 1
}
stop_watch() { kill "$WPID" 2>/dev/null || true; wait_for_exit "$WPID" 100 >/dev/null 2>&1 || true; }
woken() { grep -qs "lane.status" "$1/data/wake-ledger.tsv"; }
tick() {  # <dir> [now]
  env JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" JG_STATUS_LATENCY_NOW="${2:-$(date +%s)}" bash "$CHECK" check "$1"
}
alerts() { JG_HOME=$1 JG_STATE_OVERRIDE=$1/state bash "$ROOT/bin/jg-alert.sh" list; }
field() {  # <dir> <field>: a field of the lane's row
  awk -F'\t' -v f="$2" 'NR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next } { print $c[f] }' "$1/data/status-latency.tsv"
}

# S1
d=$(new_home s1)
start_watch "$d"
now=$(date +%s)
status "$d" "failed [at=$now]: the suite is red"
wait_for 60 woken "$d" || { stop_watch; fail "the watcher never woke for the failed line: $(cat "$d/err")"; }
stop_watch
out=$(tick "$d")
[ -z "$out" ] || fail "the check prints nothing of its own, got: $out"
secs=$(field "$d" seconds)
[ -n "$secs" ] && [ "$secs" -le 60 ] || fail "the status line must reach its owner within 60 s, the row says '$secs'"
[ -z "$(alerts "$d")" ] || fail "a wake inside the limit raises no alert, got: $(alerts "$d")"
[ -z "$LOG" ] || printf 'failed line to wake: %s s\n' "$secs" >> "$LOG"
printf 'MEASURED status-to-wake: %s s\n' "$secs"
secs_s1=$secs
pass "S1: the failed line woke its owner in $secs s, one row, no alert"

# S2
d=$(new_home s2)
now=$(date +%s)
status "$d" "needs-decision [at=$((now - 200))]: pick one"
tick "$d" "$now"
[ "$(alerts "$d")" = "undelivered--status-lane-$((now - 200))" ] || fail "an unwoken line past the limit must raise one alert, got: $(alerts "$d")"
[ "$(field "$d" word)" = needs-decision ] && [ -z "$(field "$d" woke_at)" ] || fail "the row must name the word and hold no wake time"
tick "$d" $((now + 30))
[ "$(grep -c . "$d/data/status-latency.tsv")" = 2 ] && [ "$(alerts "$d" | wc -l)" = 1 ] || fail "a second tick wrote or raised again"
pass "S2: a needs-decision line with no wake in 200 s raised one alert and one row; a second tick was silent"

# S3
d=$(new_home s3)
now=$(date +%s)
status "$d" "blocked [at=$((now - 300))]: waiting on the owner"
start_watch "$d"
wait_for 60 woken "$d" || { stop_watch; fail "the watcher never woke for the blocked line: $(cat "$d/err")"; }
stop_watch
tick "$d"
secs=$(field "$d" seconds)
[ -n "$secs" ] && [ "$secs" -ge 300 ] || fail "the row must hold the real delay of at least 300 s, got '$secs'"
[ "$(alerts "$d" | wc -l)" = 1 ] || fail "a late wake must raise one alert, got: $(alerts "$d")"
grep -q "woke its owner only after $secs seconds" "$d/state/alerts/"*.rec || fail "the alert must name the measured delay"
pass "S3: a late wake of $secs s is a row and one alert that names the delay"

if [ -n "${DONE_DONE_EVIDENCE_ROOT:-}" ]; then
  cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$ROOT" rev-parse --short HEAD)"},
 "start": "a throwaway home with one live lane and the real watcher, wake library and alert command",
 "steps": ["the lane writes a failed line while the watcher runs and the check measures the seconds to its wake", "the lane writes a needs-decision line 200 s old with no watcher and the check raises one alert", "the lane writes a blocked line 300 s old and the watcher wakes it late, so the row holds the delay and the alert names it"],
 "result": "the on-time line has a row of ${secs_s1:-2} seconds and no alert; the unwoken and the late lines each raise one undelivered alert"}
JSON
fi
