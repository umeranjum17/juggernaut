#!/usr/bin/env bash
# Behavior tests for bin/jg-loss-claim-check.sh.
#
# A plan or report never says a capability is lost without naming its
# replacement path and an effort. These tests drive the real check over small
# fixture plans: a loss line with no path fails, with a path passes, and a plan
# with no loss lines passes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/jg-loss-claim-check.sh"
TMP_ROOT=$(jg_test_tmproot jg-loss-claim-check)

fixture() {  # <name> <body> -> echoes the path
  local path="$TMP_ROOT/$1.md"
  printf '%s\n' "$2" > "$path"
  printf '%s\n' "$path"
}

test_loss_with_no_path_fails() {
  local plan out rc
  plan=$(fixture no-path '# Move to Pi

We lose auto learning when we leave the old engine.')
  out=$(bash "$CHECK" "$plan" 2>&1); rc=$?
  expect_code 1 "$rc" "a loss line with no path should fail (got: $out)"
  assert_contains "$out" "no-path.md:3: loss claim without a replacement path" "the refusal did not name the line and the missing path"
  assert_contains "$out" "an effort estimate" "the refusal did not name the missing effort"
  pass "jg-loss-claim-check.sh: a loss line with no path fails"
}

test_loss_with_path_and_effort_passes() {
  local plan out rc
  plan=$(fixture with-path '# Move to Pi

We lose auto learning when we leave the old engine.
Replacement: copy the community auto-learn extension, effort ~2 days.')
  out=$(bash "$CHECK" "$plan" 2>&1); rc=$?
  expect_code 0 "$rc" "a loss line with a path and effort should pass (got: $out)"
  assert_contains "$out" "1 loss line" "the pass line did not count the loss line"
  pass "jg-loss-claim-check.sh: a loss line with a path and effort passes"
}

test_path_without_effort_fails() {
  local plan out rc
  plan=$(fixture no-effort 'Hooks are no longer available. We can build our own extension for them.')
  out=$(bash "$CHECK" "$plan" 2>&1); rc=$?
  expect_code 1 "$rc" "a path with no effort should fail (got: $out)"
  assert_contains "$out" "loss claim without an effort estimate" "the refusal did not name the missing effort alone"
  pass "jg-loss-claim-check.sh: a path with no effort fails"
}

test_plan_without_loss_lines_passes() {
  local plan out rc
  plan=$(fixture no-loss '# Plan

Add a new extension. Nothing is lost in the move.
The cache keeps every entry; the old data is not lost.')
  out=$(bash "$CHECK" "$plan" 2>&1); rc=$?
  expect_code 0 "$rc" "a plan with no loss lines should pass (got: $out)"
  assert_contains "$out" "0 loss line" "the pass line did not report zero loss lines"
  pass "jg-loss-claim-check.sh: a plan with no loss lines passes"
}

test_path_in_another_block_does_not_cover_a_loss() {
  local plan out rc
  plan=$(fixture other-block '- Dropping the old CLI means we lose the export command.

- Copy the community export package, effort 1 day.')
  out=$(bash "$CHECK" "$plan" 2>&1); rc=$?
  expect_code 1 "$rc" "a path in a different block should not cover the loss (got: $out)"
  assert_contains "$out" "other-block.md:1:" "the refusal did not name the loss line"
  pass "jg-loss-claim-check.sh: a path in another block does not cover a loss"
}

test_each_list_item_and_table_row_is_its_own_block() {
  local plan out rc
  plan=$(fixture items '- We lose hooks. Port them from the community package, 3 days.
- We lose themes.
| Feature | Status |
| macros | dropped |')
  out=$(bash "$CHECK" "$plan" 2>&1); rc=$?
  expect_code 1 "$rc" "uncovered list items and table rows should fail (got: $out)"
  assert_contains "$out" "items.md:2:" "the uncovered list item was not flagged"
  assert_contains "$out" "items.md:4:" "the uncovered table row was not flagged"
  assert_not_contains "$out" "items.md:1:" "the covered list item was flagged"
  pass "jg-loss-claim-check.sh: list items and table rows are checked one by one"
}

test_usage_errors_exit_2() {
  local out rc
  out=$(bash "$CHECK" 2>&1); rc=$?
  expect_code 2 "$rc" "no argument should be a usage error (got: $out)"
  out=$(bash "$CHECK" "$TMP_ROOT/missing.md" 2>&1); rc=$?
  expect_code 2 "$rc" "a missing file should be a usage error (got: $out)"
  pass "jg-loss-claim-check.sh: usage errors exit 2"
}

test_loss_with_no_path_fails
test_loss_with_path_and_effort_passes
test_path_without_effort_fails
test_plan_without_loss_lines_passes
test_path_in_another_block_does_not_cover_a_loss
test_each_list_item_and_table_row_is_its_own_block
test_usage_errors_exit_2
