#!/usr/bin/env bash
# tests/jg-captain-note-ack-gate.test.sh - an acknowledgement cannot retire a
# wake batch that still holds an unanswered captain inbox note, and every drain
# prints those notes first as a must-answer list.
#
# Every case drives the real producers and consumers over a real fixture home:
# bin/jg-inbox.sh writes the note (and its wake row), bin/jg-wake-drain.sh
# presents and acknowledges, and bin/jg-wake-bus.sh is the bus those two share.
# The incident these cases hold down is Main42437/Main42458: a "Yes, remove it"
# note arrived as a check wake, the batch was acknowledged without handling it,
# and two questions from 14 November then had no wake row left to bring them
# back.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/jg-wake-drain.sh"
INBOX_BIN="$ROOT/bin/jg-inbox.sh"
BUS="$ROOT/bin/jg-wake-bus.sh"
TMP_ROOT=$(jg_test_tmproot jg-captain-note-ack-gate)

# run_inbox <state> <args...>: the real captain note producer and answer path.
run_inbox() {
  local state=$1
  shift
  JG_HOME="${state%/state}" JG_STATE_OVERRIDE="$state" "$INBOX_BIN" "$@"
}

# run_drain <state> [<args>...]: the real presentation and acknowledgement path.
run_drain() {
  local state=$1
  shift
  JG_STATE_OVERRIDE="$state" "$DRAIN" "$@"
}

# ack_sequence <file> / ack_generation <file>: the two halves of the drain's own
# WAKE_ACK_REQUIRED command, read exactly as it printed them.
ack_sequence() { sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$1" | tail -1; }
ack_generation() { sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$1" | tail -1; }

# note_ids <state>: the unanswered notes still in the home, oldest first.
note_ids() { find "$1/inbox" -maxdepth 1 -name '*.note' -exec basename {} .note \; 2>/dev/null | sort; }

# queued_rows <state>: the rows still queued for the next acknowledgement.
queued_rows() {
  if [ -f "$1/.wake-queue" ]; then
    awk 'END { print NR + 0 }' "$1/.wake-queue"
  else
    printf '0\n'
  fi
}

line_of() {  # <file> <grep pattern>: the first matching line number
  grep -n -m 1 "$2" "$1" 2>/dev/null | cut -d: -f1
}

test_drain_prints_unanswered_notes_first_as_a_must_answer_list() {
  local dir state out err id heading_line row_line

  dir=$(make_case note-first)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  run_inbox "$state" note 'Yes, remove it' >/dev/null || fail 'the real note producer failed'
  id=$(note_ids "$state")
  [ -n "$id" ] || fail 'the note was not saved'
  # A later unrelated row must never push the note down the list.
  append_wake "$state" signal task1 'watcher fired'

  run_drain "$state" > "$out" 2> "$err" || fail 'the drain failed'

  heading_line=$(line_of "$out" '^CAPTAIN NOTES - MUST ANSWER FIRST')
  row_line=$(line_of "$out" 'watcher fired')
  [ -n "$heading_line" ] || fail "the drain printed no must-answer list: $(cat "$out")"
  [ -n "$row_line" ] || fail "the drain presented no wake row: $(cat "$out")"
  [ "$heading_line" -lt "$row_line" ] \
    || fail "the captain notes did not lead the drain (notes at $heading_line, wake rows at $row_line)"
  assert_contains "$(cat "$out")" "$id" 'the must-answer list did not name the unanswered note'
  assert_contains "$(cat "$out")" 'Yes, remove it' 'the must-answer list did not carry the words of the note'
  assert_contains "$(cat "$out")" 'jg-inbox.sh reply' 'the must-answer list did not say how to answer'

  pass 'an unanswered captain note leads every drain as a must-answer list'
}

test_acknowledgement_is_refused_while_the_note_is_unanswered() {
  local dir state err id seq gen queued_before

  dir=$(make_case note-ack-refused)
  state="$dir/state"

  run_inbox "$state" note 'Two questions about the release' >/dev/null || fail 'the real note producer failed'
  id=$(note_ids "$state")
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" || fail 'the drain failed'
  seq=$(ack_sequence "$dir/drain.err")
  gen=$(ack_generation "$dir/drain.err")
  [ -n "$seq" ] && [ -n "$gen" ] || fail 'the drain printed no acknowledgement command'

  if JG_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/ack.out" 2> "$dir/ack.err"; then
    fail 'an acknowledgement retired a batch whose captain note had no reply and no acknowledgement'
  fi
  err=$(cat "$dir/ack.err")
  assert_contains "$err" 'ACKNOWLEDGEMENT REFUSED' 'the refusal did not name itself'
  assert_contains "$err" "$id" 'the refusal did not name the unanswered note'
  assert_contains "$err" 'jg-inbox.sh reply' 'the refusal did not name the reply path'
  assert_contains "$err" 'jg-inbox.sh drain --ack' 'the refusal did not name the drain acknowledgement path'

  queued_before=$(queued_rows "$state")
  [ "$queued_before" -gt 0 ] || fail 'the refused acknowledgement consumed the queued rows anyway'

  pass 'an acknowledgement is refused while a captain note in the batch is unanswered'
}

test_reply_unblocks_the_acknowledgement() {
  local dir state id seq gen

  dir=$(make_case note-reply-unblocks)
  state="$dir/state"

  run_inbox "$state" note 'Is the dashboard still there?' >/dev/null || fail 'the real note producer failed'
  id=$(note_ids "$state")
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" || fail 'the drain failed'
  seq=$(ack_sequence "$dir/drain.err")
  gen=$(ack_generation "$dir/drain.err")

  run_inbox "$state" reply "$id" 'It is gone now.' >/dev/null || fail 'the real reply path failed'
  JG_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/ack.out" 2> "$dir/ack.err" || fail "the answered note still blocked the acknowledgement: $(cat "$dir/ack.err")"
  [ "$(queued_rows "$state")" = 0 ] || fail 'the acknowledged row stayed queued after the note was answered'
  if grep -q '^CAPTAIN NOTES' "$dir/ack.out"; then fail 'an answered note was still listed as must-answer'; fi

  pass 'a recorded reply lets the acknowledgement through'
}

test_drain_acknowledgement_of_the_note_itself_unblocks_the_acknowledgement() {
  local dir state id seq gen

  dir=$(make_case note-drain-ack)
  state="$dir/state"

  run_inbox "$state" note 'No reply needed, just close this one' >/dev/null || fail 'the real note producer failed'
  id=$(note_ids "$state")
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" || fail 'the drain failed'
  seq=$(ack_sequence "$dir/drain.err")
  gen=$(ack_generation "$dir/drain.err")

  run_inbox "$state" drain --ack "$id" >/dev/null || fail 'the real drain acknowledgement failed'
  JG_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/ack.out" 2> "$dir/ack.err" || fail "the acknowledged note still blocked the wake acknowledgement: $(cat "$dir/ack.err")"
  [ "$(queued_rows "$state")" = 0 ] || fail 'the acknowledged row stayed queued after the note itself was acknowledged'

  pass 'acknowledging the note itself lets the wake acknowledgement through'
}

test_a_note_whose_row_was_already_retired_still_leads_the_next_drain() {
  local dir state id ids out err

  dir=$(make_case note-row-retired)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  run_inbox "$state" note 'Questions from 14 November' >/dev/null || fail 'the real note producer failed'
  id=$(note_ids "$state")
  # The damage the old path did: the row is consumed while the note is untouched.
  ids=$(JG_STATE_OVERRIDE="$state" "$BUS" ids-through 999999999999999 2>/dev/null) || ids=
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086  # one bus event id per line
    JG_STATE_OVERRIDE="$state" "$BUS" ack $ids >/dev/null || fail 'the fixture could not retire the row'
  fi
  [ "$(queued_rows "$state")" = 0 ] || fail 'the fixture did not retire the wake row'

  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail 'the drain failed on an empty queue'
  assert_contains "$(cat "$out")" 'CAPTAIN NOTES - MUST ANSWER FIRST' \
    'a note with no remaining wake row disappeared from the drain'
  assert_contains "$(cat "$out")" "$id" 'the must-answer list lost the note whose row was retired'
  assert_contains "$(cat "$out")" 'Questions from 14 November' 'the recovered note lost its words'

  pass 'a note survives its wake row and keeps leading every later drain'
}

test_a_note_that_arrived_after_the_batch_does_not_block_that_batch() {
  local dir state first seq gen

  dir=$(make_case note-later-arrival)
  state="$dir/state"

  run_inbox "$state" note 'First note, answered before the acknowledgement' >/dev/null || fail 'the real note producer failed'
  first=$(note_ids "$state")
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" || fail 'the drain failed'
  seq=$(ack_sequence "$dir/drain.err")
  gen=$(ack_generation "$dir/drain.err")
  run_inbox "$state" reply "$first" 'Answered.' >/dev/null || fail 'the real reply path failed'

  # A newer note arrived after that presentation: its row is above the cutoff,
  # so this older acknowledgement neither owes it nor may consume it.
  run_inbox "$state" note 'Second note, arrived after the batch was presented' >/dev/null || fail 'the real note producer failed'
  JG_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" \
    > "$dir/ack.out" 2> "$dir/ack.err" || fail "a later note blocked an older batch: $(cat "$dir/ack.err")"

  [ "$(queued_rows "$state")" -gt 0 ] || fail 'the older acknowledgement consumed a row that arrived after it'
  JG_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/next.out" 2> "$dir/next.err" || fail 'the next drain failed'
  assert_contains "$(cat "$dir/next.out")" 'Second note, arrived after the batch was presented' \
    'the later note did not lead the next drain'
  if grep -q 'First note, answered before the acknowledgement' "$dir/next.out"; then
    fail 'the next drain listed a note that had already been answered'
  fi

  pass 'an acknowledgement is judged on the batch it names, and a later note is presented next time'
}

test_drain_prints_unanswered_notes_first_as_a_must_answer_list
test_acknowledgement_is_refused_while_the_note_is_unanswered
test_reply_unblocks_the_acknowledgement
test_drain_acknowledgement_of_the_note_itself_unblocks_the_acknowledgement
test_a_note_whose_row_was_already_retired_still_leads_the_next_drain
test_a_note_that_arrived_after_the_batch_does_not_block_that_batch
