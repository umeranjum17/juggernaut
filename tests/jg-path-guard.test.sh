#!/usr/bin/env bash
# The captain-facing path rule: a line with a raw file path is refused, a line
# with a board key is accepted, and a line with both is accepted. The last case
# drives the real parent-channel append so the check bites at write time.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/jg-path-guard.sh"
TMP_ROOT=$(jg_test_tmproot jg-path-guard)

guard() {  # <text> -> RC, ERR
  printf '%s\n' "$1" | bash "$GUARD" 2>"$TMP_ROOT/stderr"
  RC=$?
  ERR=$(cat "$TMP_ROOT/stderr")
}

test_a_line_with_a_path_fails() {
  local text
  for text in \
    'done [at=1]: shots in data/setup-deep-recon/page/plan-390.png' \
    'done [at=1]: see /home/you/x/plan.png' \
    'done [at=1]: see ~/x/plan.png' \
    'done [at=1]: log state/abc.status' \
    'done [at=1]: see .treehouse/firstmate-1/2/x'; do
    guard "$text"
    [ "$RC" -eq 1 ] || fail "a raw path must be refused: $text (exit $RC)"
    assert_contains "$ERR" 'board link' 'the refusal names the board link'
  done
  pass 'a line with a path is refused'
}

test_a_line_with_a_board_key_passes() {
  local text
  for text in \
    'done [at=1]: findings at #reports/setup-deep-recon' \
    'needs-decision [at=1]: pick one #decide/ch-1' \
    'done [at=1]: designs #designs/home'; do
    guard "$text"
    [ "$RC" -eq 0 ] || fail "a board-key line must pass: $text (exit $RC)"
  done
  pass 'a line with a board key passes'
}

test_a_line_with_both_passes() {
  guard 'done [at=1]: plan data/setup-deep-recon/page/plan-390.png #reports/setup-deep-recon'
  [ "$RC" -eq 0 ] || fail "a line with a path and a board key must pass (exit $RC)"
  guard 'done [at=1]: plan data/x/plan.png picture attached'
  [ "$RC" -eq 0 ] || fail "a line with a path and the picture marker must pass (exit $RC)"
  pass 'a line with both a path and a board key passes'
}

test_urls_and_plain_text_pass() {
  guard 'done [at=1]: PR https://github.com/o/r/pull/5 merged, data and state are fine words'
  [ "$RC" -eq 0 ] || fail "a URL and plain words must pass (exit $RC)"
  pass 'a URL is not a path'
}

test_parent_channel_withholds_a_path_at_write_time() {
  local f=$TMP_ROOT/channel.status body
  # shellcheck disable=SC1091
  . "$ROOT/bin/jg-parent-channel-lib.sh"
  jg_parent_channel_append_once "$f" 'done [at=1]: shot data/x/plan.png' || fail 'the parent channel append must still deliver'
  jg_parent_channel_append_once "$f" 'done [at=2]: shot data/x/plan.png #reports/x' || fail 'the parent channel append must still deliver'
  body=$(cat "$f")
  assert_contains "$body" 'done [at=1]: shot [file path withheld]' 'a path line is delivered with the path withheld'
  assert_contains "$body" 'data/x/plan.png #reports/x' 'a line with a board key is delivered unchanged'
  pass 'the parent channel append withholds a path and keeps a board-key line'
}

test_a_line_with_a_path_fails
test_a_line_with_a_board_key_passes
test_a_line_with_both_passes
test_urls_and_plain_text_pass
test_parent_channel_withholds_a_path_at_write_time
printf 'jg-path-guard: ok\n'
