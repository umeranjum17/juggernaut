#!/usr/bin/env bash
# A ship `done:` is accepted only while its pull request reports no red or
# unfinished check (bin/jg-dod-lib.sh's jg_dod_pr_checks_clear, reading
# bin/jg-pr-state.sh --all). A red or running check refuses the done by name and
# names the light gate to run locally, the same lane is accepted once every check
# is green, and a pull request that has reported nothing yet keeps today's
# behavior because absence proves nothing (the merge gate still owns the merge).
# The lane status cases run bin/jg-crew-state.sh, the executable a supervisor
# reads, so a refusal is proven where it lands.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-done-checks)
jg_git_identity fmtest fmtest@example.invalid
CREW_STATE="$ROOT/bin/jg-crew-state.sh"
PR=https://github.com/o/r/pull/7

# A lane: a real git worktree whose HEAD is already on origin/main (so the
# named-head gate is satisfied and only the check read is under test), a meta
# record, and a status log.
make_lane() {  # <name> [<extra meta lines...>] -> echoes the case dir
  local name=$1 d
  shift
  d="$TMP_ROOT/$name"
  mkdir -p "$d/state" "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" update-ref refs/remotes/origin/main "$(git -C "$d/wt" rev-parse HEAD)"
  # This project's own light-gate entry points, so a refusal names the commands a
  # worker in a Juggernaut copy would really run.
  mkdir -p "$d/wt/bin"
  cp "$ROOT/bin/jg-lint.sh" "$ROOT/bin/jg-test-run.sh" "$d/wt/bin/"
  jg_write_meta "$d/state/t.meta" "window=fm:jg-t" "worktree=$d/wt" "kind=ship" "mode=direct-PR" "project=some-proj" "harness=claude" "$@"
  printf 'done: PR %s\n' "$PR" > "$d/state/t.status"
  # A semantic idle record: the busy contract is authoritative over the pane, so
  # the lane reads idle from its own lifecycle record rather than a rendered tail.
  local gen
  gen=$("$ROOT/bin/jg-busy-event.sh" arm "$d/state" t)
  "$ROOT/bin/jg-busy-event.sh" apply "$d/state" t idle --gen "$gen" \
    --source claude-hook --event stop
  printf '%s\n' "$d"
}

# A `gh` serving the two reads the done gate makes: the pull-request record
# bin/jg-pr-state.sh parses, and its checks list. JG_FAKE_PR_CHECKS is the JSON
# array gh reports; empty means gh's own "no checks reported" error, which is the
# sentence bin/jg-pr-state.sh matches to tell absence from a failed lookup.
make_fakebin() {  # <case-dir> -> echoes fakebin
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${JG_FAKE_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$JG_FAKE_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    for arg in "$@"; do
      [ "$arg" = headRefOid ] && { printf '%s\n' "${JG_FAKE_PR_HEAD:-}"; exit 0; }
    done
    printf 'state=open\nmerged_at=\ndraft=false\nhead=%s\nauthor=someone\nmergeability=mergeable\nreview_decision=\n' \
      "${JG_FAKE_PR_HEAD:-}"
    exit 0 ;;
  "pr checks")
    prog='' prev=''
    for arg in "$@"; do
      [ "$prev" = --jq ] && prog=$arg
      prev=$arg
    done
    if [ -z "${JG_FAKE_PR_CHECKS:-}" ]; then
      printf "no checks reported on the 'x' branch\n" >&2
      exit 1
    fi
    printf '%s' "$JG_FAKE_PR_CHECKS" | jq -r "$prog"
    exit 0 ;;
esac
exit 1
SH
  # The run lookup and pane probes that precede the status-log path in
  # jg-crew-state.sh report nothing, so the done line is what it judges.
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fb/gh" "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

lane_status() {  # <case-dir> -> the one current-state line
  PATH="$1/fakebin:$PATH" JG_STATE_OVERRIDE="$1/state" \
    JG_FAKE_PR_HEAD="$(git -C "$1/wt" rev-parse HEAD)" \
    "$CREW_STATE" t
}

test_red_check_refuses_the_done_by_name() {
  local d out
  d=$(make_lane red)
  make_fakebin "$d" >/dev/null
  JG_FAKE_PR_CHECKS='[{"name":"CI required","state":"SUCCESS","bucket":"pass"},{"name":"Lint","state":"FAILURE","bucket":"fail"}]'
  export JG_FAKE_PR_CHECKS
  out=$(lane_status "$d")
  assert_contains "$out" "state: blocked" "a red check must refuse the done"
  assert_contains "$out" "Lint (FAILURE)" "the refusal must name the exact check"
  assert_not_contains "$out" "CI required" "a passing check is not named"
  assert_contains "$out" "bin/jg-lint.sh --changed && bin/jg-test-run.sh --changed" \
    "the refusal must name the light gate to run locally"
  pass "a done with a red check is refused, naming the check and the light gate"
}

test_running_check_refuses_and_green_accepts_the_same_lane() {
  local d out
  d=$(make_lane running)
  make_fakebin "$d" >/dev/null
  JG_FAKE_PR_CHECKS='[{"name":"Lint 1","state":"IN_PROGRESS","bucket":"pending"},{"name":"Lint 2","state":"QUEUED","bucket":"pending"}]'
  export JG_FAKE_PR_CHECKS
  out=$(lane_status "$d")
  assert_contains "$out" "state: blocked" "an unfinished check must refuse the done"
  assert_contains "$out" "Lint 1 (IN_PROGRESS), Lint 2 (QUEUED)" \
    "the refusal must name every unfinished check"
  JG_FAKE_PR_CHECKS='[{"name":"Lint 1","state":"SUCCESS","bucket":"pass"},{"name":"Lint 2","state":"SUCCESS","bucket":"pass"}]'
  export JG_FAKE_PR_CHECKS
  out=$(lane_status "$d")
  assert_contains "$out" "state: done" "the same lane is accepted once every check is green"
  assert_not_contains "$out" "blocked" "a green lane is not refused"
  pass "a done waits on a running check and is accepted once every check is green"
}

test_skipped_and_cancelled_checks_do_not_refuse() {
  local d out
  d=$(make_lane skipped)
  make_fakebin "$d" >/dev/null
  JG_FAKE_PR_CHECKS='[{"name":"Shell syntax","state":"SUCCESS","bucket":"pass"},{"name":"Core suites","state":"SKIPPED","bucket":"skipping"},{"name":"Lint","state":"CANCELLED","bucket":"cancel"}]'
  export JG_FAKE_PR_CHECKS
  out=$(lane_status "$d")
  assert_contains "$out" "state: done" \
    "a skipped check and a superseded cancelled run must not refuse the done"
  pass "a skipping or cancelled check does not refuse a done"
}

test_no_reported_check_keeps_the_previous_acceptance() {
  local d out
  d=$(make_lane noreport)
  make_fakebin "$d" >/dev/null
  JG_FAKE_PR_CHECKS=''
  export JG_FAKE_PR_CHECKS
  out=$(lane_status "$d")
  assert_contains "$out" "state: done" \
    "a pull request that has reported no check yet is not refused here"
  pass "a pull request with no reported check keeps the previous acceptance"
}

test_local_only_done_makes_no_forge_read() {
  local d out
  d=$(make_lane local)
  make_fakebin "$d" >/dev/null
  jg_write_meta "$d/state/t.meta" "window=fm:jg-t" "worktree=$d/wt" "kind=ship" "mode=local-only" \
    "project=some-proj" "harness=claude"
  printf 'done: ready in branch fm/t\n' > "$d/state/t.status"
  : > "$d/gh.log"
  JG_FAKE_GH_LOG="$d/gh.log"
  export JG_FAKE_GH_LOG
  out=$(lane_status "$d")
  assert_contains "$out" "state: done" "a local-only done has no pull request to read"
  [ ! -s "$d/gh.log" ] || fail "a local-only done read the forge: $(cat "$d/gh.log")"
  pass "a local-only done never reads a forge check"
}

test_red_check_refuses_the_done_by_name
test_running_check_refuses_and_green_accepts_the_same_lane
test_skipped_and_cancelled_checks_do_not_refuse
test_no_reported_check_keeps_the_previous_acceptance
test_local_only_done_makes_no_forge_read

echo "all jg-done-checks tests passed"
