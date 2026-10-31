#!/usr/bin/env bash
# Fast eval for bin/jg-fleet-autosync.sh.
#
# T1 A copy three merges behind becomes current when the merge event's pass runs,
#    and the digest line flips from "3 behind" to "current".
# T2 A copy holding a tracked change refuses and stays behind with its file intact;
#    the drift alarm fires past two merges behind, never at two, and never twice for
#    one distance.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTOSYNC="$ROOT/bin/jg-fleet-autosync.sh"

jg_git_identity fmtest fmtest@example.com

TMP_ROOT=$(jg_test_tmproot jg-fleet-autosync-tests)

# A world is a bare origin, one clone of it standing in for the copy the fleet runs,
# and a home holding only that copy's state and data directories.
new_world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/home/state" "$w/home/data"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"
  mkdir -p "$w/seed/bin"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/copy"
  git -C "$w/copy" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$w"
}

# One more merged pull request on the default branch. The copy has fetched, so the
# merge is visible in its origin refs while its own HEAD stays behind.
merge_once() {
  local w=$1
  printf 'm-%s\n' "$RANDOM$RANDOM" >> "$w/seed/README.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm merge
  git -C "$w/seed" push -q origin main
  git -C "$w/copy" fetch -q origin
}

digest() { JG_ROOT_OVERRIDE="$1/copy" JG_HOME="$1/home" "$AUTOSYNC" digest 2>&1; }
pass_run() { JG_ROOT_OVERRIDE="$1/copy" JG_HOME="$1/home" "$AUTOSYNC" run 2>&1; }
run_check() { JG_ROOT_OVERRIDE="$1/copy" JG_HOME="$1/home" JG_AUTOSYNC_ALARM_SECS="$2" "$AUTOSYNC" check 2>&1; }

test_behind_becomes_current() {
  local w out
  w=$(new_world t1)
  merge_once "$w"
  merge_once "$w"
  merge_once "$w"

  assert_equals "primary: 3 behind" "$(digest "$w")" "a copy three merges behind reports its distance"
  out=$(pass_run "$w")
  assert_contains "$out" "juggernaut: updated " "the pass fast-forwards the copy"
  assert_equals "primary: current" "$(digest "$w")" "the digest line flips to current"
  assert_equals "$(git -C "$w/copy" rev-parse HEAD)" "$(git -C "$w/copy" rev-parse origin/main)" \
    "the copy's HEAD is the merged tip"
  pass "T1 a behind copy becomes current and the digest line flips"
}

test_tracked_change_and_alarm() {
  local w out
  w=$(new_world t2)
  # The tracked change also keeps every check-started pass from moving this copy, so
  # the distance assertions below never race a background fast-forward.
  printf 'unlanded\n' >> "$w/copy/bin/tool.sh"
  merge_once "$w"
  merge_once "$w"

  out=$(pass_run "$w")
  assert_contains "$out" "juggernaut: skipped: dirty working tree" "a copy holding a tracked change refuses"
  assert_equals "primary: 2 behind" "$(digest "$w")" "the refused copy stays behind"
  assert_contains "$(cat "$w/copy/bin/tool.sh")" "unlanded" "the unlanded change is untouched"

  out=$(run_check "$w" 0)
  assert_not_contains "$out" "merges behind" "two behind does not raise the alarm"
  merge_once "$w"
  out=$(run_check "$w" 0)
  assert_contains "$out" "primary is 3 merges behind the merged default branch" \
    "the alarm fires past two behind"
  out=$(run_check "$w" 0)
  assert_not_contains "$out" "merges behind" "the reported distance does not repeat"
  pass "T2 a tracked change refuses and the alarm fires past two behind"
}

test_behind_becomes_current
test_tracked_change_and_alarm
