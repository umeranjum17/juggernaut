#!/usr/bin/env bash
# tests/jg-wake-daemon-lifecycle-e2e.test.sh - the watcher + supervise-daemon
# lifecycle, end to end, over one shared state root and a shimmed tmux:
#
#   routine status -> batched, queued, self-handled with no wake turn
#   terminal status written while the watcher is DOWN -> wakes and is caught on restart (catch-up)
#   drain queued records -> exactly ONE captain-relevant digest is buffered
#   housekeeping catch-all scan -> NO duplicate digest
#   buffered digest flushes to the supervisor pane as exactly ONE submission
#   stale working-pane: transient (self + marker) -> persistent (escalates once,
#     clears its marker) -> resumed/busy (clears without escalating)
#
# This proves the operator-visible routing/queueing/dedupe behavior through real
# jg-watch.sh runs plus the daemon's own functions. The captain-relevant
# status-phrase matrix and the lock-primitive races stay as focused units
# (jg-daemon.test.sh, jg-watcher-lock.test.sh) - an e2e cannot deterministically
# cover a race, and the phrase list is a product contract worth a dedicated test.
set -u

# Re-enter the real journey as a child with hostile inherited owner paths.
if [ -z "${JG_WAKE_FIXTURE_SENTINEL:-}" ]; then
  exec env JG_WAKE_FIXTURE_SENTINEL=/nonexistent/Umer-owner-sentinel \
    JG_HOME=/nonexistent/Umer-owner-sentinel FM_HOME=/nonexistent/Umer-owner-sentinel \
    JG_STATE_OVERRIDE=/nonexistent/Umer-owner-sentinel/state \
    JG_CONFIG_OVERRIDE=/nonexistent/Umer-owner-sentinel/config \
    JG_DATA_OVERRIDE=/nonexistent/Umer-owner-sentinel/data \
    JG_ROOT_OVERRIDE=/nonexistent/Umer-owner-sentinel bash "$0"
fi

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
for owner_var in JG_HOME FM_HOME JG_STATE_OVERRIDE JG_CONFIG_OVERRIDE JG_DATA_OVERRIDE JG_ROOT_OVERRIDE; do
  case "${!owner_var-}" in "$JG_WAKE_FIXTURE_SENTINEL"*) fail "owner sentinel leaked into child: $owner_var" ;; esac
done
pass "wake fixture: inherited owner paths never reach the journey child"

WATCH="$ROOT/bin/jg-watch.sh"
DRAIN="$ROOT/bin/jg-wake-drain.sh"
DAEMON="$ROOT/bin/jg-supervise-daemon.sh"

# Source the daemon's pure functions (its main loop is guarded out under sourcing).
if [ -z "${JG_TEST_DAEMON_SOURCED:-}" ]; then
  export JG_TEST_DAEMON_SOURCED=1
  # shellcheck source=/dev/null
  . "$DAEMON"
fi

TMP_ROOT=$(jg_test_tmproot jg-wake-daemon-e2e)

# Run the daemon-managed watcher once: under the supervise-daemon (away mode) the
# watcher is one-shot - it exits with a single reason line on EVERY wake and the
# daemon does the triage. This e2e exercises exactly that path, so it runs with
# state/.afk present (which the daemon owns) to keep the watcher one-shot; the
# always-on standalone triage is covered by jg-watch-triage.test.sh. fakebin
# shadows tmux. Echoes nothing; the caller reads $out.
run_watcher_once() {
  local state=$1 fakebin=$2 out=$3
  mkdir -p "$state"
  date '+%s' > "$state/.afk"
  PATH="$fakebin:$PATH" JG_STATE_OVERRIDE="$state" JG_POLL=1 JG_SIGNAL_GRACE=1 \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 50
}

# Run the watcher once, but prove it keeps waiting: a `batch` row is queued and does not
# end the wait by itself, so it costs no turn (defaults/wake-routing). Stops it before returning.
run_watcher_still_waiting() {  # <state> <fakebin> <out>
  local state=$1 fakebin=$2 out=$3 pid i
  mkdir -p "$state"
  date '+%s' > "$state/.afk"
  PATH="$fakebin:$PATH" JG_STATE_OVERRIDE="$state" JG_POLL=1 JG_SIGNAL_GRACE=1 \
    JG_CHECK_INTERVAL=999999 JG_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  for i in $(seq 1 50); do
    is_live_non_zombie "$pid" || return 1
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait_for_exit "$pid" 20 >/dev/null 2>&1 || true
  return 0
}

ack_handled_wakes() {  # <state> <drain-stderr>
  local state=$1 drain_err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  JG_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# --- Phase 1: routine self-handled, queued; terminal caught after restart ---
test_routine_then_terminal_after_restart() {
  local dir state fakebin out drain_out drain_err status_file terminal_file
  dir=$(make_supercase wd-lifecycle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task-w1.status"
  terminal_file="$state/task-w2.status"

  # A routine status is a batched wake: it is queued and the watcher keeps waiting, so
  # the line costs no turn of its own.
  printf 'working: building\n' > "$status_file"
  run_watcher_still_waiting "$state" "$fakebin" "$out" || fail "watcher exited for a routine status line"

  # Drain it and route through the daemon: a routine status self-handles.
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain after routine signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "routine signal was not queued"
  JG_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  ack_handled_wakes "$state" "$drain_err" || fail "routine wake acknowledgement failed"
  [ ! -s "$state/.subsuper-escalations" ] || fail "routine status was escalated by the daemon"

  # The watcher is now DOWN. A terminal status lands while it is down; the next
  # watcher run must catch it up (losslessness across restart).
  printf 'done: PR https://example.test/pr/900\n' > "$terminal_file"
  : > "$out"
  run_watcher_once "$state" "$fakebin" "$out" || fail "restarted watcher did not exit for the terminal signal"
  grep -F "$terminal_file" "$out" >/dev/null || fail "terminal signal written while watcher down was not caught on restart"

  # Drain and route the terminal: exactly ONE digest is buffered.
  : > "$drain_out"
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain after terminal signal failed"
  JG_STATE_OVERRIDE="$state" handle_wake "signal: $terminal_file" "$state"
  ack_handled_wakes "$state" "$drain_err" || fail "terminal wake acknowledgement failed"
  [ -s "$state/.subsuper-escalations" ] || fail "captain-relevant terminal status was not buffered"

  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "expected exactly one buffered digest after the terminal signal"

  # The catch-all heartbeat scan must NOT re-escalate the same status (no dup).
  JG_STATE_OVERRIDE="$state" housekeeping "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "catch-all scan duplicated the already-buffered digest"

  # With afk active, the buffered digest flushes to the supervisor pane as ONE
  # submission (one typed line + one Enter), then the buffer clears.
  local sent
  sent="$dir/sent.log"; : > "$sent"
  printf '❯\n' > "$dir/pane.txt"
  afk_enter "$state"
  PATH="$fakebin:$PATH" JG_FAKE_TMUX_PANE_ALIVE=1 JG_FAKE_TMUX_SENT="$sent" \
    JG_FAKE_TMUX_CAPTURE="$dir/pane.txt" JG_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed for the buffered digest"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "buffered digest was not submitted exactly once"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a successful flush"
  pass "lifecycle: routine self-handles, terminal survives a watcher restart, buffers once, no dup, injects once"
}

# --- Phase 2: stale working-pane transient -> persistent -> resumed ----------
test_stale_pane_transient_persistent_resume() {
  local dir state fakebin win key resumed_gen
  dir=$(make_supercase wd-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:jg-stale-w2"
  key=$(printf '%s' "stale-w2" | tr ':/.' '___')
  printf 'working: compiling\n' > "$state/stale-w2.status"

  # Transient: first stale observation self-handles and records a marker.
  stale_marker_record "$win" "$state"
  case "$(JG_STATE_OVERRIDE="$state" classify_stale "$win" "$state")" in
    self\|*) : ;;
    *) fail "transient stale did not self-handle" ;;
  esac
  [ -e "$state/.subsuper-stale-$key" ] || fail "transient stale did not record a persistence marker"

  # Persistent: the marker ages past the threshold and the pane is still idle, so
  # housekeeping escalates exactly once and clears the marker.
  printf 'idle prompt $\n' > "$dir/pane.txt"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  : > "$state/.subsuper-escalations" 2>/dev/null || true
  PATH="$fakebin:$PATH" JG_FAKE_TMUX_WINDOW="$win" JG_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    JG_STATE_OVERRIDE="$state" JG_STALE_ESCALATE_SECS=240 housekeeping "$state" \
    2>"$dir/housekeeping.err"
  [ ! -s "$dir/housekeeping.err" ] \
    || fail "missing task metadata leaked a raw read error: $(cat "$dir/housekeeping.err")"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale did not escalate"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"

  # Resumed: a fresh transient marker but the crew is provably working again ->
  # housekeeping clears the marker without escalating. The proof is the crew's
  # own semantic busy-state record (bin/jg-busy-lib.sh), not rendered pane text.
  stale_marker_record "$win" "$state"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  printf 'Working...\n' > "$dir/pane.txt"
  jg_write_meta "$state/stale-w2.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  resumed_gen=$("$ROOT/bin/jg-busy-event.sh" arm "$state" stale-w2)
  "$ROOT/bin/jg-busy-event.sh" apply "$state" stale-w2 busy --gen "$resumed_gen" \
    --source pi-ext --event agent-start
  : > "$state/.subsuper-escalations"
  PATH="$fakebin:$PATH" JG_FAKE_TMUX_WINDOW="$win" JG_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    JG_STATE_OVERRIDE="$state" JG_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "resumed stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "resumed (busy) stale was escalated"
  pass "lifecycle: stale pane transient self-handles, persistent escalates once and clears, resumed clears quietly"
}

test_routine_then_terminal_after_restart
test_stale_pane_transient_persistent_resume
