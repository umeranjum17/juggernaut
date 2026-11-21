#!/usr/bin/env bash
# tests/jg-away-escalation-buffer.test.sh - the away-supervisor escalation buffer, end to end
# over a throwaway state root and a shimmed tmux.
#
# The buffer once replayed 489 events in one injection, 163 of them copies of the same three
# routine checks, so real events hid among duplicates. An event is keyed by its distilled
# text: a repeat of one still waiting is not buffered again, a delivered event leaves the
# buffer, and a new distinct event (or a repeat of a delivered one) reaches the next injection.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# Source the daemon's functions (its main loop is guarded out under sourcing).
if [ -z "${JG_TEST_DAEMON_SOURCED:-}" ]; then
  export JG_TEST_DAEMON_SOURCED=1
  # shellcheck source=/dev/null
  . "$ROOT/bin/jg-supervise-daemon.sh"
fi

# shellcheck disable=SC2034 # read by make_supercase in wake-helpers.sh
TMP_ROOT=$(jg_test_tmproot jg-away-escalation-buffer)

# flush_to_pane <state> <fakebin> <pane-capture> <sent-log>: one batched injection to the
# fake supervisor pane; the digest body lands in the operational inbox record it names.
flush_to_pane() {
  local state=$1 fakebin=$2 pane=$3 sent=$4
  rm -f "$state"/operational-inbox/*.msg
  : > "$sent"
  PATH="$fakebin:$PATH" JG_FAKE_TMUX_PANE_ALIVE=1 JG_FAKE_TMUX_SENT="$sent" \
    JG_FAKE_TMUX_CAPTURE="$pane" JG_ESCALATE_BATCH_SECS=0 escalate_flush "$state"
}

test_repeated_checks_buffer_once() {
  local dir state fakebin sent pane i delivered
  dir=$(make_supercase away-buffer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sent="$dir/sent.log"
  pane="$dir/pane.txt"
  printf '\342\235\257\n' > "$pane"
  : > "$state/.subsuper-escalations"
  afk_enter "$state"

  for i in $(seq 1 163); do
    escalate_add "$state" "check: poll-alpha is routine" || fail "escalate_add refused a repeated check"
    escalate_add "$state" "check: poll-beta is routine" || fail "escalate_add refused a repeated check"
    escalate_add "$state" "check: poll-gamma is routine" || fail "escalate_add refused a repeated check"
  done
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 3 ] \
    || fail "489 buffered adds of three routine checks did not collapse to three entries"

  flush_to_pane "$state" "$fakebin" "$pane" "$sent" || fail "escalate_flush failed for the deduplicated buffer"
  delivered=$(cat "$state"/operational-inbox/*.msg 2>/dev/null)
  case "$delivered" in *"Supervisor escalate (3 event(s))"*) : ;; *) fail "injection did not carry three events: $delivered" ;; esac
  for i in alpha beta gamma; do
    [ "$(printf '%s' "$delivered" | grep -o "poll-$i is routine" | wc -l | tr -d ' ')" -eq 1 ] \
      || fail "routine check poll-$i did not appear exactly once in the injection"
  done
  [ ! -s "$state/.subsuper-escalations" ] || fail "delivered entries stayed in the buffer"

  # A new distinct event, and a repeat of an already delivered check, reach the next injection.
  escalate_add "$state" "check: poll-delta is new" || fail "escalate_add refused a new event"
  escalate_add "$state" "check: poll-alpha is routine" || fail "escalate_add refused a delivered check's repeat"
  flush_to_pane "$state" "$fakebin" "$pane" "$sent" || fail "escalate_flush failed for the next injection"
  delivered=$(cat "$state"/operational-inbox/*.msg 2>/dev/null)
  case "$delivered" in *"poll-delta is new"*) : ;; *) fail "a new distinct event did not reach the next injection" ;; esac
  case "$delivered" in *"Supervisor escalate (2 event(s))"*) : ;; *) fail "next injection did not carry exactly the two waiting events: $delivered" ;; esac
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after the next injection"
  pass "away buffer: 163 repeats of three routine checks deliver three lines once, a new event still arrives"
}

test_repeated_checks_buffer_once
