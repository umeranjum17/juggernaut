#!/usr/bin/env bash
# Tests for bin/jg-pr-wait.sh and bin/jg-pr-lib.sh jg_pr_wait_status: the
# one-line wait a pull request shows on its own page, so nobody has to ask what
# it is waiting for.
#
# These prove the published artifact through the script's own CLI and a gh stub
# that records the exact arguments it was given. The merge path's use of the same
# status, including the pending-status deadlock and the cleared wait on a merged
# pull request, is proven in tests/jg-pr-merge.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_WAIT="$ROOT/bin/jg-pr-wait.sh"
PR_URL=https://github.com/example/repo/pull/42
HEAD=0123456789abcdef0123456789abcdef01234567
BASE_PATH=$PATH

TMP_ROOT=$(jg_test_tmproot jg-pr-wait-tests)

# A gh stub that answers the head read and records every status post, so each
# case asserts one exact invocation rather than a substring of a wider log.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/fakebin"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/gh.log"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*)
        [ -f "$case_dir/head-fail" ] && exit 1
        printf '%s\n' "$HEAD"
        exit 0
        ;;
    esac
    exit 1
    ;;
  "api -X")
    [ -f "$case_dir/api-fail" ] && exit 1
    printf '{}\n'
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

run_pr_wait() {
  local case_dir=$1 rc; shift
  PATH="$case_dir/fakebin:$BASE_PATH" "$PR_WAIT" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  return "$rc"
}

test_set_publishes_one_pending_line() {
  local case_dir rc
  case_dir=$(make_case set-pending)
  rc=0
  run_pr_wait "$case_dir" "$PR_URL" set 'captain decision: which release name' || rc=$?
  expect_code 0 "$rc" "set-pending: set should succeed"
  assert_grep "api -X POST repos/example/repo/statuses/$HEAD" "$case_dir/gh.log" \
    "set-pending: the status was not posted to the pull request head"
  assert_grep 'state=pending' "$case_dir/gh.log" \
    "set-pending: a wait must be published as pending"
  assert_grep 'context=juggernaut/waiting-for' "$case_dir/gh.log" \
    "set-pending: the status used a different context"
  assert_grep 'description=captain decision: which release name' "$case_dir/gh.log" \
    "set-pending: the wait line was not published"
  assert_grep "target_url=$PR_URL" "$case_dir/gh.log" \
    "set-pending: the status did not link back to the pull request"
  pass "jg-pr-wait publishes one pending wait line on the pull request head"
}

test_clear_publishes_success() {
  local case_dir rc
  case_dir=$(make_case clear-success)
  rc=0
  run_pr_wait "$case_dir" "$PR_URL" clear || rc=$?
  expect_code 0 "$rc" "clear-success: clear should succeed"
  assert_grep 'state=success' "$case_dir/gh.log" \
    "clear-success: a cleared wait must be published as success, never pending"
  assert_grep 'description=no wait' "$case_dir/gh.log" \
    "clear-success: the cleared status did not say there is no wait"
  assert_no_grep 'state=pending' "$case_dir/gh.log" \
    "clear-success: clearing left a pending status behind"
  pass "jg-pr-wait clears the wait to success"
}

# One short plain line is the whole point: a newline or a stray double space
# would make the status read like a log dump instead of a wait.
test_line_is_collapsed_and_capped() {
  local case_dir rc desc
  case_dir=$(make_case line-shape)
  rc=0
  run_pr_wait "$case_dir" "$PR_URL" set "$(printf 'proof   re-run\nat the new head')" || rc=$?
  expect_code 0 "$rc" "line-shape: set should succeed"
  assert_grep 'description=proof re-run at the new head' "$case_dir/gh.log" \
    "line-shape: the wait line was not collapsed to one line"
  assert_no_grep 'description=proof   re-run' "$case_dir/gh.log" \
    "line-shape: repeated spaces survived in the wait line"
  rc=0
  run_pr_wait "$case_dir" "$PR_URL" set "$(printf 'x%.0s' $(seq 1 400))" || rc=$?
  expect_code 0 "$rc" "line-shape: an over-long line should still publish"
  desc=$(grep -F 'description=' "$case_dir/gh.log" | grep -F 'xxx' | head -n 1 \
    | sed 's/.*-f description=//; s/ -f target_url=.*//')
  [ "${#desc}" -le 140 ] || fail "line-shape: the description exceeded GitHub's 140-character limit (${#desc})"
  pass "the wait line is one line capped at the status description limit"
}

# commit statuses are a GitHub concept; a merge request on another forge is
# accepted and left untouched rather than refused, so no caller has to know
# which forge it is holding.
test_other_forges_are_left_alone() {
  local case_dir rc
  case_dir=$(make_case other-forge)
  rc=0
  run_pr_wait "$case_dir" https://gitlab.example/group/project/-/merge_requests/7 set 'waiting' || rc=$?
  expect_code 0 "$rc" "other-forge: a non-GitHub URL should be accepted"
  [ -s "$case_dir/gh.log" ] && fail "other-forge: a non-GitHub merge request reached gh"
  pass "a non-GitHub merge request is accepted and left untouched"
}

test_bad_requests_are_refused() {
  local case_dir rc
  case_dir=$(make_case bad-requests)
  rc=0
  run_pr_wait "$case_dir" https://example.invalid/not-a-pr set 'waiting' || rc=$?
  expect_code 2 "$rc" "bad-requests: an unparseable URL should be a usage error"
  rc=0
  run_pr_wait "$case_dir" "$PR_URL" set '' || rc=$?
  expect_code 2 "$rc" "bad-requests: an empty wait line should be a usage error"
  rc=0
  run_pr_wait "$case_dir" "$PR_URL" sprinkle 'waiting' || rc=$?
  expect_code 2 "$rc" "bad-requests: an unknown verb should be a usage error"
  [ -s "$case_dir/gh.log" ] && fail "bad-requests: a refused request still reached gh"
  pass "jg-pr-wait refuses a bad URL, an empty line and an unknown verb"
}

test_publish_failure_is_reported() {
  local case_dir rc
  case_dir=$(make_case publish-fails)
  : > "$case_dir/api-fail"
  rc=0
  run_pr_wait "$case_dir" "$PR_URL" set 'waiting' || rc=$?
  expect_code 1 "$rc" "publish-fails: a failed forge call should report failure"
  assert_grep 'could not publish the wait status' "$case_dir/stderr" \
    "publish-fails: the failure was not reported"
  pass "jg-pr-wait reports a forge call that failed"
}

test_set_publishes_one_pending_line
test_clear_publishes_success
test_line_is_collapsed_and_capped
test_other_forges_are_left_alone
test_bad_requests_are_refused
test_publish_failure_is_reported
