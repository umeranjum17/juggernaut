#!/usr/bin/env bash
# A real cycle handoff retains its beacon and never runs two arms on one cycle;
# cleaned lanes cannot replay alarms.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
WATCH="$ROOT/bin/jg-watch.sh"
TMP_ROOT=$(jg_test_tmproot jg-watch-handoff)

wait_file() { # <path>
  local i
  for ((i=0; i<150; i++)); do
    [ ! -e "$1" ] || return 0
    sleep 0.1
  done
  fail "timed out waiting for $1"
}

start_cycle() { # <dir>
  PATH="$1/fakebin:$PATH" JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" \
    JG_POLL=0.2 JG_SIGNAL_GRACE=0 JG_CHECK_INTERVAL=0 JG_HEARTBEAT=999999 \
    JG_SQUAD_LEAD_WAKE_STALL_SECS=1 JG_WATCH_HANDLING_SUCCESSOR=1 \
    "$WATCH" > "$1/watch.out" 2> "$1/watch.err" &
  pid=$!
}

hold_scan() { # <dir>
  cat > "$1/state/hold.check.sh" <<SH
#!/usr/bin/env bash
: > "$1/holding"
while [ ! -e "$1/release" ]; do sleep 0.1; done
SH
  chmod 0700 "$1/state/hold.check.sh"
  JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" "$ROOT/bin/jg-check-register.sh" hold >/dev/null \
    || fail "could not register bounded scan check"
}

healthy() { # <dir>
  JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/bin/jg-wake-lib.sh"
    jg_watcher_healthy "$2/state" "$1/bin/jg-watch.sh" 300 "$2"
  ' _ "$ROOT" "$1"
}

test_handoff() { (
  local dir pid='' monitor='' i stamp
  dir=$(make_case handoff)
  # shellcheck disable=SC2030 # Each case runs in its own subshell by design.
  export JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state"
  # shellcheck source=bin/jg-wake-lib.sh
  . "$ROOT/bin/jg-wake-lib.sh"
  trap '[ -z "$monitor" ] || kill "$monitor" 2>/dev/null; [ -z "$pid" ] || kill "$pid" 2>/dev/null; wait 2>/dev/null || true' EXIT
  printf 'done: completed lane\n' > "$dir/state/lane.status"
  start_cycle "$dir"
  wait_for_exit "$pid" 150 || fail "first cycle did not deliver the completed lane"
  pid=''
  grep -q '^signal:' "$dir/watch.out" || fail "first cycle had no signal"
  [ -e "$dir/state/.last-watcher-beat" ] || fail "actionable predecessor left no beacon"
  stamp=$(jg_path_mtime "$dir/state/.last-watcher-beat")
  # The handoff is already being handled, so only the successor's scan is due.
  rm -f "$dir/state/lane.status" "$dir/state/.wake-queue"
  hold_scan "$dir"
  (
    while [ ! -e "$dir/release" ]; do
      [ -e "$dir/state/.last-watcher-beat" ] || : > "$dir/gap"
      sleep 0.01
    done
  ) &
  monitor=$!
  start_cycle "$dir"
  wait_file "$dir/holding"
  [ -e "$dir/state/.last-watcher-beat" ] || fail "successor deleted the predecessor beacon during its scan"
  [ ! -e "$dir/gap" ] || fail "reader observed a beacon gap on handoff"
  healthy "$dir" || fail "live successor was DOWN during its first scan"
  [ "$(jg_path_mtime "$dir/state/.last-watcher-beat")" = "$stamp" ] || fail "successor renewed beacon before scan progress"
  # Keeping the previous beacon must not freshen it or hide a stalled scan.
  touch -t 200001010000 "$dir/state/.last-watcher-beat"
  if healthy "$dir"; then fail "stalled successor was reported healthy"; fi
  : > "$dir/release"
  for ((i=0; i<150; i++)); do
    healthy "$dir" && break
    sleep 0.1
  done
  healthy "$dir" || fail "completed successor scan did not renew the beacon"
  kill "$pid"
  wait_for_exit "$pid" 150 >/dev/null 2>&1 || true
  pid=''
  if healthy "$dir"; then fail "dead successor with retained beacon was healthy"; fi
  pass "handoff has no missing beacon or false DOWN; stalled and dead cycles stay DOWN"
); }

test_cleaned_lane() { (
  local dir pid='' i
  dir=$(make_case cleaned)
  trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null; wait 2>/dev/null || true' EXIT
  printf 'window=crew:gone\nbackend=tmux\nkind=ship\n' > "$dir/state/lane.meta"
  printf 'done: finished lane\n' > "$dir/state/lane.status"
  mkdir -p "$dir/state/lane.inbox"
  # A scan can retain this sidecar after cleanup removes the owning task.
  printf 'crew:gone\ttmux\n' > "$dir/state/.tracked-crew_gone"
  rm -f "$dir/state/lane.meta" "$dir/state/lane.status"
  rmdir "$dir/state/lane.inbox"
  append_wake "$dir/state" stale crew:gone 'stale: crew:gone'
  append_wake "$dir/state" signal lane.status "signal: $dir/state/lane.status"
  hold_scan "$dir"
  : > "$dir/release"
  for cycle in 1 2; do
    start_cycle "$dir"
    wait_file "$dir/state/.last-watcher-beat"
    for ((i=0; i<35; i++)); do
      [ ! -s "$dir/watch.out" ] || fail "cleaned lane raised an alarm in cycle $cycle: $(cat "$dir/watch.out")"
      sleep 0.1
    done
    kill "$pid"
    wait_for_exit "$pid" 150 >/dev/null 2>&1 || true
    pid=''
  done
  [ ! -s "$dir/state/.wake-queue" ] || fail "cleaned lane left replayable alarms"
  pass "cleaned lane emits no new or replayed stale/signal alarm across cycles"
); }

test_live_lane_replays() { (
  local kind=$1 key dir pid=''
  dir=$(make_case "live-$kind")
  trap '[ -z "$pid" ] || kill "$pid" 2>/dev/null; wait 2>/dev/null || true' EXIT
  # An unreadable/missing status alone is not cleanup: metadata still owns it.
  printf 'kind=ship\nwindow=crew:live\nbackend=tmux\n' > "$dir/state/lane.meta"
  printf 'crew_live\n' > "$dir/state/.pruned-panes"
  key=lane.status; [ "$kind" != stale ] || key=crew:live
  append_wake "$dir/state" "$kind" "$key" "$kind: $key"
  start_cycle "$dir"
  wait_for_exit "$pid" 150 || fail "live lane alarm did not replay"
  pid=''
  grep -q "^$kind: $key" "$dir/watch.out" || fail "live lane alarm was suppressed"
  [ -s "$dir/state/.wake-queue" ] || fail "live lane alarm was consumed"
  pass "a live task with a missing status still replays its $kind alarm"
); }

# Start an arm in the current case's home and wait for its status line.
# Sets ARM to its pid; its output goes to <out>.
start_arm() { # <out> [arm arguments...]
  local out=$1 i
  shift
  "$ROOT/bin/jg-watch-arm.sh" "$@" > "$out" 2>&1 &
  # shellcheck disable=SC2031 # Each case starts its own background jobs in its own subshell.
  ARM=$!
  # The arm prints its verdict once the first scan completes, inside its own confirmation budget; the bound only stops a hang.
  for ((i=0; i<900; i++)); do
    grep -qE '^watcher: (started|attached|FAILED)' "$out" 2>/dev/null && return 0
    sleep 0.1
  done
}

# The reasons the cycle-exit ledger of <state> records, one per line.
cycle_reasons() { # <state>
  sed -n 's/.*	reason=\([^	]*\).*/\1/p' "$1/.watch-cycle-exits.log" 2>/dev/null
}

# Eight two-second checks make a scan of about sixteen seconds, longer than the
# fifteen-second grace, with a finished unit every two seconds. The grace is 15 s
# because the real beacon aged to 5 to 8 s through this scan at host load 15 to 35.
slow_scan() { # <dir>
  local n
  for n in 1 2 3 4 5 6 7 8; do
    cat > "$1/state/slow$n.check.sh" <<SH
#!/usr/bin/env bash
sleep 2
printf x >> "$1/units"
SH
    chmod 0700 "$1/state/slow$n.check.sh"
    "$ROOT/bin/jg-check-register.sh" "slow$n" >/dev/null || fail "could not register slow$n"
  done
}

# A --take-over hands the running cycle to the new arm instead of stopping it
# (the live churn: every take-over killed a healthy watcher seconds into its
# life and started a cold one). The watcher, its lock and its beacon never
# change hands, so across more than one grace the beacon stays fresh, the
# supervision predicate Main's lead check reads never reports the home down,
# and no row records a taken-over or killed cycle. A watcher killed afterwards
# must still raise the alarm exactly once.
test_takeover_adopts_the_running_cycle() { (
  local dir state arm1='' arm2='' p watcher i out max=0 age banners warnings needed=0
  dir=$(make_case takeover)
  state="$dir/state"
  # shellcheck disable=SC2030,SC2031 # This case runs in its own subshell by design.
  export JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_CHECK_INTERVAL=0 JG_HEARTBEAT=999999 JG_GUARD_GRACE=15 JG_SUPERVISION_MODEL=persistent
  # shellcheck disable=SC2030,SC2031 # This case runs in its own subshell by design.
  export PATH="$dir/fakebin:$PATH"
  # shellcheck source=bin/jg-wake-lib.sh
  . "$ROOT/bin/jg-wake-lib.sh"
  # shellcheck source=bin/jg-supervision-lib.sh
  . "$ROOT/bin/jg-supervision-lib.sh"
  trap 'for p in $arm1 $arm2; do kill "$p" 2>/dev/null; done; kill "$(cat "$state/.watch.lock/pid" 2>/dev/null)" 2>/dev/null; wait 2>/dev/null || true' EXIT
  printf 'project=x\nkind=ship\n' > "$state/lane.meta"
  slow_scan "$dir"
  start_arm "$dir/arm1.out"
  arm1=$ARM
  grep -q '^watcher: started' "$dir/arm1.out" || fail "first arm never started: $(cat "$dir/arm1.out")"
  watcher=$(cat "$state/.watch.lock/pid")
  start_arm "$dir/arm2.out" --take-over "$arm1"
  arm2=$ARM
  grep -qx "watcher: attached pid=$watcher (beacon [0-9]*s)" "$dir/arm2.out" \
    || fail "take-over did not adopt the running watcher $watcher: $(cat "$dir/arm2.out")"
  wait_for_exit "$arm1" 50 || fail "the arm that handed its cycle over still runs"
  arm1=''
  # Sample across more than one grace while the adopted watcher keeps scanning.
  : > "$dir/units"
  for ((i=0; i<200; i++)); do
    age=$(jg_path_age "$state/.last-watcher-beat")
    [ "$age" -le "$max" ] || max=$age
    healthy "$dir" || fail "adopted watcher read DOWN (beacon ${age}s, grace 15s)"
    jg_supervision_status "$state" 15
    [ "$JG_SUP_NEEDED" = false ] || needed=$((needed + 1))
    if jg_supervision_unhealthy "$state" 15; then
      fail "supervision read down across the hand-over (beacon ${age}s, grace 15s)"
    fi
    sleep 0.1
  done
  [ "$needed" -eq 200 ] || fail "fixture: the home did not need supervision throughout ($needed of 200 samples)"
  [ "$(wc -c < "$dir/units")" -ge 8 ] || fail "fixture: the adopted watcher did not keep scanning"
  [ "$(cat "$state/.watch.lock/pid")" = "$watcher" ] || fail "the watcher lock changed hands"
  kill -0 "$arm2" 2>/dev/null || fail "the taking arm stopped following the cycle: $(cat "$dir/arm2.out")"
  echo "# beacon age peaked at ${max}s across the hand-over (grace 15s)"
  [ "$max" -lt 15 ] || fail "beacon aged to ${max}s across the hand-over"
  ! cycle_reasons "$state" | grep -q -e '^taken-over' -e '^signal-exit$' \
    || fail "a take-over still stopped a cycle: $(cycle_reasons "$state" | tr '\n' ' ')"
  grep -q "^arm_pid=[0-9]*	watcher_pid=$watcher	.*	reason=handed-over	.*	successor=attached:$watcher" "$state/.watch-cycle-exits.log" \
    || fail "the hand-over row does not name the adopted watcher: $(cat "$state/.watch-cycle-exits.log")"
  banners=$("$ROOT/bin/jg-guard.sh" 2>&1 >/dev/null | grep -c 'WATCHER DOWN')
  [ "$banners" -eq 0 ] || fail "guard alarmed on an adopted watcher"

  # The other direction: a killed watcher is still a real alarm, raised once.
  kill -KILL "$arm2" "$watcher" 2>/dev/null
  arm2=''
  sleep 7
  banners=0 warnings=0
  for i in 1 2 3; do
    out=$("$ROOT/bin/jg-guard.sh" 2>&1 >/dev/null)
    banners=$((banners + $(printf '%s\n' "$out" | grep -c 'WATCHER DOWN')))
    warnings=$((warnings + $(printf '%s\n' "$out" | grep -c 'watcher still down')))
  done
  [ "$banners" -eq 1 ] || fail "killed watcher raised $banners full alarms across three checks, wanted 1"
  [ "$warnings" -eq 2 ] || fail "killed watcher repeats were not the one-line reminder ($warnings)"
  pass "take-over adopts the running cycle: beacon fresh, supervision never down, no cycle stopped; a killed watcher alarms once"
); }

# An attached arm whose watcher delivered a wake, with no successor coming,
# reports that wake within the hand-off window. It used to wait the whole
# confirmation budget, which grows by a check timeout per registered check
# (here 258 s; 837 s in a live lead home), while nothing watched the home.
test_attached_arm_reports_a_delivered_wake_promptly() { (
  local dir state arm1='' arm2='' p started elapsed
  dir=$(make_case attached-delivered)
  state="$dir/state"
  # shellcheck disable=SC2030,SC2031 # This case runs in its own subshell by design.
  export JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_CHECK_INTERVAL=0 JG_HEARTBEAT=999999 JG_GUARD_GRACE=15 JG_SUPERVISION_MODEL=persistent
  # shellcheck disable=SC2030,SC2031 # This case runs in its own subshell by design.
  export PATH="$dir/fakebin:$PATH"
  trap 'for p in $arm1 $arm2; do kill "$p" 2>/dev/null; done; kill "$(cat "$state/.watch.lock/pid" 2>/dev/null)" 2>/dev/null; wait 2>/dev/null || true' EXIT
  slow_scan "$dir"
  start_arm "$dir/arm1.out"
  arm1=$ARM
  grep -q '^watcher: started' "$dir/arm1.out" || fail "first arm never started: $(cat "$dir/arm1.out")"
  start_arm "$dir/arm2.out"
  arm2=$ARM
  grep -q '^watcher: attached' "$dir/arm2.out" || fail "second arm did not attach: $(cat "$dir/arm2.out")"
  printf 'done: finished lane\n' > "$state/lane.status"
  wait_for_exit "$arm1" 600 || fail "the owner never delivered the lane"
  arm1=''
  grep -q '^signal:' "$dir/arm1.out" || fail "fixture: the owner's close was not the lane signal: $(cat "$dir/arm1.out")"
  started=$(date +%s)
  wait_for_exit "$arm2" 600 || fail "the attached arm never reported the delivered wake"
  arm2=''
  elapsed=$(( $(date +%s) - started ))
  echo "# the attached arm reported ${elapsed}s after the owner's close (hand-off window 15s)"
  grep -q '^signal:' "$dir/arm2.out" || fail "the attached arm did not report the delivered wake: $(cat "$dir/arm2.out")"
  [ "$elapsed" -le 25 ] || fail "the attached arm held the delivered wake ${elapsed}s"
  pass "an attached arm reports a delivered wake within the hand-off window, not the confirmation budget"
); }

# A detached arm nobody reads (JG_WATCH_ARM_NO_FOLLOW) confirms a live cycle and
# leaves instead of following it as a second arm.
test_no_follow_arm_does_not_race_the_owner() { (
  local dir state arm1='' arm2='' p watcher
  dir=$(make_case no-follow)
  state="$dir/state"
  # shellcheck disable=SC2030,SC2031 # This case runs in its own subshell by design.
  export JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_CHECK_INTERVAL=0 JG_HEARTBEAT=999999 JG_GUARD_GRACE=15 JG_SUPERVISION_MODEL=persistent
  # shellcheck disable=SC2030,SC2031 # This case runs in its own subshell by design.
  export PATH="$dir/fakebin:$PATH"
  trap 'for p in $arm1 $arm2; do kill "$p" 2>/dev/null; done; kill "$(cat "$state/.watch.lock/pid" 2>/dev/null)" 2>/dev/null; wait 2>/dev/null || true' EXIT
  start_arm "$dir/arm1.out"
  arm1=$ARM
  grep -q '^watcher: started' "$dir/arm1.out" || fail "first arm never started: $(cat "$dir/arm1.out")"
  watcher=$(cat "$state/.watch.lock/pid")
  JG_WATCH_ARM_NO_FOLLOW=1 start_arm "$dir/arm2.out"
  arm2=$ARM
  wait_for_exit "$arm2" 50 || fail "the no-follow arm stayed attached as a second arm"
  arm2=''
  grep -qx "watcher: attached pid=$watcher (beacon [0-9]*s)" "$dir/arm2.out" \
    || fail "the no-follow arm did not confirm the live cycle: $(cat "$dir/arm2.out")"
  [ "$(ls -A "$state/.watch-arms")" = "$arm1" ] || fail "an arm other than the owner is recorded: $(ls -A "$state/.watch-arms")"
  kill -0 "$watcher" 2>/dev/null || fail "the no-follow arm stopped the owner's watcher"
  pass "a no-follow arm confirms a live cycle and leaves it to its owner"
); }

result=0
test_handoff || result=1
test_cleaned_lane || result=1
test_live_lane_replays signal || result=1
test_live_lane_replays stale || result=1
test_takeover_adopts_the_running_cycle || result=1
test_attached_arm_reports_a_delivered_wake_promptly || result=1
test_no_follow_arm_does_not_race_the_owner || result=1
exit "$result"
