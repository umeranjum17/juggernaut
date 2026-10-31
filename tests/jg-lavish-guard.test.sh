#!/usr/bin/env bash
# The Lavish refusal guard, replayed from the real incident: a report reached
# the captain as a Lavish page on port 4387 after Lavish was retired and
# sign-off became the only report surface.
# The first case is that exact note. Every case drives a real command: the
# guard itself, the status-append form the generated worker instructions carry,
# and the report helper a lead actually reports through.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/jg-lavish-guard.sh"
REPORT="$ROOT/bin/jg-squad-lead-report.sh"
TMP_ROOT=$(jg_test_tmproot jg-lavish-guard)

# Tonight's real case: the note is a done report whose whole finding is a link
# to a Lavish page on the retired port.
TONIGHT='done [at=1793417000]: report at http://review.example:4387/session/876d22727c2c3776'

guard() {  # <text> -> ERR, RC: the guard's own line is ERR, so only its status is kept
  printf '%s\n' "$1" | bash "$GUARD" 2>"$TMP_ROOT/stderr"
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

test_tonights_report_link_is_refused() {
  guard "$TONIGHT"
  [ "$RC" -eq 1 ] || fail "a report linking a Lavish page must be refused, got exit $RC"
  assert_contains "$ERR" 'sign-off board (sign-off-axi)' \
    'the refusal tells the worker to post on sign-off instead'
  pass 'a report whose link is a Lavish page on port 4387 is refused, and the refusal names sign-off'
}

test_a_lavish_publish_command_is_refused() {
  local text
  for text in 'lavish-axi review.html' 'lavish-axi publish board' 'cd x && lavish-axi .lavish/board.htm'; do
    guard "$text"
    [ "$RC" -eq 1 ] || fail "a Lavish publish command must be refused: $text"
    assert_contains "$ERR" 'sign-off board (sign-off-axi)' "the publish refusal names sign-off: $text"
  done
  pass 'a Lavish publish command is refused and points at sign-off'
}

test_clean_report_text_passes() {
  local text
  for text in \
    'done [at=1793417000]: merged https://github.com/umeranjum17/juggernaut/pull/310' \
    'http://review.example:4388/board/umer' \
    'Lavish is retired; the sign-off board carries the report.' \
    ''; do
    guard "$text"
    [ "$RC" -eq 0 ] || fail "clean captain-facing text was refused: $text"
  done
  pass 'a sign-off link, a PR link, retirement prose, and empty text all pass'
}

test_the_status_append_form_writes_only_clean_lines() {
  local status="$TMP_ROOT/worker.status"
  rm -f "$status"
  printf '%s\n' "$TONIGHT" | bash "$GUARD" --append "$status" 2>"$TMP_ROOT/stderr" \
    && fail 'the status-append form accepted a Lavish link'
  assert_absent "$status" 'a refused status line never reached the status file'
  printf '%s\n' 'working [at=1793417000]: rebuilding the board on sign-off' \
    | bash "$GUARD" --append "$status" || fail 'the status-append form refused clean text'
  assert_grep 'rebuilding the board on sign-off' "$status" \
    'a clean status line is appended unchanged'
  pass 'the status-append form refuses tonight'"'"'s line and appends only clean lines'
}

test_the_lead_report_helper_refuses_before_append() {
  local dir="$TMP_ROOT/report"
  mkdir -p "$dir/state" "$dir/parent/state"
  printf 'umer\n' > "$dir/.jg-squad-lead-home"
  printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" \
    > "$dir/.jg-squad-lead-parent"
  JG_HOME="$dir" bash "$REPORT" 'done' abcdef0123456789 "$TONIGHT" 2>"$dir/stderr" \
    && fail 'the report helper accepted a Lavish report link'
  assert_contains "$(cat "$dir/stderr")" 'sign-off board (sign-off-axi)' \
    'the report helper surfaces the sign-off instruction'
  assert_absent "$dir/parent/state/umer.status" 'a refused report wrote nothing to the parent channel'
  JG_HOME="$dir" bash "$REPORT" 'done' abcdef0123456789 'board: http://review.example:4388/board/umer' \
    2>>"$dir/stderr" || fail 'the report helper refused a sign-off report link'
  assert_grep 'board: http://review.example:4388/board/umer' "$dir/parent/state/umer.status" \
    'the sign-off report link reaches the parent channel'
  pass 'the report helper refuses before append and accepts the sign-off link'
}

test_tonights_report_link_is_refused
test_a_lavish_publish_command_is_refused
test_clean_report_text_passes
test_the_status_append_form_writes_only_clean_lines
test_the_lead_report_helper_refuses_before_append
printf 'jg-lavish-guard: ok\n'
