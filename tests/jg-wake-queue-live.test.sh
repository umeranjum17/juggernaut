#!/usr/bin/env bash
# The wake queue and the task inboxes live on the bus (docs/bus-live.md): a raise
# reaches the read model with the server's own sequence, an acknowledgement
# removes it from the bus and from the read model, a record-only row lands in the
# record model, a withdraw takes only its own row, and an inbox record is raised
# at its writer and acknowledged when its file leaves the inbox.
#
# The test starts a throwaway server on a free port with its own store, so it
# never touches this machine's real bus or a real home. It gate-skips when the
# server or the client is missing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NATS_SERVER=${JG_NATS_SERVER:-$(command -v nats-server 2>/dev/null || true)}
NATS_BIN=${JG_NATS_BIN:-$(command -v nats 2>/dev/null || true)}
[ -n "$NATS_SERVER" ] || { echo "skip: nats-server not found (set JG_NATS_SERVER)"; exit 0; }
[ -n "$NATS_BIN" ] || { echo "skip: nats client not found (set JG_NATS_BIN)"; exit 0; }

DIR=$(jg_test_tmproot jg-wake-queue-live)
HOME_DIR="$DIR/home"
STATE_DIR="$HOME_DIR/state"
SERVER_PID=
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() { [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$STATE_DIR" "$HOME_DIR/config" "$DIR/store"
printf 'now * * * *\n' > "$HOME_DIR/config/wake-routing"
"$NATS_SERVER" -js -a 127.0.0.1 -p -1 -sd "$DIR/store" > "$DIR/nats.log" 2>&1 &
SERVER_PID=$!
port=
for _ in $(seq 200); do
  port=$(sed -n 's/.*Listening for client connections on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$DIR/nats.log" 2>/dev/null | head -n 1)
  [ -n "$port" ] && break
  sleep 0.05
done
[ -n "$port" ] || { echo "skip: the throwaway server never listened"; exit 0; }

export JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" JG_WAKE_BUS_URL="nats://127.0.0.1:$port"
export JG_WAKE_ROUTING="$HOME_DIR/config/wake-routing"
export JG_NATS_BIN="$NATS_BIN"
bus() { "$ROOT/bin/jg-wake-bus.sh" "$@"; }

# The library that owns the producer and consumer primitives this test drives.
# shellcheck source=bin/jg-wake-lib.sh
. "$ROOT/bin/jg-wake-lib.sh"

test_raise_reaches_the_read_model() {
  local rows seq
  bus raise check startup "check: MISSING" now || fail "the raise did not publish"
  rows=$(awk 'END { print NR }' "$STATE_DIR/.wake-queue")
  assert_equals 1 "$rows" "a raise must reach the read model exactly once"
  seq=$(awk -F '\t' '{ print $2 }' "$STATE_DIR/.wake-queue")
  case "$seq" in ''|*[!0-9]*) fail "the row must carry a numeric sequence, got '$seq'" ;; esac
  echo "$seq" | grep -qE '^[0-9]{10,}$' \
    || fail "the row's number is fixed at raise time, so a row must never carry a bare counter: got '$seq'"
  pass "a raise reaches the read model with the server's sequence"
}

test_acknowledgement_removes_the_row_everywhere() {
  local id
  id=$(bus ids check startup)
  [ -n "$id" ] || fail "the read model must name the queued id"
  bus ack "$id" || fail "the acknowledgement did not publish"
  assert_equals 0 "$(awk 'END { print NR }' "$STATE_DIR/.wake-queue")" \
    "an acknowledged row must leave the read model"
  assert_equals 0 "$(bus count)" "an acknowledged row must leave the replica"
  pass "an acknowledgement removes the row from the bus and the read model"
}

test_record_only_row_lands_in_the_record_model() {
  bus settle heartbeat crew "all quiet" || fail "the record-only event did not publish"
  assert_contains "$(cat "$STATE_DIR/.wake-settled")" "heartbeat" \
    "a record-only event must appear in the record model"
  assert_equals 0 "$(awk 'END { print NR }' "$STATE_DIR/.wake-queue")" \
    "a record-only event must never become a queued row"
  pass "a record-only event is recorded and never queued"
}

test_withdraw_takes_only_its_own_row() {
  bus raise check keepers "check: keep me" now
  bus raise check dropme "check: drop me" now
  jg_wake_withdraw check dropme || fail "the withdraw failed"
  assert_not_contains "$(cat "$STATE_DIR/.wake-queue")" "dropme" "the withdrawn row must go"
  assert_contains "$(cat "$STATE_DIR/.wake-queue")" "keepers" "another row must stay queued"
  pass "a withdraw removes exactly its own row"
}

test_inbox_is_raised_at_the_writer_and_acknowledged_on_the_move() {
  local rec
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-task-inbox-lib.sh"
  rec=$(jg_task_inbox_write "$STATE_DIR" task-a "hello steer") || fail "the inbox write failed"
  assert_contains "$(cat "$STATE_DIR/.wake-bus.events.jsonl")" '"task":"task-a"' \
    "the writer must publish the record it made durable"
  bus inbox-settle || fail "the settle pass failed"
  assert_not_contains "$(cat "$STATE_DIR/.wake-bus.events.jsonl")" '"task":"task-a"' \
    "a record still in its inbox must stay unacknowledged"
  mv "$rec" "$STATE_DIR/task-a.inbox/handled/" || fail "the handled move failed"
  bus inbox-settle || fail "the settle pass failed"
  assert_not_contains "$(cat "$STATE_DIR/.wake-bus.events.jsonl")" '"task":"task-a"' \
    "a handled record must be acknowledged on the bus"
  pass "an inbox record is raised at its writer and acknowledged on the move"
}

result=0
test_raise_reaches_the_read_model || result=1
test_acknowledgement_removes_the_row_everywhere || result=1
test_record_only_row_lands_in_the_record_model || result=1
test_withdraw_takes_only_its_own_row || result=1
test_inbox_is_raised_at_the_writer_and_acknowledged_on_the_move || result=1
exit "$result"
