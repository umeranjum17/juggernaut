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

# One server serves every home on the machine, so a stream made for the first home's
# prefix alone must not turn the next home's raise into an owed outbox row: that
# is how a queue "on the bus" kept all its wakes in a file.
test_a_second_home_reaches_the_same_stream() {
  local h2="$DIR/home2" url="$JG_WAKE_BUS_URL" subjects
  mkdir -p "$h2/state" "$h2/config"
  # The captain channel's stream overlaps a wildcard over the home part, as on the real server.
  "$NATS_BIN" -s "$url" stream add CAPTAIN --subjects 'jg.captain.>' --storage file --defaults >/dev/null 2>&1 || true
  "$NATS_BIN" -s "$url" stream edit JG_WAKE --subjects 'jg.home_.wake.>' --force >/dev/null 2>&1 \
    || fail "could not narrow the stream to one home, the way an earlier build left it"
  JG_HOME="$h2" JG_STATE_OVERRIDE="$h2/state" "$ROOT/bin/jg-wake-bus.sh" raise check second "check: from home two" now \
    || fail "the second home's raise failed"
  assert_equals 0 "$(cat "$h2/state/.wake-bus.outbox.jsonl" 2>/dev/null | wc -l | tr -d ' ')" \
    "the second home's raise must reach the bus, not wait in its outbox"
  subjects=$("$NATS_BIN" -s "$url" stream info JG_WAKE --json | jq -r '.config.subjects | join(",")')
  assert_contains "$subjects" 'jg.home2' "the stream must carry the second home's wake subject"
  assert_contains "$subjects" 'jg.home_.wake.>' "the stream must keep the first home's wake subject"
  pass "a second home's raise reaches the one stream"
}

test_an_inbox_acknowledgement_lands_on_the_inbox_stream() {
  local before after
  before=$("$NATS_BIN" -s "$JG_WAKE_BUS_URL" stream info JG_INBOX --json | jq -r '.state.messages')
  bus ack "inbox/$(basename "$HOME_DIR"):$(printf '%s' "$HOME_DIR" | sha256sum | cut -c1-8)/ghost/1" >/dev/null 2>&1 || true
  after=$("$NATS_BIN" -s "$JG_WAKE_BUS_URL" stream info JG_INBOX --json | jq -r '.state.messages')
  assert_equals "$((before + 1))" "$after" "an inbox acknowledgement must be a message on JG_INBOX"
  pass "an inbox acknowledgement lands on the inbox stream"
}

# An acknowledgement the bus could not take waits in the outbox and is published by
# the next render. It carries its raise's id, so it needs its own message id or the
# server drops it as a duplicate and the settled row comes back from the stream.
test_an_acknowledgement_owed_by_the_outbox_still_settles() {
  local id
  bus raise check owed "check: owed ack" now
  id=$(bus ids check owed)
  JG_WAKE_BUS_URL=nats://127.0.0.1:1 bus ack "$id" >/dev/null 2>&1 || true
  bus render || fail "the render that flushes the outbox failed"
  rm -f "$STATE_DIR/.wake-bus.cursor" "$STATE_DIR/.wake-bus.events.jsonl"
  bus render || fail "the rebuild from the stream failed"
  assert_not_contains "$(cat "$STATE_DIR/.wake-queue")" "owed" \
    "a flushed acknowledgement must settle its row when the replica is rebuilt from the stream"
  pass "an acknowledgement flushed from the outbox settles its row"
}

# The done-done journey (journeys/wake-bus-live.sh) is this suite's whole-path proof: its own
# throwaway server, two homes, and the probe that must PASS in each.
test_the_journey_proves_the_probe_in_two_homes() {
  local out
  mkdir -p "$DIR/evidence"
  out=$(DONE_DONE_EVIDENCE_ROOT="$DIR/evidence" RUN_ID=journey bash "$ROOT/journeys/wake-bus-live.sh" 2>&1) \
    || fail "the journey failed: $out"
  assert_contains "$out" "journey rc=0" "the journey must end clean"
  pass "the journey proves the probe in two homes"
}

result=0
test_raise_reaches_the_read_model || result=1
test_acknowledgement_removes_the_row_everywhere || result=1
test_record_only_row_lands_in_the_record_model || result=1
test_withdraw_takes_only_its_own_row || result=1
test_inbox_is_raised_at_the_writer_and_acknowledged_on_the_move || result=1
test_a_second_home_reaches_the_same_stream || result=1
test_an_inbox_acknowledgement_lands_on_the_inbox_stream || result=1
test_an_acknowledgement_owed_by_the_outbox_still_settles || result=1
test_the_journey_proves_the_probe_in_two_homes || result=1
exit "$result"
