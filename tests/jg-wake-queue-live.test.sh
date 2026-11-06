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

inbox_replica() { # <task>: how many unsettled records of this task the replica holds
  jq -c --arg task "$1" 'select(.task == $task)' "$STATE_DIR/.wake-bus.events.jsonl" | awk 'END { print NR + 0 }'
}

# A record's file is numbered by its own inbox, the stream by every record of the home,
# so a second task's record makes the two numbers differ.
test_inbox_is_raised_at_the_writer_and_acknowledged_on_the_move() {
  local rec
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-task-inbox-lib.sh"
  jg_task_inbox_write "$STATE_DIR" task-b "first steer" >/dev/null || fail "the inbox write failed"
  rec=$(jg_task_inbox_write "$STATE_DIR" task-a "hello steer") || fail "the inbox write failed"
  assert_equals 1 "$(inbox_replica task-a)" "the writer must publish the record it made durable"
  bus inbox-settle || fail "the settle pass failed"
  assert_equals 1 "$(inbox_replica task-a)" "a record still in its inbox must stay unacknowledged"
  assert_equals 1 "$(inbox_replica task-b)" "a record still in its inbox must stay unacknowledged"
  mv "$rec" "$STATE_DIR/task-a.inbox/handled/" || fail "the handled move failed"
  bus inbox-settle || fail "the settle pass failed"
  assert_equals 0 "$(inbox_replica task-a)" "a handled record must be acknowledged on the bus"
  assert_equals 1 "$(inbox_replica task-b)" "only the handled record may be acknowledged"
  pass "an inbox record is raised at its writer and acknowledged on the move"
}

# A record that vanished from its inbox without landing in handled/ was lost, not handled.
test_a_lost_record_is_not_acknowledged() {
  local rec
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-task-inbox-lib.sh"
  rec=$(jg_task_inbox_write "$STATE_DIR" task-lost "steer that goes missing") || fail "the inbox write failed"
  rm -f -- "$rec"
  bus inbox-settle || fail "the settle pass failed"
  assert_equals 1 "$(inbox_replica task-lost)" "a record in neither the inbox nor handled/ must stay unacknowledged"
  pass "a missing record is not counted as acknowledged"
}

# A raise the event system refuses is reported on stderr; the steer itself stays stored.
test_a_failed_raise_is_reported_and_the_steer_stays_stored() {
  local rec err
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-task-inbox-lib.sh"
  jg_wake_bus() { printf 'refused: the event system said no\n'; return 1; }
  err=$(jg_task_inbox_write "$STATE_DIR" task-raise "steer with a refused raise" 2>&1 >"$STATE_DIR/.raise-rec") || fail "a refused raise must not fail the steer"
  rec=$(cat "$STATE_DIR/.raise-rec")
  [ -f "$rec" ] || fail "the steer record must stay stored"
  assert_contains "$err" "did not take it" "the refused raise must be reported"
  assert_contains "$err" "the event system said no" "the report must carry the reason"
  unset -f jg_wake_bus
  pass "a failed raise is reported and the steer stays stored"
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

# A home's cursor can sit far past both stream ends, as a cursor taken before the
# streams were remade does (6347 and 1630 against streams that end near 190 and 311).
# Each stream is then read again from its start, an inbox record keeps its own number,
# and a replica an older render wrote with the stream's sequence still settles.
test_a_cursor_past_both_stream_ends_reads_both_from_the_start() {
  local rec
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-task-inbox-lib.sh"
  bus raise check stale-cursor "check: stale-cursor" now || fail "setup raise failed"
  rec=$(jg_task_inbox_write "$STATE_DIR" task-c "steer past the cursor") || fail "the inbox write failed"
  : > "$STATE_DIR/.wake-bus.events.jsonl"
  printf 'JG_WAKE\t6347\nJG_INBOX\t1630\n' > "$STATE_DIR/.wake-bus.cursor"
  bus render || fail "the render past the stale cursor failed"
  assert_once stale-cursor
  assert_equals 1 "$(inbox_replica task-c)" "the inbox stream must be read again from its start"
  assert_equals 1 "$(inbox_replica task-b)" "a record still waiting must come back with it"
  awk '$1 == "JG_INBOX" { exit !($2 < 1630) }' "$STATE_DIR/.wake-bus.cursor" \
    || fail "the inbox cursor must move back onto the stream"
  jq -c 'if .task == "task-c" then .seq = 99 else . end' "$STATE_DIR/.wake-bus.events.jsonl" > "$DIR/replica" \
    && mv "$DIR/replica" "$STATE_DIR/.wake-bus.events.jsonl"
  bus inbox-settle || fail "the settle pass failed"
  assert_equals 1 "$(inbox_replica task-c)" "a record still in its inbox must stay unacknowledged"
  mv "$rec" "$STATE_DIR/task-c.inbox/handled/" || fail "the handled move failed"
  bus inbox-settle || fail "the settle pass failed"
  assert_equals 0 "$(inbox_replica task-c)" "a handled record must settle whatever number the replica gave it"
  pass "a cursor past both stream ends reads both from the start"
}

# A row whose first acknowledgement the cursor passed without settling it (a replica
# write that lost to a concurrent render) could never be acknowledged again: the second
# acknowledgement reused the first one's message id, the server dropped it as a duplicate,
# and every retry exited 0 with the row still queued. Each acknowledgement is its own
# message now, so the retry settles the row.
test_a_repeated_acknowledgement_settles_a_row_the_cursor_passed() {
  local id keep
  bus raise check stuck "check: stuck" now || fail "setup raise failed"
  id=$(bus ids check stuck | head -n 1)
  keep=$DIR/replica-before-ack
  cp "$STATE_DIR/.wake-bus.events.jsonl" "$keep"
  bus ack "$id" || fail "the first acknowledgement failed"
  assert_equals 0 "$(grep -c 'check: stuck' "$STATE_DIR/.wake-queue")" "the first acknowledgement must settle the row"
  cp "$keep" "$STATE_DIR/.wake-bus.events.jsonl"
  bus ack "$id" || fail "the repeated acknowledgement must settle the row, not exit 0 with it queued"
  assert_equals 0 "$(grep -c 'check: stuck' "$STATE_DIR/.wake-queue")" \
    "a repeated acknowledgement must remove the row from the read model"
  pass "a repeated acknowledgement settles a row the cursor already passed"
}

# An acknowledgement the bus reports stored but that never reaches the replica cannot remove
# its row. It must say so and exit non-zero, not exit 0 beside a row that stays.
test_an_acknowledgement_that_cannot_remove_its_row_fails_loudly() {
  local d=$DIR/liar id out rc
  mkdir -p "$d"
  cat > "$d/nats-shim" <<SHIM
#!/usr/bin/env bash
case " \$* " in *" pub "*wake.ack*) echo "Stored in Stream: JG_WAKE Sequence: 1"; exit 0 ;; esac
exec "$NATS_BIN" "\$@"
SHIM
  chmod +x "$d/nats-shim"
  bus raise check liar "check: liar" now || fail "setup raise failed"
  id=$(bus ids check liar | head -n 1)
  out=$(JG_NATS_BIN="$d/nats-shim" bus ack "$id" 2>&1); rc=$?
  assert_equals 1 "$rc" "an acknowledgement that leaves its row queued must exit non-zero"
  echo "$out" | grep -q "still queued" || fail "the failure must say why, got: $out"
  bus ack "$id" || fail "cleanup acknowledgement failed"
  pass "an acknowledgement that cannot remove its row exits non-zero with the reason"
}

# A message the render could not read - the bus answered a `stream get` with an error rather than
# "no message found" - was skipped and the cursor then passed it, so an acknowledgement read during
# that render was lost to the replica for good: the row stayed queued, the retry's own message was
# a different one, and only a restart of the bus (which made reads work again) let any later
# acknowledgement settle anything. A render that cannot read a message must stop there and leave the
# cursor before it, so the next render that can read it applies it.
test_a_message_the_render_could_not_read_is_applied_by_the_next_render() {
  local d=$DIR/unreadable id out rc
  mkdir -p "$d"
  cat > "$d/nats-shim" <<SHIM
#!/usr/bin/env bash
case " \$* " in *" stream get "*) [ ! -e "$d/refuse" ] || { echo "nats: error: context deadline exceeded" >&2; exit 1; } ;; esac
exec "$NATS_BIN" "\$@"
SHIM
  chmod +x "$d/nats-shim"
  bus raise check unreadable "check: unreadable" now || fail "setup raise failed"
  id=$(bus ids check unreadable | head -n 1)
  : > "$d/refuse"
  out=$(JG_NATS_BIN="$d/nats-shim" bus ack "$id" 2>&1); rc=$?
  assert_equals 1 "$rc" "an acknowledgement the render cannot read back must not pass as settled"
  echo "$out" | grep -q "still queued" || fail "the failure must say why, got: $out"
  rm -f -- "$d/refuse"
  bus render >/dev/null 2>&1 || fail "the render after the bus recovered failed"
  assert_equals 0 "$(grep -c 'check: unreadable' "$STATE_DIR/.wake-queue")" \
    "the acknowledgement unreadable at first must settle the row once the bus reads again"
  pass "a message the render could not read is applied by the next render"
}

# A row the bus never received sits in the outbox and in the replica; acknowledging it
# must drop both.
test_a_row_owed_by_the_outbox_is_acknowledged_once() {
  local id
  JG_WAKE_BUS_URL=nats://127.0.0.1:1 bus raise check owed-row "check: owed-row" now || fail "setup raise failed"
  id=$(JG_WAKE_BUS_URL=nats://127.0.0.1:1 bus ids check owed-row | head -n 1)
  JG_WAKE_BUS_URL=nats://127.0.0.1:1 bus ack "$id" || fail "acknowledging an owed row failed"
  assert_equals 0 "$(grep -c 'check: owed-row' "$STATE_DIR/.wake-queue")" "an owed row must leave the read model"
  bus render >/dev/null 2>&1 || true
  assert_equals 0 "$(grep -c 'check: owed-row' "$STATE_DIR/.wake-queue")" "an owed row must not come back"
  pass "a row owed by the outbox is acknowledged once"
}

result=0
test_raise_reaches_the_read_model || result=1
test_acknowledgement_removes_the_row_everywhere || result=1
test_one_real_wake_reads_end_to_end_through_the_go_path || result=1
test_record_only_row_lands_in_the_record_model || result=1
test_withdraw_takes_only_its_own_row || result=1
test_inbox_is_raised_at_the_writer_and_acknowledged_on_the_move || result=1
test_a_lost_record_is_not_acknowledged || result=1
test_a_failed_raise_is_reported_and_the_steer_stays_stored || result=1
test_a_second_home_reaches_the_same_stream || result=1
test_an_inbox_acknowledgement_lands_on_the_inbox_stream || result=1
test_an_acknowledgement_owed_by_the_outbox_still_settles || result=1
test_a_render_killed_after_reading_one_stream_loses_no_wake || result=1
test_a_render_killed_mid_read_loses_no_wake || result=1
test_an_ordinary_run_delivers_each_wake_once || result=1
test_a_remade_stream_still_reaches_the_read_model || result=1
test_a_cursor_past_both_stream_ends_reads_both_from_the_start || result=1
test_a_repeated_acknowledgement_settles_a_row_the_cursor_passed || result=1
test_an_acknowledgement_that_cannot_remove_its_row_fails_loudly || result=1
test_a_row_owed_by_the_outbox_is_acknowledged_once || result=1
test_a_message_the_render_could_not_read_is_applied_by_the_next_render || result=1
test_the_kill_journey_delivers_each_wake_once || result=1
test_the_journey_proves_the_probe_in_two_homes || result=1
exit "$result"
