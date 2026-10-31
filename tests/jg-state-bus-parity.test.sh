#!/usr/bin/env bash
# The per-task leases and busy events on the key-value bus, in shadow
# (docs/state-shadow.md): a replay of the recorded claims must report the same
# holder for the same task at the same instant on both paths, with the same
# refusal reason and the same expiry verdict, and a deliberately tampered value on
# the bus path must make the same check fail, so a green parity run is never
# vacuous.
#
# The test runs a throwaway nats-server on a random port, writes the file side
# with the production writers (bin/jg-lease.sh, bin/jg-busy-event.sh), and never
# touches this machine's real bus or a real home.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

NATS_SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
if [ -z "$NATS_SERVER" ]; then
  echo "skip: nats-server not found (set JG_NATS_SERVER)"
  exit 0
fi
if [ -z "$NATS_BIN" ]; then
  echo "skip: nats client not found (set JG_NATS_BIN)"
  exit 0
fi

DIR=$(jg_test_tmproot jg-state-bus-parity)
HOME_DIR="$DIR/home"
STATE_DIR="$HOME_DIR/state"
SERVER_PID=
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# start_server: a JetStream server on a free port, its client port read back from
# its own log so the test never assumes a fixed one.
start_server() {
  mkdir -p "$DIR/store"
  "$NATS_SERVER" -js -a 127.0.0.1 -p -1 -sd "$DIR/store" > "$DIR/nats.log" 2>&1 &
  SERVER_PID=$!
  local port i
  for i in $(seq 1 200); do
    port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$DIR/nats.log" 2>/dev/null | head -n 1)
    [ -n "$port" ] && break
    sleep 0.05
  done
  [ -n "${port:-}" ] || fail "the test bus never reported a listen port"
  NATS_URL="nats://127.0.0.1:$port"
}

# claim_as <main|branch> <task>: the production claim, scoped to this test's home.
claim_as() {
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" JG_SUPERVISION_ACTOR="$1" \
    bash "$ROOT/bin/jg-lease.sh" claim "$2" --actor "$1" || fail "the $1 claim on $2 failed"
}

# busy_event <args...>: the production busy writer, scoped to this test's home.
busy_event() {
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" \
    bash "$ROOT/bin/jg-busy-event.sh" "$@" >/dev/null || fail "busy event $* failed"
}

# file_side: the recorded claims and busy events, written by the production
# writers. Two live leases (one per supervision actor), one recorded expired
# lease, and two busy records (one still busy, one settled).
file_side() {
  mkdir -p "$STATE_DIR" "$HOME_DIR/config"
  printf 'shadow on\n' > "$HOME_DIR/config/state-bus"
  printf '%s\n' "$$" > "$STATE_DIR/.lock"
  claim_as main lane-a
  claim_as branch lane-b
  printf 'main\t%s\t%s\n' "$(dead_pid)" "$(date +%s)" > "$STATE_DIR/.lease-lane-c"
  busy_event arm "$STATE_DIR" lane-one
  busy_event arm "$STATE_DIR" lane-two
  busy_event apply "$STATE_DIR" lane-two idle --current-gen --source pi-ext --event agent-settled
}

statebus() {
  JG_STATE_BUS_URL="$NATS_URL" JG_NATS_BIN="$NATS_BIN" \
    bash "$ROOT/bin/jg-state-bus.sh" --home "$HOME_DIR" "$@"
}

kv() {
  "$NATS_BIN" -s "$NATS_URL" kv "$@"
}

test_the_mirror_carries_the_same_records() {
  local out key value want
  out=$(statebus sync 2>&1) || fail "the mirror failed: $out"
  assert_contains "$out" "leases=3 busy=2" "the mirror must carry every lease and busy record the file path holds"
  key=$(kv ls JG_LEASES | sed -n 's|^\(.*/lane-a\)$|\1|p')
  [ -n "$key" ] || fail "the bus holds no key for task lane-a"
  value=$(kv get JG_LEASES "$key" --raw 2>/dev/null) || fail "the bus value for lane-a is unreadable"
  want=$(cat "$STATE_DIR/.lease-lane-a")
  assert_equals "$want" "$value" "the bus must hold the lease line byte for byte, holder included"
  pass "the bus holds the same holder for the same task"
}

test_parity_reports_no_difference() {
  local out
  out=$(statebus parity 2>&1) || { printf '%s\n' "$out"; fail "parity failed on an untampered replay"; }
  assert_contains "$out" "events_compared=11" "every lease row, busy row and replayed claim must be compared"
  assert_contains "$out" "differences=0" "both paths must agree on the holder, the verdict and the reason"
  pass "the replayed claims report the same holder and the same refusal reason on both paths"
}

test_tampering_is_reported() {
  local out status=0
  out=$(statebus parity --corrupt 2>&1) || status=$?
  [ "$status" -ne 0 ] || { printf '%s\n' "$out"; fail "parity passed after one bus value was tampered with"; }
  assert_contains "$out" "lane-a" "the difference must name the record it found"
  assert_contains "$out" "held-by-other" "the replayed claims must include a refusal both paths agree on"
  assert_not_contains "$out" "differences=0" "a tampered value must never report no difference"
  pass "one tampered value on the bus path fails the same check"
}

test_a_release_reaches_the_bus_as_a_delete() {
  local out
  rm -f "$STATE_DIR/.lease-lane-b" || fail "releasing the lease failed"
  out=$(statebus sync 2>&1) || fail "the mirror failed after a release: $out"
  assert_contains "$out" "leases=2 busy=2" "the released lease must leave the mirror"
  assert_not_contains "$(kv ls JG_LEASES)" "/lane-b" "a released lease must be deleted from the bus, not left behind"
  out=$(statebus parity 2>&1) || { printf '%s\n' "$out"; fail "parity failed after a release"; }
  assert_contains "$out" "events_compared=8" "the released claim must drop out of the comparison"
  assert_contains "$out" "differences=0" "a release must not leave the two paths disagreeing"
  pass "a release reaches the bus as the delete a watcher observes"
}

# test_a_watch_sees_the_claim_and_the_release: the behaviour a switch would buy in
# place of the poll. A watcher must see the claim arrive with its holder and the
# release arrive as a delete, which is the event a reader would consume instead of
# polling the lease file.
test_a_watch_sees_the_claim_and_the_release() {
  local out watchfile="$DIR/watch.out" wpid
  claim_as main lane-w
  timeout 8 "$NATS_BIN" -s "$NATS_URL" kv watch JG_LEASES --updates > "$watchfile" 2>&1 &
  wpid=$!
  sleep 0.7
  statebus sync >/dev/null 2>&1 || fail "the mirror failed while a watcher ran"
  rm -f "$STATE_DIR/.lease-lane-w" || fail "releasing the watched lease failed"
  statebus sync >/dev/null 2>&1 || fail "the mirror failed after the watched release"
  sleep 0.7
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  out=$(cat "$watchfile")
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c 'PUT.*/lane-w: main')" \
    "a watcher must see the claim with the holder that made it"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c 'DELETE .*/lane-w$')" \
    "a watcher must see the release as one delete"
  pass "a watcher sees the claim and the release, so the poll is replaceable"
}

# test_tampering_a_busy_record_is_reported: the same check on a home that holds no
# lease at all, so the busy record is the only thing it can have corrupted and the
# busy half of the comparison is proven not to be vacuous either.
test_tampering_a_busy_record_is_reported() {
  local out status=0
  rm -f "$STATE_DIR/.lease-lane-a" "$STATE_DIR/.lease-lane-c" || fail "clearing the lease fixtures failed"
  out=$(statebus parity --corrupt 2>&1) || status=$?
  [ "$status" -ne 0 ] || { printf '%s\n' "$out"; fail "parity passed after one busy value was tampered with"; }
  assert_contains "$out" "unknown" "the difference must name the tampered record state"
  out=$(statebus parity 2>&1) || { printf '%s\n' "$out"; fail "parity failed after the tamper was mirrored over"; }
  assert_contains "$out" "events_compared=2" "the comparison must drop to the two busy records"
  assert_contains "$out" "differences=0" "a tampered value must be healed by the next mirror, not persist"
  pass "one tampered busy record fails the same check, and the next mirror heals it"
}

start_server
file_side
result=0
test_the_mirror_carries_the_same_records || result=1
test_parity_reports_no_difference || result=1
test_tampering_is_reported || result=1
test_a_release_reaches_the_bus_as_a_delete || result=1
test_a_watch_sees_the_claim_and_the_release || result=1
test_tampering_a_busy_record_is_reported || result=1
exit "$result"
