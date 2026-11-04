#!/usr/bin/env bash
# bin/jg-pr-state.sh on a repository with no required check, and on one that
# requires every check. gh cannot tell "this base requires nothing" from "a
# required check has not started", so GitHub's mergeStateStatus decides, and the
# gate's own juggernaut/waiting-for status is never counted as pending.
# A fake gh evaluates the script's own jq programs over JSON fixtures, so the
# real parsing runs; the cases cover the verdict, not gh's jq engine
# (tests/jg-pr-state-live-e2e.test.sh owns that).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-pr-state)
SCRIPT="$ROOT/bin/jg-pr-state.sh"
PR=https://github.com/o/r/pull/9
BASE_PATH=$PATH

# A case dir holds the fixtures gh serves: pr.json (the pull request), all.json
# (every reported check), required.json (the checks gh marks required). An empty
# or absent checks file is gh's own "nothing reported" error for that scope.
make_case() {  # <name> <merge-state> -> echoes the case dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/fakebin"
  cat > "$d/pr.json" <<JSON
{"state":"OPEN","mergedAt":null,"isDraft":false,"headRefOid":"abc","author":{"login":"a"},
 "mergeable":"MERGEABLE","mergeStateStatus":"$2","reviewDecision":""}
JSON
  cat > "$d/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
prog='' prev='' scope=all
for arg in "$@"; do
  [ "$prev" = --jq ] && prog=$arg
  [ "$arg" = --required ] && scope=required
  prev=$arg
done
case "${1:-} ${2:-}" in
  "pr view") jq -r "$prog" < "$JG_FAKE_DIR/pr.json" ;;
  "pr checks")
    if [ ! -s "$JG_FAKE_DIR/$scope.json" ]; then
      if [ "$scope" = required ]; then
        printf "no required checks reported on the 'main' branch\n" >&2
      else
        printf "no checks reported on the 'main' branch\n" >&2
      fi
      exit 1
    fi
    jq -r "$prog" < "$JG_FAKE_DIR/$scope.json" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$d/fakebin/gh"
  printf '%s\n' "$d"
}

state() {  # <case-dir> [flag] -> the script's stdout
  PATH="$1/fakebin:$BASE_PATH" JG_FAKE_DIR="$1" "$SCRIPT" ${2:+"$2"} "$PR"
}

WAIT='{"name":"juggernaut/waiting-for","state":"PENDING","bucket":"pending"}'
CI_OK='{"name":"CI","state":"SUCCESS","bucket":"pass"}'
LINT_RED='{"name":"Lint","state":"FAILURE","bucket":"fail"}'

test_no_required_check_passes_when_every_reported_check_is_green() {
  local d
  d=$(make_case green UNSTABLE)
  printf '[%s,%s]\n' "$CI_OK" "$WAIT" > "$d/all.json"
  assert_equals "" "$(state "$d")" \
    "no required check and every reported check green reads as no blocker"
  assert_contains "$(state "$d" --waiting-for)" "juggernaut/waiting-for: the merge call" \
    "the wait is the merge call, not the required checks"
  printf '[%s]\n' "$WAIT" > "$d/all.json"
  assert_equals "" "$(state "$d")" \
    "the gate's own waiting-for status alone is never a pending check"
  pass "a repository with no required check passes on green reported checks"
}

test_no_required_check_still_reports_a_red_check() {
  local d out
  d=$(make_case red UNSTABLE)
  printf '[%s,%s,%s]\n' "$CI_OK" "$LINT_RED" "$WAIT" > "$d/all.json"
  out=$(state "$d")
  assert_equals "CHECK: Lint (FAILURE)" "$out" \
    "a red reported check is the only blocker, and the wait status is not one"
  assert_contains "$(state "$d" --waiting-for)" "a check is not passing: Lint" \
    "the wait names the red check"
  pass "a repository with no required check still blocks on a red reported check"
}

test_unmet_required_check_stays_unconfirmed() {
  local d out
  d=$(make_case blocked BLOCKED)
  printf '[%s,%s]\n' "$CI_OK" "$WAIT" > "$d/all.json"
  out=$(state "$d")
  assert_contains "$out" "no required check has reported; readiness unconfirmed" \
    "a BLOCKED merge state keeps the required check that has not reported unconfirmed"
  assert_contains "$(state "$d" --waiting-for)" "the required checks have not reported yet" \
    "the wait is the unreported required check"
  pass "a pull request blocked on an unreported required check stays unconfirmed"
}

test_nothing_reported_at_all_is_not_read_as_ready() {
  local d
  d=$(make_case none CLEAN)
  assert_contains "$(state "$d")" "CHECKS: none reported yet" \
    "a pull request with no check of any kind is printed, not read as ready"
  pass "no reported check at all is printed rather than read as ready"
}

test_required_waiting_for_status_is_never_pending() {
  local d out
  d=$(make_case reqwait BLOCKED)
  printf '[%s,%s]\n' "$CI_OK" "$WAIT" > "$d/required.json"
  assert_equals "" "$(state "$d")" \
    "a repository requiring every check does not wait on the gate's own status"
  printf '[%s,%s]\n' "$LINT_RED" "$WAIT" > "$d/required.json"
  out=$(state "$d")
  assert_equals "REQUIRED CHECK: Lint (FAILURE)" "$out" \
    "a real required check still blocks beside the wait status"
  pass "the waiting-for status is ignored when it is itself a required check"
}

test_no_required_check_passes_when_every_reported_check_is_green
test_no_required_check_still_reports_a_red_check
test_unmet_required_check_stays_unconfirmed
test_nothing_reported_at_all_is_not_read_as_ready
test_required_waiting_for_status_is_never_pending

echo "all jg-pr-state tests passed"
