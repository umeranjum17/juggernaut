#!/usr/bin/env bash
# A real cycle handoff retains its beacon; cleaned lanes cannot replay alarms.
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

test_handoff() (
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
)

test_cleaned_lane() (
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
)

test_live_lane_replays() (
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
)

# A --take-over successor starts over the predecessor's beacon and runs a first
# scan longer than the grace. Its beacon must keep advancing through that scan,
# and a watcher killed afterwards must still raise the alarm exactly once.
test_takeover_first_scan() (
  local dir state arm1='' arm2='' i n p out max=0 age marks banners warnings
  dir=$(make_case takeover)
  state="$dir/state"
  # shellcheck disable=SC2031 # This case runs in its own subshell by design.
  export JG_HOME="$dir" JG_STATE_OVERRIDE="$state" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_CHECK_INTERVAL=0 JG_HEARTBEAT=999999 JG_GUARD_GRACE=3 JG_SUPERVISION_MODEL=persistent
  export PATH="$dir/fakebin:$PATH"
  # shellcheck source=bin/jg-wake-lib.sh
  . "$ROOT/bin/jg-wake-lib.sh"
  trap 'for p in $arm1 $arm2; do kill "$p" 2>/dev/null; done; kill "$(cat "$state/.watch.lock/pid" 2>/dev/null)" 2>/dev/null; wait 2>/dev/null || true' EXIT
  printf 'project=x\nkind=ship\n' > "$state/lane.meta"
  # Five one-second checks make a scan of about five seconds, longer than the
  # three-second grace, with a finished unit every second.
  for n in 1 2 3 4 5; do
    cat > "$state/slow$n.check.sh" <<SH
#!/usr/bin/env bash
sleep 1
printf x >> "$dir/units"
SH
    chmod 0700 "$state/slow$n.check.sh"
    "$ROOT/bin/jg-check-register.sh" "slow$n" >/dev/null || fail "could not register slow$n"
  done
  "$ROOT/bin/jg-watch-arm.sh" > "$dir/arm1.out" 2>&1 &
  arm1=$!
  for ((i=0; i<300; i++)); do
    grep -q '^watcher: started' "$dir/arm1.out" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '^watcher: started' "$dir/arm1.out" || fail "first arm never started: $(cat "$dir/arm1.out")"
  # A whole first scan has finished, so the predecessor's beacon is on disk.
  for ((i=0; i<300; i++)); do [ "$(wc -c < "$dir/units" 2>/dev/null || echo 0)" -ge 5 ] && break; sleep 0.1; done
  : > "$dir/units"
  "$ROOT/bin/jg-watch-arm.sh" --take-over "$arm1" > "$dir/arm2.out" 2>&1 &
  arm2=$!
  for ((i=0; i<300; i++)); do
    grep -q '^watcher: started' "$dir/arm2.out" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '^watcher: started' "$dir/arm2.out" || fail "take-over never started: $(cat "$dir/arm2.out")"
  # Sample the beacon across more than one grace of the successor's first scan.
  marks=0
  for ((i=0; i<45; i++)); do
    age=$(jg_path_age "$state/.last-watcher-beat")
    [ "$age" -le "$max" ] || max=$age
    if [ "$(wc -c < "$dir/units" 2>/dev/null || echo 0)" -ge 1 ]; then marks=$((marks + 1)); fi
    healthy "$dir" || [ "$(wc -c < "$dir/units" 2>/dev/null || echo 0)" -lt 1 ] \
      || fail "take-over successor read DOWN mid first scan (beacon ${age}s, grace 3s)"
    sleep 0.1
  done
  [ "$marks" -ge 20 ] || fail "fixture: the first scan did not run past the grace window ($marks samples)"
  echo "# beacon age peaked at ${max}s through the first scan (grace 3s)"
  [ "$max" -lt 3 ] || fail "beacon aged to ${max}s through the take-over's first scan"
  banners=$("$ROOT/bin/jg-guard.sh" 2>&1 >/dev/null | grep -c 'WATCHER DOWN')
  [ "$banners" -eq 0 ] || fail "guard alarmed on a live take-over successor"

  # The other direction: a killed watcher is still a real alarm, raised once.
  kill -KILL "$arm2" "$(cat "$state/.watch.lock/pid")" "$arm1" 2>/dev/null
  arm1='' arm2=''
  sleep 4
  banners=0 warnings=0
  for n in 1 2 3; do
    out=$("$ROOT/bin/jg-guard.sh" 2>&1 >/dev/null)
    banners=$((banners + $(printf '%s\n' "$out" | grep -c 'WATCHER DOWN')))
    warnings=$((warnings + $(printf '%s\n' "$out" | grep -c 'watcher still down')))
  done
  [ "$banners" -eq 1 ] || fail "killed watcher raised $banners full alarms across three checks, wanted 1"
  [ "$warnings" -eq 2 ] || fail "killed watcher repeats were not the one-line reminder ($warnings)"
  pass "take-over first scan keeps its beacon fresh; a killed watcher alarms once"
)

result=0
test_handoff || result=1
test_cleaned_lane || result=1
test_live_lane_replays signal || result=1
test_live_lane_replays stale || result=1
test_takeover_first_scan || result=1
exit "$result"
