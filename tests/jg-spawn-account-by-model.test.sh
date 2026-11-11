#!/usr/bin/env bash
# config/claude-account-by-model (bin/jg-worker-account-lib.sh): a Claude launch whose model has an entry in
# the map runs on that entry's account, every other model keeps the home's pin, and a home with no map
# launches exactly as before. Real bin/jg-brief.sh and bin/jg-spawn.sh over a fixture project; only the
# terminal, the worktree tool and `claude auth status` are stand-ins.
#
# T1 Sonnet maps to the Cognify folder: the launch line and the task record carry it, and a relaunch keeps it.
# T2 Opus is not in the map and keeps the pin folder.
# T3 no map file keeps today's behaviour: Sonnet runs on the pin.
# T4 a malformed map refuses the spawn before any task record exists.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset JG_SPAWN_TEST_MODEL_OPTIONAL

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-account-by-model)

W="$TMP_ROOT/world"
HOME_DIR="$W/home"
PROJ="$W/proj"
PIN_ROOT="$W/accounts/13bscs"
COGNIFY_ROOT="$W/accounts/cognify"
mkdir -p "$W" "$PIN_ROOT" "$COGNIFY_ROOT"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"
git -C "$PROJ" add -A
git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main
git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true

jg_test_spawn_home "$HOME_DIR"
FAKEBIN=$(make_spawn_fakebin "$W/fake" claude)
jg_test_fake_sleep_noop "$FAKEBIN"
sed -i '/^set -u$/a case "$*" in *pane_current_command*) echo bash; exit 0 ;; esac' "$FAKEBIN/tmux"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"
printf '%s\n' "$PIN_ROOT" > "$HOME_DIR/config/claude-account"
MAP="$HOME_DIR/config/claude-account-by-model"

N=0
fresh() { N=$((N + 1)); id=jg-acctmap$N; }
scaffold() {
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$1" proj --mode direct-PR --project "$PROJ" >"$W/brief.out" 2>&1 || { cat "$W/brief.out" >&2; return 1; }
  sed -i 's/{TASK}/Exercise the account map./;s/{JUGGERNAUT_SPEC}/Exercise the account map end to end./' "$HOME_DIR/data/$1/brief.md"
}
spawn_claude() { # <id> <spawn-args...>: a real Claude ship spawn onto its own isolated copy
  local id=$1
  shift
  git -C "$PROJ" worktree add -q --detach "$W/wt-$id" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
  JG_FAKE_LAUNCH_LOG="$W/launch-$id.log" jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" "$PROJ" claude \
    --mode direct-PR --yolo off "$@" 2>&1
}

printf '# Sonnet on Cognify, every other model on the pin\nclaude-sonnet-5-5 %s\n' "$COGNIFY_ROOT" > "$MAP"

# T1
fresh
scaffold "$id" || fail "T1 could not scaffold"
out=$(spawn_claude "$id" --model claude-sonnet-5-5); rc=$?
expect_code 0 "$rc" "T1 a Sonnet spawn should succeed: $out"
assert_grep "account=$COGNIFY_ROOT" "$HOME_DIR/state/$id.meta" "T1 the task record lacks the Cognify account"
assert_contains "$(cat "$W/launch-$id.log")" "CLAUDE_CONFIG_DIR='$COGNIFY_ROOT'" "T1 the launch does not select the Cognify folder"
out=$(JG_FAKE_LAUNCH_LOG="$W/relaunch-$id.log" JG_FAKE_DUPLICATE_WINDOW="jg-$id" jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" --relaunch 2>&1); rc=$?
expect_code 0 "$rc" "T1 a relaunch should succeed: $out"
assert_grep "account=$COGNIFY_ROOT" "$HOME_DIR/state/$id.meta" "T1 the relaunch lost the Cognify account"
assert_contains "$(cat "$W/relaunch-$id.log")" "CLAUDE_CONFIG_DIR='$COGNIFY_ROOT'" "T1 the relaunch does not select the Cognify folder"
pass "T1 Sonnet launches, records and relaunches on the Cognify folder"

# T2
fresh
scaffold "$id" || fail "T2 could not scaffold"
out=$(spawn_claude "$id" --model claude-opus-5-5); rc=$?
expect_code 0 "$rc" "T2 an Opus spawn should succeed: $out"
assert_grep "account=$PIN_ROOT" "$HOME_DIR/state/$id.meta" "T2 the task record lacks the pinned account"
assert_contains "$(cat "$W/launch-$id.log")" "CLAUDE_CONFIG_DIR='$PIN_ROOT'" "T2 the launch does not select the pin folder"
pass "T2 Opus keeps the pin folder"

# T3
rm -f "$MAP"
fresh
scaffold "$id" || fail "T3 could not scaffold"
out=$(spawn_claude "$id" --model claude-sonnet-5-5); rc=$?
expect_code 0 "$rc" "T3 a Sonnet spawn with no map should succeed: $out"
assert_grep "account=$PIN_ROOT" "$HOME_DIR/state/$id.meta" "T3 a missing map changed the account"
pass "T3 a missing map keeps today's behaviour"

# T4
printf 'claude-sonnet-5-5 relative/path\n' > "$MAP"
fresh
scaffold "$id" || fail "T4 could not scaffold"
out=$(spawn_claude "$id" --model claude-sonnet-5-5); rc=$?
expect_code 1 "$rc" "T4 a malformed map should refuse the spawn: $out"
assert_contains "$out" "claude-account-by-model" "T4 the refusal does not name the map file"
[ ! -e "$HOME_DIR/state/$id.meta" ] || fail "T4 the refused spawn wrote a task record"
pass "T4 a malformed map refuses the spawn and leaves no record"

echo "all jg-spawn-account-by-model tests passed"
