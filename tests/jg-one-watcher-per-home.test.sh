#!/usr/bin/env bash
# tests/jg-one-watcher-per-home.test.sh - a home has exactly one live watcher, and
# a slow beat under host load is not a failure (jg-7v6uw-s50). Real watchers and
# real arms run against a throwaway state; load is simulated through
# JG_HOST_LOAD / JG_HOST_CPUS, the seam bin/jg-wake-lib.sh jg_host_load_scale reads.
# shellcheck disable=SC2030,SC2031 # Test subshells intentionally isolate exported fixture settings.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/jg-watch.sh"
WATCH_ARM="$ROOT/bin/jg-watch-arm.sh"
# shellcheck disable=SC2034 # make_case reads TMP_ROOT.
TMP_ROOT=$(jg_test_tmproot jg-one-watcher-tests)

# start_watcher <dir>: a real watcher holding the lock; sets WPID.
start_watcher() {
  local dir=$1 i=0
  PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" JG_POLL=5 JG_SIGNAL_GRACE=1 \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  WPID=$!
  while [ "$i" -lt 600 ]; do
    [ "$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)" = "$WPID" ] && [ -e "$dir/state/.last-watcher-beat" ] \
      && [ -s "$dir/state/.watch.lock/scan-complete" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "seed watcher did not take the lock"
}

# slow_beat <dir> <pid> <seconds>: freeze the watcher and age its beat, as a
# starved host does; the pid stays alive.
slow_beat() {
  kill -STOP "$2" 2>/dev/null || fail "could not stop the watcher"
  touch -d "@$(( $(date +%s) - $3 ))" "$1/state/.last-watcher-beat"
}

stop_watcher() {
  kill -CONT "$1" 2>/dev/null || true
  kill -TERM "$1" 2>/dev/null || true
  wait_for_exit "$1" 80 || true
}

# arm_for <dir> <out> [env...]: run a real arm in the background; sets APID.
arm_for() {
  local dir=$1 out=$2
  shift 2
  env PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" JG_POLL=5 JG_SIGNAL_GRACE=1 \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 JG_ARM_ATTACH_POLL=0.1 JG_ARM_CONFIRM_TIMEOUT=60 "$@" \
    "$WATCH_ARM" > "$out" 2>&1 &
  APID=$!
}

wait_for_line() {
  local file=$1 pattern=$2 i=0
  while [ "$i" -lt 600 ]; do
    grep -Eq "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_arm_attaches_to_a_live_watcher_and_starts_nothing() {
  local dir out
  dir=$(make_case one-attach)
  out="$dir/arm.out"
  start_watcher "$dir"
  arm_for "$dir" "$out"
  wait_for_line "$out" "^watcher: attached pid=$WPID" || fail "arm did not attach: $(cat "$out")"
  ! grep -q 'watcher: started' "$out" || fail "arm started a second watcher"
  [ "$(cat "$dir/state/.watch.lock/pid")" = "$WPID" ] || fail "arm disturbed the lock"
  kill -TERM "$APID" 2>/dev/null || true
  wait "$APID" 2>/dev/null || true
  stop_watcher "$WPID"
  pass "an arm request against a live watcher attaches and starts nothing"
}

test_slow_beat_under_load_is_not_a_failure() {
  local dir out status=0
  dir=$(make_case one-slow)
  out="$dir/arm.out"
  start_watcher "$dir"
  slow_beat "$dir" "$WPID" 900   # fifteen minutes late, pid alive
  # Simulated load 30 on 4 CPUs: the beat limit stretches past the delay.
  JG_HOST_LOAD=30 JG_HOST_CPUS=4 PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" JG_POLL=5 \
    "$WATCH" > "$dir/rearm.out" 2> "$dir/rearm.err" || status=$?
  [ "$status" -eq 0 ] || fail "re-arm of a slow live watcher failed ($status): $(cat "$dir/rearm.err")"
  grep -Fx "watcher: already running pid $WPID" "$dir/rearm.out" >/dev/null \
    || fail "re-arm did not report the live watcher: $(cat "$dir/rearm.out")"
  arm_for "$dir" "$out" JG_HOST_LOAD=30 JG_HOST_CPUS=4
  wait_for_line "$out" "^watcher: attached pid=$WPID" || fail "arm did not attach under load: $(cat "$out")"
  ! grep -Eq 'FAILED|started' "$out" || fail "arm raised a failure for a slow beat: $(cat "$out")"
  [ "$(cat "$dir/state/.watch.lock/pid")" = "$WPID" ] || fail "slow watcher lost its lock"
  kill -TERM "$APID" 2>/dev/null || true
  wait "$APID" 2>/dev/null || true
  stop_watcher "$WPID"
  pass "a beat 15 minutes late under load 30 with the pid alive attaches and raises no failure"
}

test_slow_beat_below_stall_bound_is_not_refused_without_load() {
  local dir status=0
  dir=$(make_case one-unloaded)
  start_watcher "$dir"
  slow_beat "$dir" "$WPID" 400   # past the 300s grace, under the 900s stall bound
  JG_HOST_LOAD=0 PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" JG_POLL=5 \
    "$WATCH" > "$dir/rearm.out" 2> "$dir/rearm.err" || status=$?
  [ "$status" -eq 0 ] || fail "live holder below the stall bound refused the re-arm: $(cat "$dir/rearm.err")"
  grep -Fx "watcher: already running pid $WPID" "$dir/rearm.out" >/dev/null || fail "no already-running line"
  stop_watcher "$WPID"
  pass "a live holder below the stall bound reads as already running, never as an inspect-me failure"
}

test_dead_pid_with_stale_beat_is_reclaimed() {
  local dir out dead i=0
  dir=$(make_case one-dead)
  start_watcher "$dir"
  stop_watcher "$WPID"
  dead=$(dead_pid)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$dead" > "$dir/state/.watch.lock/pid"
  touch -d "@$(( $(date +%s) - 3600 ))" "$dir/state/.last-watcher-beat"
  out="$dir/arm.out"
  arm_for "$dir" "$out" JG_HOST_LOAD=30 JG_HOST_CPUS=4
  wait_for_line "$out" '^watcher: started pid=' || fail "dead holder was not reclaimed: $(cat "$out")"
  while [ "$i" -lt 30 ] && [ "$(cat "$dir/state/.watch.lock/pid" 2>/dev/null)" = "$dead" ]; do sleep 0.1; i=$((i + 1)); done
  [ "$(cat "$dir/state/.watch.lock/pid")" != "$dead" ] || fail "lock still names the dead pid"
  kill -TERM "$(cat "$dir/state/.watch.lock/pid")" 2>/dev/null || true
  wait "$APID" 2>/dev/null || true
  pass "a dead pid with a stale beat is reclaimed even under load"
}

test_two_owners_never_hold_two_watchers() {
  local dir o1 o2 live=0 holder
  dir=$(make_case one-two-owners)
  o1="$dir/daemon.out"
  o2="$dir/stop-hook.out"
  # The supervision-host daemon and the Stop auto-arm both run bin/jg-watch-arm.sh.
  arm_for "$dir" "$o1" JG_HOST_LOAD=30 JG_HOST_CPUS=4
  local a1=$APID
  arm_for "$dir" "$o2" JG_HOST_LOAD=30 JG_HOST_CPUS=4
  local a2=$APID
  wait_for_line "$o1" '^watcher: (started|attached) pid=' || fail "first owner never settled: $(cat "$o1")"
  wait_for_line "$o2" '^watcher: (started|attached) pid=' || fail "second owner never settled: $(cat "$o2")"
  holder=$(cat "$dir/state/.watch.lock/pid")
  is_live_non_zombie "$holder" && live=$((live + 1))
  [ "$live" -eq 1 ] || fail "lock holder is not one live watcher"
  # Count watcher roots of this home: jg-watch.sh processes whose parent is not itself
  # a jg-watch.sh (the watcher forks subshells of the same script).
  live=$(grep -l "JG_STATE_OVERRIDE=$dir/state" /proc/[0-9]*/environ 2>/dev/null | while read -r f; do
    p=${f#/proc/}; p=${p%%/*}
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in *jg-watch.sh*) ;; *) continue ;; esac
    is_live_non_zombie "$p" || continue
    pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    case "$(tr '\0' ' ' < "/proc/${pp:-0}/cmdline" 2>/dev/null)" in *jg-watch.sh*) ;; *) echo "$p" ;; esac
  done 2>/dev/null | wc -l)
  [ "$live" -eq 1 ] || fail "expected one watcher process for the home, counted $live"
  [ "$(cat "$o1" "$o2" | grep -c '^watcher: started')" -eq 1 ] || fail "both owners started a watcher"
  kill -TERM "$a1" "$a2" "$holder" 2>/dev/null || true
  wait "$a1" "$a2" 2>/dev/null || true
  pass "daemon and Stop-hook arms together leave one watcher process under load 30"
}

test_arm_attaches_to_a_live_watcher_and_starts_nothing
test_slow_beat_under_load_is_not_a_failure
test_slow_beat_below_stall_bound_is_not_refused_without_load
test_dead_pid_with_stale_beat_is_reclaimed
test_two_owners_never_hold_two_watchers
