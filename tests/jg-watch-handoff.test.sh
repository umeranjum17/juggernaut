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

result=0
test_handoff || result=1
test_cleaned_lane || result=1
test_live_lane_replays signal || result=1
test_live_lane_replays stale || result=1
exit "$result"
