#!/usr/bin/env bash
# The wake queue and the task inboxes on the bus, in shadow (docs/bus-shadow.md):
# a replayed event set must produce the same consumer rows on both paths, and a
# deliberately corrupted event on the bus path must make the same check fail, so
# a green parity run is never vacuous.
#
# The test runs a throwaway nats-server on a random port, writes the file side
# with the production writers (jg_wake_append and jg_task_inbox_write), and never
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

DIR=$(jg_test_tmproot jg-wake-bus-parity)
HOME_DIR="$DIR/home"
STATE_DIR="$HOME_DIR/state"
RECORDS="$DIR/records"
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

# append_home_wake <kind> <key> <payload>: the production writer, scoped to this
# test's home so its own routing rule file decides the class.
append_home_wake() {
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" bash -c '
    # shellcheck source=/dev/null
    . "$1/bin/jg-wake-lib.sh"
    jg_wake_append "$2" "$3" "$4"
  ' _ "$ROOT" "$1" "$2" "$3" || fail "wake append failed"
}

# file_side: records on the file path, written by the production owners.
file_side() {
  mkdir -p "$STATE_DIR" "$HOME_DIR/config"
  printf 'shadow on\n' > "$HOME_DIR/config/wake-bus"
  printf 'silent signal *.quiet *\nnow * * * *\n' > "$HOME_DIR/config/wake-routing"
  append_home_wake check startup "check: MISSING"
  append_home_wake signal crew.quiet "signal: crew.quiet"
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" bash -c '
    # shellcheck source=/dev/null
    . "$1/bin/jg-task-inbox-lib.sh"
    jg_task_inbox_write "$2" lane-a "first instruction" >/dev/null
    jg_task_inbox_write "$2" lane-a "fire and forget" fire-and-forget >/dev/null
    jg_task_inbox_write "$2" lane-b "third instruction" >/dev/null
  ' _ "$ROOT" "$STATE_DIR" || fail "inbox write failed"
  # The acknowledgement is the worker's own move, exactly as the brief spells it.
  mv "$STATE_DIR/lane-b.inbox/001.msg" "$STATE_DIR/lane-b.inbox/handled/" \
    || fail "the handled move failed"
}

bus() {
  JG_WAKE_BUS_URL="$NATS_URL" JG_NATS_BIN="$NATS_BIN" "$ROOT/bin/jg-wake-bus.sh" \
    --home "$HOME_DIR" --record-dir "$RECORDS" "$@"
}

test_parity_matches_both_paths() {
  local out
  out=$(bus sync 2>&1) || fail "the mirror failed: $out"
  assert_contains "$out" "published=4" "the mirror must publish every record the file path holds"
  out=$(bus parity 2>&1) || { echo "$out"; fail "parity failed on an uncorrupted replay"; }
  assert_contains "$out" "differences=0" "both paths must agree on every row"
  assert_contains "$out" "bus_acknowledgements=1" "the handled record must be acknowledged on the bus"
  pass "every replayed event produces the same consumer row on both paths"
}

test_view_shows_the_same_five_rows() {
  local out
  out=$(bus view 2>&1) || fail "the bus view failed"
  assert_equals 5 "$(printf '%s\n' "$out" | awk 'END { print NR }')" \
    "the bus must present one queued wake, one settled wake, two pending records and one handled record"
  assert_contains "$out" "queue	check" "a queued wake must reach the bus view"
  assert_contains "$out" "settled	signal" "a silent wake must stay a recorded event"
  assert_contains "$out" "handled	normal" "a handled record must present as handled"
  pass "the bus view holds the queued, settled, pending and handled rows"
}

test_corruption_is_reported() {
  local out status=0
  bus sync >/dev/null 2>&1
  out=$(bus parity --corrupt 2>&1) || status=$?
  [ "$status" -ne 0 ] || { echo "$out"; fail "parity passed after one bus event was corrupted"; }
  assert_contains "$out" "corrupted by the parity test" "the difference must name the corrupted field"
  assert_not_contains "$out" "differences=0" "a corrupted event must never report no difference"
  pass "one corrupted event on the bus path fails the same check"
}

start_server
file_side
result=0
test_parity_matches_both_paths || result=1
test_view_shows_the_same_five_rows || result=1
test_corruption_is_reported || result=1
exit "$result"
