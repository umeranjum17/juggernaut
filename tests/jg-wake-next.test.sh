#!/usr/bin/env bash
# tests/jg-wake-next.test.sh - behavior tests for bin/jg-wake-next.sh, the
# one-call fetch of the next wake together with its acknowledgement token.
# Every case drives the REAL jg-wake-next.sh and the REAL jg-wake-drain.sh over a
# real durable queue, and proves the single call is a true replacement for
# drain-then-parse: it returns the wake the drain would return, and the token it
# prints retires that same row when run.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

NEXT="$ROOT/bin/jg-wake-next.sh"
DRAIN="$ROOT/bin/jg-wake-drain.sh"

TMP_ROOT=$(jg_test_tmproot jg-wake-next-tests)

# The presented row's identity with the arrival timestamp dropped, so two
# separate queue fixtures carrying the same appended wake compare equal while a
# wrong kind, key, payload, or sequence does not.
row_identity() {  # <file>
  awk -F '\t' '$2 == "1" && $3 == "signal" && $4 == "task1" { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$1"
}

# The --ack-through sequence a drain-style acknowledgement names, from either
# the drain's own WAKE_ACK_REQUIRED line or the new command's WAKE_NEXT_ACK line.
ack_sequence() {  # <file>
  sed -n 's/.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$1" | tail -1
}

# The runnable acknowledgement command the new call printed.
next_ack_command() {  # <file>
  sed -n 's/^WAKE_NEXT_ACK: \(bin\/jg-wake-drain\.sh .*\)$/\1/p' "$1" | tail -1
}

# Run one acknowledgement command exactly as printed, from the repo root so its
# relative bin/ path resolves.
run_ack() {  # <state> <command>
  local state=$1 command=$2
  ( cd "$ROOT" && JG_STATE_OVERRIDE="$state" bash -c "$command" )
}

queued_rows() {  # <state>
  awk 'END { print NR + 0 }' "$1/.wake-queue" 2>/dev/null || printf '0\n'
}

test_single_call_returns_the_wake_the_drain_returns_and_retires_the_same_row() {
  local old_dir old_state old_out old_err old_seq old_identity
  local new_dir new_state new_out new_err new_ack new_seq new_identity

  # The old way: drain, read the acknowledgement off stderr, run it by hand.
  old_dir=$(make_case next-old-way)
  old_state="$old_dir/state"
  old_out="$old_dir/drain.out"
  old_err="$old_dir/drain.err"
  append_wake "$old_state" signal task1 'watcher fired'
  JG_STATE_OVERRIDE="$old_state" "$DRAIN" > "$old_out" 2> "$old_err" \
    || fail "the reference drain failed"
  old_seq=$(ack_sequence "$old_err")
  [ -n "$old_seq" ] || fail "the reference drain printed no acknowledgement to compare against"
  old_identity=$(row_identity "$old_out")
  [ -n "$old_identity" ] || fail "the reference drain presented no wake row"
  run_ack "$old_state" "$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run \(bin\/jg-wake-drain\.sh .*\)$/\1/p' "$old_err" | tail -1)" \
    || fail "the reference drain's own acknowledgement failed"
  [ "$(queued_rows "$old_state")" = 0 ] \
    || fail "the reference drain's acknowledgement did not retire the row"

  # The new way: one call, no parse, no hand-built command.
  new_dir=$(make_case next-single-call)
  new_state="$new_dir/state"
  new_out="$new_dir/next.out"
  new_err="$new_dir/next.err"
  append_wake "$new_state" signal task1 'watcher fired'
  JG_STATE_OVERRIDE="$new_state" "$NEXT" > "$new_out" 2> "$new_err" \
    || fail "the single call failed"

  new_identity=$(row_identity "$new_out")
  [ "$new_identity" = "$old_identity" ] \
    || fail "the single call returned a different wake than the drain would (expected '$old_identity', got '$new_identity')"
  new_ack=$(next_ack_command "$new_out")
  [ -n "$new_ack" ] || fail "the single call printed no acknowledgement command"
  new_seq=$(ack_sequence "$new_out")
  [ "$new_seq" = "$old_seq" ] \
    || fail "the single call named sequence '$new_seq' while the drain named '$old_seq'"
  ! grep -F 'WAKE_ACK_REQUIRED' "$new_out" "$new_err" >/dev/null \
    || fail "the single call still leaked the old acknowledgement line for the caller to parse"

  run_ack "$new_state" "$new_ack" || fail "the acknowledgement the single call printed failed"
  [ "$(queued_rows "$new_state")" = 0 ] \
    || fail "the acknowledgement the single call printed did not retire the row"

  pass "one call returns the wake the drain returns and its token retires that same row"
}

test_one_call_reports_nothing_to_acknowledge_when_the_queue_is_empty() {
  local dir state out err

  dir=$(make_case next-idle)
  state="$dir/state"
  out="$dir/next.out"
  err="$dir/next.err"
  : > "$state/.wake-queue"

  JG_STATE_OVERRIDE="$state" "$NEXT" > "$out" 2> "$err" \
    || fail "the single call failed on an idle queue"
  grep -Fx 'WAKE_NEXT_ACK: none' "$out" >/dev/null \
    || fail "an idle queue did not report nothing to acknowledge: $(cat "$out")"
  [ "$(queued_rows "$state")" = 0 ] || fail "an idle call invented a queued row"

  pass "an idle queue reports nothing to acknowledge instead of a bogus token"
}

test_one_call_relays_the_presentation_and_still_surfaces_open_decisions() {
  local dir state out err

  dir=$(make_case next-sections)
  state="$dir/state"
  out="$dir/next.out"
  err="$dir/next.err"
  append_wake "$state" signal task1 'watcher fired'
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task9.status"

  JG_STATE_OVERRIDE="$state" "$NEXT" > "$out" 2> "$err" \
    || fail "the single call failed over an open decision"
  grep -F 'OPEN DECISIONS' "$out" >/dev/null \
    || fail "the single call swallowed the drain's OPEN DECISIONS section"
  grep -F '[key=api-shape]' "$out" | grep -F 'pick REST or RPC' >/dev/null \
    || fail "the single call did not surface the open decision"
  [ "$(row_identity "$out")" != '' ] \
    || fail "the single call swallowed the presented wake row while relaying sections"

  pass "one call keeps every section the drain presents beside the wake and its token"
}

test_single_call_returns_the_wake_the_drain_returns_and_retires_the_same_row
test_one_call_reports_nothing_to_acknowledge_when_the_queue_is_empty
test_one_call_relays_the_presentation_and_still_surfaces_open_decisions
