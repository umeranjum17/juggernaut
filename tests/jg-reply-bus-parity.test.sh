#!/usr/bin/env bash
# The pending-reply event stream on the bus (docs/reply-shadow.md): the
# production writers publish their facts, state/reply-state.tsv is the cache the
# fold rebuilds from those events, and a deliberately corrupted event must make the
# check fail, so a green parity run is never vacuous.
#
# The test runs a throwaway nats-server on a random port, writes with the
# production writers (jg_pending_reply_create and the recovery, resolve and
# escalate functions) so their own publishes are what reaches the bus, and never
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

DIR=$(jg_test_tmproot jg-reply-bus-parity)
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

# file_side: three waiters on the record path, written by the production owners,
# with fixed clocks so every deadline and fire epoch is exact.
#
#   answered  delivered, its request turn completed, then a correlated parent
#             status line resolved it (waiter, request timer, answer)
#   escalated the request turn completed, one recovery repost ran, the recovery
#             turn completed, and the second grace elapsed (both timers and both
#             fires)
#   open      delivered, no turn completion yet, so no timer is armed
file_side() {
  local base
  mkdir -p "$STATE_DIR" "$HOME_DIR/config"
  printf 'nats-url %s\n' "$NATS_URL" > "$HOME_DIR/config/reply-bus"
  base=$(( $(date +%s) - 600 ))
  printf '%s\n' "$base" > "$DIR/base"
  cat > "$DIR/recovery-hook.sh" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${JG_TEST_HOOK_LOG:?}"
exit 0
HOOK
  chmod +x "$DIR/recovery-hook.sh"
  JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$STATE_DIR" \
    JG_REPLY_BUS_URL="$NATS_URL" JG_NATS_BIN="$NATS_BIN" \
    JG_PENDING_REPLY_SEND_HOOK="$DIR/recovery-hook.sh" \
    JG_TEST_HOOK_LOG="$DIR/recovery-hook.log" \
    bash -c '
    set -u
    # shellcheck source=/dev/null
    . "$1/bin/jg-pending-reply-lib.sh"
    state=$2 base=$3
    c_a=$(jg_pending_reply_create "$JG_HOME" "$state" lane-a "please report" ) || exit 2
    c_b=$(jg_pending_reply_create "$JG_HOME" "$state" lane-b "please repost" ) || exit 2
    c_c=$(jg_pending_reply_create "$JG_HOME" "$state" lane-c "still working" ) || exit 2
    for c in "$c_a" "$c_b" "$c_c"; do
      JG_PENDING_REPLY_NOW=$((base)) jg_pending_reply_mark_delivered "$state" "$c" || exit 2
    done
    rec=$(jg_pending_reply_path "$state" "$c_a")
    jg_pending_reply_set "$rec" request_turn_completed_epoch $((base + 10)) || exit 2
    printf "done [at=%s]: corr=%s the report is on the desk\n" "$((base + 20))" "$c_a" \
      >> "$state/lane-a.status"
    JG_PENDING_REPLY_NOW=$((base + 20)) jg_pending_reply_try_resolve "$state" "$c_a" \
      "$state/lane-a.status" || exit 2
    rec=$(jg_pending_reply_path "$state" "$c_b")
    jg_pending_reply_set "$rec" request_turn_completed_epoch $((base + 10)) || exit 2
    JG_PENDING_REPLY_NOW=$((base + 130)) jg_pending_reply_send_recovery "$state" "$c_b" || exit 2
    jg_pending_reply_set "$rec" recovery_turn_completed_epoch $((base + 140)) || exit 2
    JG_PENDING_REPLY_NOW=$((base + 270)) jg_pending_reply_maybe_escalate "$state" "$c_b" || exit 2
    [ "$(jg_pending_reply_get "$rec" phase)" = escalated ] || exit 2
    # A fourth waiter, dropped undelivered: it must leave the stream view as well
    # as the record path, or a discarded request would come back on the next
    # projection.
    c_d=$(jg_pending_reply_create "$JG_HOME" "$state" lane-d "drop this one") || exit 2
    jg_pending_reply_discard_undelivered "$state" "$c_d" || exit 2
    jg_pending_reply_exists "$(jg_pending_reply_path "$state" "$c_d")" && exit 2
    printf "%s %s %s %s\n" "$c_a" "$c_b" "$c_c" "$c_d" > "$4"
  ' _ "$ROOT" "$STATE_DIR" "$base" "$DIR/corr" || fail "the record-side fixture could not be built"
}

reply_bus() {
  JG_REPLY_BUS_URL="$NATS_URL" JG_NATS_BIN="$NATS_BIN" "$ROOT/bin/jg-reply-bus.sh" \
    --home "$HOME_DIR" "$@"
}

test_the_writers_published_and_kept_no_log() {
  local out
  [ ! -e "$STATE_DIR/reply-bus.jsonl" ] \
    || fail "the interim event log was written beside the bus"
  out=$(reply_bus view 2>&1) || fail "the stream view failed: $out"
  assert_contains "$out" "waiter	lane-a" "the create must have published a waiter event"
  assert_contains "$out" "answer	" "the resolve must have published an answer event"
  assert_not_contains "$out" "lane-d" "a discarded waiter must leave the stream's view"
  pass "the production writers published, and no event log was written beside the bus"
}

test_the_projection_rebuilds_from_the_bus() {
  local out saved="$DIR/saved.tsv"
  cp "$STATE_DIR/reply-state.tsv" "$saved" || fail "the cache could not be copied"
  rm -f "$STATE_DIR/reply-state.tsv" || fail "the cache could not be cleared"
  out=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/jg-pending-reply-lib.sh"
    JG_REPLY_BUS_URL="$NATS_URL" JG_NATS_BIN="$NATS_BIN" \
      jg_pending_reply_state_sync "$STATE_DIR"
  ) || fail "the rebuild from the bus failed: $out"
  [ -f "$STATE_DIR/reply-state.tsv" ] || fail "the rebuild from the bus wrote no cache"
  out=$(diff -u "$saved" "$STATE_DIR/reply-state.tsv" 2>&1) \
    || fail "the cache rebuilt from the bus differs from the cache written: $out"
  pass "the cache is exactly the fold of the stream"
}

test_parity_matches_both_paths() {
  local out
  out=$(reply_bus parity 2>&1) || { echo "$out"; fail "parity failed on an uncorrupted comparison"; }
  assert_contains "$out" "differences=0" "the records and the stream must agree on every row"
  assert_contains "$out" "events_compared=12" "every fact of the three live waiters must be compared"
  assert_contains "$out" "timers_armed=3" "each completed turn arms one timer"
  assert_contains "$out" "timers_fired=2" "the repost and the escalation are the two fired timeouts"
  assert_contains "$out" "max_lateness_s=10" "the second timeout fires from its own grace, and only it is late"
  pass "every live waiter produces the same rows from its record and from the stream"
}

test_view_shows_the_same_twelve_rows() {
  local out
  out=$(reply_bus view 2>&1) || fail "the workflow view failed"
  assert_equals 12 "$(printf '%s\n' "$out" | awk 'END { print NR }')" \
    "the workflow must present four rows for the answered waiter, five for the escalated one and three for the open one"
  assert_contains "$out" "waiter	lane-a" "an answered waiter must be present"
  assert_contains "$out" "answer	" "the reply that settled a waiter must be present"
  assert_contains "$out" "timer	request	none" "an open waiter must show an unarmed timer"
  assert_contains "$out" "fire	recovery	" "the escalation must show its fired timeout"
  pass "the workflow view holds the waiter, timer, fire and answer rows"
}

test_corruption_is_reported() {
  local out status=0
  out=$(reply_bus parity --corrupt 2>&1) || status=$?
  [ "$status" -ne 0 ] || { echo "$out"; fail "parity passed after one workflow event was corrupted"; }
  assert_contains "$out" "corrupted-by-the-parity-test" "the difference must name the corrupted field"
  assert_not_contains "$out" "differences=0" "a corrupted event must never report no difference"
  pass "one corrupted event on the workflow path fails the same check"
}

start_server
file_side
result=0
test_the_writers_published_and_kept_no_log || result=1
test_the_projection_rebuilds_from_the_bus || result=1
test_parity_matches_both_paths || result=1
test_view_shows_the_same_twelve_rows || result=1
test_corruption_is_reported || result=1
exit "$result"
