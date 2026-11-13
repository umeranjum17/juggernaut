#!/usr/bin/env bash
# A rejected state check alerts once per file, not once per watcher sweep.
#
# bin/jg-watch.sh refuses a state/*.check.sh that has no matching trust binding and
# wakes Main about it. That wake used to repeat on every sweep for as long as the same
# file stayed rejected (50 wakes in 4.3 hours on one home, for one file). Each case runs
# the real watcher for one cycle against a throwaway home, then drains and acknowledges
# the cycle the way a Stop-owned arm does, and reads the wake the cycle printed:
#
#   same-file   the same rejected file on two sweeps alerts once
#   changed     a rejected file whose bytes change alerts again
#   second-file a second, distinct rejected file alerts, and names only itself
#   refixed     a file that is fixed (bound) and later rejected again alerts again
#
# The durable wake row is written for the first rejection only, so the drain
# presents one row, and the second sweep presents none.
#
# This is also the done-done journey test of rejected-state-check-once (the journey
# runs this file directly), so the changed-test map selects it for a change to the check.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(jg_test_tmproot jg-rejected-state-check-once)
WATCH="$ROOT/bin/jg-watch.sh"
DRAIN="$ROOT/bin/jg-wake-drain.sh"
REGISTER="$ROOT/bin/jg-check-register.sh"
ALERT='rejected unauthenticated state checks'

new_home() {  # <name>
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/home/config" "$dir/tmp" "$dir/config"
  # A home on the file wake queue, so a machine with no wake-bus service running
  # cannot stall the cycles.
  printf 'off\n' > "$dir/config/wake-bus"
  printf '%s\n' "$dir"
}

# write_check <dir> <id> <body>: an executable check shim with no trust binding.
write_check() {
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/state/$2.check.sh"
  chmod 0700 "$1/state/$2.check.sh"
}

# cycle <dir>: one real watcher cycle, then drain and acknowledge it. Leaves the
# cycle's output in <dir>/out and the drained wake rows in <dir>/drain.
cycle() {
  local dir=$1 rc=0 seq gen pid i
  # The sweep touches .last-check, so its presence proves the watcher got as far as the
  # due-check sweep; a silent cycle then means "swept, nothing to say". The watcher is
  # given as long as a slow runner needs to reach the sweep (a fixed short cap is a
  # flake there), and a short grace after it for an alert to print and the cycle to end.
  rm -f "$dir/state/.last-check"
  env HOME="$dir/home" XDG_CONFIG_HOME="$dir/home/config" TMPDIR="$dir/tmp" \
    PATH="$dir/fakebin:$PATH" JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" \
    JG_CONFIG_OVERRIDE="$dir/config" JG_POLL=0.2 JG_SIGNAL_GRACE=0 \
    JG_CHECK_INTERVAL=0 JG_HEARTBEAT=999999 JG_HOME_SUMMARY_INTERVAL=999999 \
    JG_SQUAD_LEAD_LIVENESS_SECS=99999999 JG_BUSY_TURN_MAX_SECS=999999 \
    JG_STALE_ESCALATE_SECS=999999 JG_WATCH_HANDLING_SUCCESSOR=1 \
    timeout 60 "$WATCH" > "$dir/out" 2> "$dir/err" &
  pid=$!
  for ((i = 0; i < 500; i++)); do
    [ ! -e "$dir/state/.last-check" ] || break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  for ((i = 0; i < 20; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || rc=$?
  case "$rc" in 0|124|143) ;; *) fail "watcher failed (rc=$rc): $(cat "$dir/err" "$dir/out" 2>/dev/null)" ;; esac
  [ -e "$dir/state/.last-check" ] || fail "the watcher never reached its due-check sweep: $(cat "$dir/err")"
  JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$DRAIN" > "$dir/drain" 2> "$dir/ack"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$dir/ack")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$dir/ack")
  [ -z "$seq" ] || JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$DRAIN" \
    --ack-through "$seq" --recovery-generation "$gen" >/dev/null
}

alerts() {  # <dir>: how many times the last cycle's output carries the alert
  grep -c "$ALERT" "$1/out" || true
}

assert_alert() {  # <dir> <names> <label>
  local dir=$1 names=$2 label=$3 n
  n=$(alerts "$dir")
  [ "$n" -eq 1 ] || fail "$label: expected one alert, got $n: $(cat "$dir/out") / $(cat "$dir/err")"
  grep -q "$ALERT:.*$names" "$dir/out" || fail "$label: the alert does not name $names: $(cat "$dir/out")"
}

assert_silent() {  # <dir> <label>
  local dir=$1 label=$2
  [ "$(alerts "$dir")" -eq 0 ] || fail "$label: the rejected file alerted again: $(cat "$dir/out")"
  ! grep -q "$ALERT" "$dir/drain" || fail "$label: the rejected file left a second wake row: $(cat "$dir/drain")"
}

test_same_file_alerts_once() {
  local dir
  dir=$(new_home same-file)
  write_check "$dir" stray 'exit 0'
  cycle "$dir"
  assert_alert "$dir" 'stray\.check\.sh' "first sweep"
  grep -q "$ALERT" "$dir/drain" || fail "the first rejection left no durable wake row: $(cat "$dir/drain")"
  cycle "$dir"
  assert_silent "$dir" "second sweep of the same file"
  cycle "$dir"
  assert_silent "$dir" "third sweep of the same file"
  pass "the same rejected file alerts on its first sweep and stays silent after"
}

test_changed_file_alerts_again() {
  local dir
  dir=$(new_home changed)
  write_check "$dir" stray 'exit 0'
  cycle "$dir"
  assert_alert "$dir" 'stray\.check\.sh' "first sweep"
  write_check "$dir" stray 'echo changed; exit 0'
  cycle "$dir"
  assert_alert "$dir" 'stray\.check\.sh' "changed file"
  cycle "$dir"
  assert_silent "$dir" "sweep after the changed file alerted"
  pass "a rejected file whose bytes change alerts again, once"
}

test_second_file_alerts() {
  local dir
  dir=$(new_home second-file)
  write_check "$dir" stray 'exit 0'
  cycle "$dir"
  assert_alert "$dir" 'stray\.check\.sh' "first file"
  write_check "$dir" other 'exit 0'
  cycle "$dir"
  assert_alert "$dir" 'other\.check\.sh' "second file"
  ! grep -q 'stray\.check\.sh' "$dir/out" || fail "the second alert repeated the first file: $(cat "$dir/out")"
  cycle "$dir"
  assert_silent "$dir" "sweep with both files already alerted"
  pass "a second distinct rejected file alerts and names only itself"
}

test_fixed_then_rejected_again_alerts() {
  local dir
  dir=$(new_home refixed)
  write_check "$dir" stray 'exit 0'
  cycle "$dir"
  assert_alert "$dir" 'stray\.check\.sh' "first rejection"
  # Fixed: bind the file to its bytes. The watcher runs it, and it is no longer rejected.
  JG_HOME="$dir" JG_STATE_OVERRIDE="$dir/state" "$REGISTER" stray >/dev/null \
    || fail "could not register the fixed check"
  cycle "$dir"
  assert_silent "$dir" "sweep of the fixed file"
  # Rejected again: the same bytes, but the binding is gone.
  rm -f "$dir/state/stray.check-trust"
  cycle "$dir"
  assert_alert "$dir" 'stray\.check\.sh' "rejected again after the fix"
  pass "a fixed file that is rejected again alerts again"
}

test_same_file_alerts_once
test_changed_file_alerts_again
test_second_file_alerts
test_fixed_then_rejected_again_alerts
echo "rejected state checks: one alert per file until its content or identity changes"
