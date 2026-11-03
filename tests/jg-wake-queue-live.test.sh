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

# The live probe: one real wake, end to end, through the Go path. A raise lands on the bus and in
# the read model, and the library's readers - core/wake/cmd/jg-wake-core, through
# bin/jg-wake-core.sh - name its key, its number and its row; the withdraw takes it away and the
# same readers see nothing. That is the whole turn a supervisor takes on a wake, answered in Go.
test_one_real_wake_reads_end_to_end_through_the_go_path() {
  local seq
  bus raise check go-probe "check: read me through the Go path" now \
    || fail "the raise did not publish"
  seq=$(awk -F '\t' '$4 == "go-probe" { print $2 }' "$STATE_DIR/.wake-queue")
  case "$seq" in ''|*[!0-9]*) fail "the raised row must carry the server's number, got '$seq'" ;; esac
  assert_equals "go-probe" "$(jg_wake_queued_keys check | grep -Fx go-probe)" \
    "the Go reader must name the queued key"
  assert_equals "$seq" "$(jg_wake_rows_queued "$seq")" \
    "the Go reader must name the row's own number"
  assert_equals "go-probe" "$(jg_wake_print_deduped "$STATE_DIR/.wake-queue" | awk -F '\t' '$4 == "go-probe" { print $4 }')" \
    "the Go dedupe must present the row once"
  assert_equals 1 "$(jg_wake_actor_pending_count main)" "Main must count the one queued row"
  jg_wake_withdraw check go-probe || fail "the withdraw failed"
  assert_equals "" "$(jg_wake_queued_keys check | grep -Fx go-probe || true)" \
    "a withdrawn row must leave the Go readers"
  assert_equals 0 "$(jg_wake_actor_pending_count main)" \
    "Main must count no row once the wake is withdrawn"
  pass "one real wake is raised, read and withdrawn through the Go path"
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

# A render killed part-way through reading the bus must not lose or repeat a wake. The
# cursor moves only after the replica holding what it passed is written, and each file
# lands by rename, so a kill leaves the previous position or the new one. The shim
# below stands in for the client and parks one chosen call so the test can kill the
# render exactly there (kill -9 on the render's own process group, never anything else).
kill_shim() { # <dir>
  cat > "$1/nats-shim" <<SHIM
#!/usr/bin/env bash
case " \$* " in *" \$(cat "$1/pattern" 2>/dev/null) "*) ;; *) exec "$NATS_BIN" "\$@" ;; esac
[ -s "$1/pattern" ] || exec "$NATS_BIN" "\$@"
n=\$(( \$(cat "$1/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$1/count"
if [ "\$n" = "\$(cat "$1/hang-at")" ]; then : > "$1/reached"; exec sleep 60; fi
exec "$NATS_BIN" "\$@"
SHIM
  chmod +x "$1/nats-shim"
}

# kill_a_render_at <pattern> <hang-at>: raise one wake while the <hang-at>th client call
# naming <pattern> parks, then kill that raise. The wake is already stored on the bus.
kill_a_render_at() {
  local d=$DIR/kill pid
  mkdir -p "$d"; rm -f "$d/reached" "$d/count"
  kill_shim "$d"
  printf '%s' "$1" > "$d/pattern"; printf '%s' "$2" > "$d/hang-at"
  JG_NATS_BIN="$d/nats-shim" setsid "$ROOT/bin/jg-wake-bus.sh" raise check "$3" "check: $3" now >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 200); do [ -e "$d/reached" ] && break; sleep 0.05; done
  [ -e "$d/reached" ] || fail "the render never reached the call it was to be killed at ($1)"
  kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pkill -9 -P "$pid" 2>/dev/null || true
  rm -f "$d/pattern"
}

assert_once() { # <kind-key-word>...: each word is in the queue exactly once
  local w
  for w in "$@"; do
    assert_equals 1 "$(grep -c "check: $w" "$STATE_DIR/.wake-queue")" "wake '$w' must be delivered exactly once"
  done
}

test_a_render_killed_after_reading_one_stream_loses_no_wake() {
  bus raise check before "check: before" now || fail "setup raise failed"
  assert_once before
  kill_a_render_at "stream info JG_INBOX" 2 killed1
  bus render || fail "the restarted render failed"
  assert_once before killed1
  bus render || fail "a second render failed"
  assert_once before killed1
  bus raise check after "check: after" now || fail "the raise after the restart failed"
  assert_once before killed1 after
  pass "a render killed after reading one stream loses and repeats no wake"
}

test_a_render_killed_mid_read_loses_no_wake() {
  kill_a_render_at "stream get" 1 killed2
  bus render || fail "the restarted render failed"
  assert_once killed2
  bus render || fail "a second render failed"
  assert_once killed2
  cursor_wake=$(awk '$1 == "JG_WAKE" { print $2 }' "$STATE_DIR/.wake-bus.cursor")
  case "$cursor_wake" in ''|*[!0-9]*) fail "the cursor must hold a whole number, got '$cursor_wake'" ;; esac
  pass "a render killed mid-read loses and repeats no wake"
}

test_an_ordinary_run_delivers_each_wake_once() {
  local w
  for w in ord1 ord2 ord3; do bus raise check "$w" "check: $w" now || fail "raise $w failed"; done
  bus render || fail "render failed"
  bus render || fail "render failed"
  assert_once ord1 ord2 ord3
  pass "an ordinary run delivers each wake once"
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

# The done-done journey (journeys/wake-cursor-kill.sh) is the transcript proof of the kill case
# above: the same real render, killed and restarted on its own throwaway server.
test_the_kill_journey_delivers_each_wake_once() {
  local out
  mkdir -p "$DIR/evidence-kill"
  out=$(DONE_DONE_EVIDENCE_ROOT="$DIR/evidence-kill" RUN_ID=kill bash "$ROOT/journeys/wake-cursor-kill.sh" 2>&1) \
    || fail "the kill journey failed: $out"
  assert_contains "$out" "journey rc=0" "the kill journey must end clean"
  pass "the kill journey delivers each wake once"
}

# A stream the server made again numbers its messages from 1. A cursor taken on the old
# stream is past the new one's end, and a render that trusted it read nothing, so every
# wake raised after the remake sat on the server and never reached the read model. The
# cursor carries the stream's creation time, and an older two-field cursor past the end
# starts again at the stream's first message.
test_a_remade_stream_still_reaches_the_read_model() {
  local made
  bus raise check before-remake "check: before-remake" now || fail "setup raise failed"
  "$NATS_BIN" -s "$JG_WAKE_BUS_URL" stream rm -f JG_WAKE >/dev/null 2>&1 || fail "the test could not remove the wake stream"
  bus raise check after-remake "check: after-remake" now || fail "the raise onto the remade stream failed"
  assert_once after-remake
  made=$("$NATS_BIN" -s "$JG_WAKE_BUS_URL" stream info JG_WAKE --json | jq -r .created)
  assert_equals "$made" "$(awk '$1 == "JG_WAKE" { print $3 }' "$STATE_DIR/.wake-bus.cursor")" \
    "the cursor must name the stream it was taken on"
  printf 'JG_WAKE\t999999\nJG_INBOX\t999999\n' > "$STATE_DIR/.wake-bus.cursor"
  bus raise check old-cursor "check: old-cursor" now || fail "the raise past an old cursor failed"
  assert_once after-remake old-cursor
  assert_equals "$made" "$(awk '$1 == "JG_WAKE" { print $3 }' "$STATE_DIR/.wake-bus.cursor")" \
    "an old cursor must be rewritten onto the stream it now reads"
  pass "a wake raised on a remade stream reaches the read model"
}

result=0
test_raise_reaches_the_read_model || result=1
test_acknowledgement_removes_the_row_everywhere || result=1
test_one_real_wake_reads_end_to_end_through_the_go_path || result=1
test_record_only_row_lands_in_the_record_model || result=1
test_withdraw_takes_only_its_own_row || result=1
test_inbox_is_raised_at_the_writer_and_acknowledged_on_the_move || result=1
test_a_second_home_reaches_the_same_stream || result=1
test_an_inbox_acknowledgement_lands_on_the_inbox_stream || result=1
test_an_acknowledgement_owed_by_the_outbox_still_settles || result=1
test_a_render_killed_after_reading_one_stream_loses_no_wake || result=1
test_a_render_killed_mid_read_loses_no_wake || result=1
test_an_ordinary_run_delivers_each_wake_once || result=1
test_a_remade_stream_still_reaches_the_read_model || result=1
test_the_kill_journey_delivers_each_wake_once || result=1
test_the_journey_proves_the_probe_in_two_homes || result=1
exit "$result"
