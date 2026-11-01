#!/usr/bin/env bash
# The per-task busy events on the key-value bus, in shadow
# (docs/state-shadow.md): a replay of the recorded records must report the same
# busy record on both paths, a deliberately tampered value on the bus path must
# make the same check fail, and the next mirror must heal it, so a green parity
# run is never vacuous.
#
# The leases this file used to compare are live now and are proven by
# tests/jg-lease-live.test.sh; what remains here is the busy half, which is still
# mirrored from the file path.
#
# The test runs a throwaway nats-server on a random port, writes the file side
# with the production writer (bin/jg-busy-event.sh), and never touches this
# machine's real bus or a real home.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DIR=$(jg_test_tmproot jg-state-bus-parity)
HOME_DIR="$DIR/home"
STATE_DIR="$HOME_DIR/state"
jg_test_bus_start "$DIR" || {
  echo "skip: nats-server or the nats client not found (set JG_NATS_SERVER and JG_NATS_BIN)"
  exit 0
}

# busy_event <args...>: the production busy writer, scoped to this test's home.
busy_event() {
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" \
    bash "$ROOT/bin/jg-busy-event.sh" "$@" >/dev/null || fail "busy event $* failed"
}

# file_side: two busy records written by the production writer, one still busy
# and one settled.
file_side() {
  mkdir -p "$STATE_DIR" "$HOME_DIR/config"
  printf 'shadow on\n' > "$HOME_DIR/config/state-bus"
  busy_event arm "$STATE_DIR" lane-one
  busy_event arm "$STATE_DIR" lane-two
  busy_event apply "$STATE_DIR" lane-two idle --current-gen --source pi-ext --event agent-settled
}

statebus() {
  JG_NATS_BIN="$JG_NATS_BIN" JG_KV_URL="$JG_KV_URL" \
    bash "$ROOT/bin/jg-state-bus.sh" --home "$HOME_DIR" "$@"
}

kv() {
  "$JG_NATS_BIN" -s "$JG_KV_URL" kv "$@"
}

test_the_mirror_carries_the_same_records() {
  local out key value want
  out=$(statebus sync 2>&1) || fail "the mirror failed: $out"
  assert_contains "$out" "busy=2" "the mirror must carry every busy record the file path holds"
  key=$(kv ls JG_BUSY | sed -n 's|^\(.*/lane-one\)$|\1|p')
  [ -n "$key" ] || fail "the bus holds no key for task lane-one"
  value=$(kv get JG_BUSY "$key" --raw 2>/dev/null) || fail "the bus value for lane-one is unreadable"
  want=$(cat "$STATE_DIR/lane-one.busy-gen" "$STATE_DIR/lane-one.busy-state")
  assert_equals "$want" "$value" "the bus must hold the gen line and the record line byte for byte"
  pass "the bus holds the same busy record the file path holds"
}

test_parity_reports_no_difference() {
  local out
  out=$(statebus parity 2>&1) || { printf '%s\n' "$out"; fail "parity failed on an untampered replay"; }
  assert_contains "$out" "records_compared=2" "both busy records must be compared"
  assert_contains "$out" "differences=0" "both paths must agree on the record, its gen and its sequence"
  pass "the replay reports the same busy record on both paths"
}

test_tampering_is_reported() {
  local out status=0
  out=$(statebus parity --corrupt 2>&1) || status=$?
  [ "$status" -ne 0 ] || { printf '%s\n' "$out"; fail "parity passed after one bus value was tampered with"; }
  assert_contains "$out" "unknown" "the difference must name the tampered record state"
  assert_not_contains "$out" "differences=0" "a tampered value must never report no difference"
  out=$(statebus parity 2>&1) || { printf '%s\n' "$out"; fail "parity failed after the tamper was mirrored over"; }
  assert_contains "$out" "differences=0" "a tampered value must be healed by the next mirror, not persist"
  pass "one tampered busy record fails the same check, and the next mirror heals it"
}

test_a_retire_reaches_the_bus_as_a_delete() {
  local out
  busy_event retire "$STATE_DIR" lane-one --current-gen
  out=$(statebus sync 2>&1) || fail "the mirror failed after a retire: $out"
  assert_contains "$out" "busy=1" "the retired record must leave the mirror"
  assert_not_contains "$(kv ls JG_BUSY)" "/lane-one" "a retired record must be deleted from the bus, not left behind"
  out=$(statebus parity 2>&1) || { printf '%s\n' "$out"; fail "parity failed after a retire"; }
  assert_contains "$out" "records_compared=1" "the retired record must drop out of the comparison"
  assert_contains "$out" "differences=0" "a retire must not leave the two paths disagreeing"
  pass "a retire reaches the bus as the delete a watcher observes"
}

file_side
result=0
test_the_mirror_carries_the_same_records || result=1
test_parity_reports_no_difference || result=1
test_tampering_is_reported || result=1
test_a_retire_reaches_the_bus_as_a_delete || result=1
exit "$result"
