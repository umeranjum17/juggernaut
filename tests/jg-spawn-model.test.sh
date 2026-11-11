#!/usr/bin/env bash
# No lane runs on a model nobody chose: bin/jg-spawn.sh refuses a spawn whose model is empty or `default`
# (owner rule 2026-11-08 "No worker lane on Luna"), whichever harness it names, and records the resolved
# model in the task record. Real bin/jg-brief.sh and bin/jg-spawn.sh over a fixture project; only the
# terminal and the worktree tool are stand-ins. bin/jg-model-allowlist.sh watch is proved here too: a
# model ban is lifted for one job by a recorded lift, and for no other job.
#
# tests/lib.sh arms JG_SPAWN_TEST_MODEL_OPTIONAL so the older suites, which never choose a model, keep
# running; this suite unsets it, because refusing the unchosen model is what it proves.
#
# T1 a spawn with no --model and no declared default exits 1, names the owner rule, and leaves no record.
# T2 --model default is refused the same way.   T3 a chosen model is recorded and `model=default` never is.
# T4 a home-declared worker default (config/tool-models.json) is recorded as the resolved model.
# T5 a scout is refused the same way.   T6 a relaunch of a record that holds `model=default` is refused,
#    and a relaunch of a record with a chosen model keeps it.
# T7 the model-ban watch alarms for an off-list model, stays silent under a lift naming that job and
#    model, and still alarms for another job on the same model.
# T8 a raw launch command (no adapter) spawns without a model, since it has none to choose.
# T9 a Claude lane on an account config/claude-1m-accounts lists launches and records the model's [1m]
#    id, and a relaunch of that record keeps it, never doubled.
# T10 an id that already ends in [1m] is not doubled.
# T11 a Claude lane on an account the file does not list, and a codex lane, keep the model as chosen.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset JG_SPAWN_TEST_MODEL_OPTIONAL

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-spawn-model-tests)

W="$TMP_ROOT/world"
HOME_DIR="$W/home"
PROJ="$W/proj"
mkdir -p "$W"
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
# The stand-in terminal reports an idle shell, so a relaunch sees an endpoint with no agent in it.
sed -i '/^set -u$/a case "$*" in *pane_current_command*) echo bash; exit 0 ;; esac' "$FAKEBIN/tmux"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$HOME_DIR/config/host-memory"

N=0
fresh() { N=$((N + 1)); id=jg-model$N; }

scaffold() { # <id> [--scout]
  local id=$1 kind=(--mode direct-PR --project "$PROJ")
  [ "${2:-}" != --scout ] || kind=(--scout)
  JG_HOME="$HOME_DIR" "$ROOT/bin/jg-brief.sh" "$id" proj "${kind[@]}" >"$W/brief.out" 2>&1 || { cat "$W/brief.out" >&2; return 1; }
  sed -i 's/{TASK}/Exercise the model rule./;s/{JUGGERNAUT_SPEC}/Exercise the model rule end to end./' "$HOME_DIR/data/$id/brief.md"
}
isolated_copy() { # <id>
  git -C "$PROJ" worktree add -q --detach "$W/wt-$1" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
}
spawn() { # <id> <spawn-args...>: a real ship spawn onto its own isolated copy
  local id=$1
  shift
  isolated_copy "$id"
  jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" "$PROJ" codex --mode direct-PR --yolo off "$@" 2>&1
}
meta() { cat "$HOME_DIR/state/$1.meta" 2>/dev/null; }
refused_clean() { [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "the refused spawn $1 wrote a task record"; }

# T1
fresh
scaffold "$id" || fail "T1 could not scaffold"
out=$(spawn "$id"); rc=$?
expect_code 1 "$rc" "T1 a spawn with no model should be refused: $out"
assert_contains "$out" "No worker lane on Luna" "T1 the refusal does not name the owner rule"
assert_contains "$out" "--model" "T1 the refusal does not say how to choose a model"
refused_clean "$id"
pass "T1 a spawn with no chosen model exits 1 naming the owner rule and leaves no record"

# T2
fresh
scaffold "$id" || fail "T2 could not scaffold"
out=$(spawn "$id" --model default); rc=$?
expect_code 1 "$rc" "T2 --model default should be refused: $out"
assert_contains "$out" "No worker lane on Luna" "T2 the refusal does not name the owner rule"
refused_clean "$id"
pass "T2 --model default is refused"

# T3
fresh
scaffold "$id" || fail "T3 could not scaffold"
out=$(spawn "$id" --model gpt-5.6-sol); rc=$?
expect_code 0 "$rc" "T3 a spawn with a chosen model should succeed: $out"
assert_grep 'model=gpt-5.6-sol' "$HOME_DIR/state/$id.meta" "T3 the task record lacks the chosen model"
! grep -q '^model=default' "$HOME_DIR/state/$id.meta" || fail "T3 the task record holds model=default"
CHOSEN_ID=$id
pass "T3 a chosen model is recorded and model=default is never written"

# T4
fresh
scaffold "$id" || fail "T4 could not scaffold"
printf '%s\n' '{"rules":[{"tool":"worker-default","when":"every worker","use":{"harness":"codex","model":"gpt-5.6-sol"}}]}' \
  > "$HOME_DIR/config/tool-models.json"
out=$(spawn "$id"); rc=$?
expect_code 0 "$rc" "T4 a harness with a declared default should spawn: $out"
assert_grep 'model=gpt-5.6-sol' "$HOME_DIR/state/$id.meta" "T4 the task record lacks the declared default as the resolved model"
rm -f "$HOME_DIR/config/tool-models.json"
pass "T4 a home-declared worker default is recorded as the resolved model"

# T5
fresh
scaffold "$id" --scout || fail "T5 could not scaffold the scout brief"
isolated_copy "$id"
out=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" "$PROJ" codex --scout 2>&1); rc=$?
expect_code 1 "$rc" "T5 a scout with no model should be refused: $out"
assert_contains "$out" "No worker lane on Luna" "T5 the refusal does not name the owner rule"
refused_clean "$id"
pass "T5 a scout with no chosen model is refused"

# T6
legacy="$HOME_DIR/state/$CHOSEN_ID.meta"
cp -f "$legacy" "$W/chosen.meta"
sed -i 's/^model=.*/model=default/' "$legacy"
out=$(JG_FAKE_DUPLICATE_WINDOW="jg-$CHOSEN_ID" jg_test_run_spawn "$HOME_DIR" "$W/wt-$CHOSEN_ID" "$FAKEBIN" "$CHOSEN_ID" --relaunch 2>&1); rc=$?
expect_code 1 "$rc" "T6 a relaunch of a record holding model=default should be refused: $out"
assert_contains "$out" "No worker lane on Luna" "T6 the refusal does not name the owner rule"
cp -f "$W/chosen.meta" "$legacy"
out=$(JG_FAKE_DUPLICATE_WINDOW="jg-$CHOSEN_ID" jg_test_run_spawn "$HOME_DIR" "$W/wt-$CHOSEN_ID" "$FAKEBIN" "$CHOSEN_ID" --relaunch 2>&1); rc=$?
expect_code 0 "$rc" "T6 a relaunch of a record with a chosen model should succeed: $out"
assert_grep 'model=gpt-5.6-sol' "$legacy" "T6 the relaunch lost the chosen model"
pass "T6 a relaunch never runs on model=default and keeps a chosen model"

# T7: the model-ban watch honours a recorded one-job lift
WSTATE="$HOME_DIR/state"
printf '%s\n' '{"claude":["claude-sonnet-5-5"]}' > "$HOME_DIR/config/model-allow-list.json"
printf '1\tclaude\tclaude-fable-5-1\thigh\n' > "$WSTATE/plan-worker.models"
watch() { rm -f "$WSTATE/.model-allowlist.seen"; JG_HOME="$HOME_DIR" "$ROOT/bin/jg-model-allowlist.sh" watch 2>&1; }
out=$(watch)
assert_contains "$out" "claude-fable-5-1" "T7 an off-list model raised no alarm without a lift"
printf '%s\n' 'plan-worker claude/claude-fable-5-1 autopilot plan, juggernaut worktree' > "$HOME_DIR/config/model-ban-lifts"
out=$(watch)
[ -z "$out" ] || fail "T7 a recorded lift for the job and model still alarmed: $out"
printf '1\tclaude\tclaude-fable-5-1\thigh\n' > "$WSTATE/other-worker.models"
out=$(watch)
assert_contains "$out" "claude-fable-5-1" "T7 a lift for one job silenced another job"
printf '%s\n' 'plan-worker claude/claude-fable-5-1' > "$HOME_DIR/config/model-ban-lifts"
rm -f "$WSTATE/other-worker.models"
out=$(watch)
assert_contains "$out" "claude-fable-5-1" "T7 a lift record with no scope silenced the alarm"
pass "T7 the model-ban watch is lifted for one named job and model, and for nothing else"

# T8: a raw launch command names no adapter, so there is no model to choose
fresh
scaffold "$id" || fail "T8 could not scaffold"
isolated_copy "$id"
out=$(jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" "$PROJ" "sh -c 'echo raw-ok'" --mode direct-PR --yolo off 2>&1); rc=$?
expect_code 0 "$rc" "T8 a raw launch command should spawn without a model: $out"
pass "T8 a raw launch command is not refused for lacking a model"

# T9-T11: the Claude 1M context window follows the account the lane launches on. The stand-in claude
# answers `claude auth status`, so the ordinary-account pin passes its sign-in check.
spawn_claude() { # <id> <spawn-args...>: a real Claude ship spawn onto its own isolated copy
  local id=$1
  shift
  isolated_copy "$id"
  JG_FAKE_LAUNCH_LOG="$W/launch-$id.log" jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" "$PROJ" claude \
    --mode direct-PR --yolo off "$@" 2>&1
}
model_of() { sed -n 's/^model=//p' "$HOME_DIR/state/$1.meta" | tail -1; }
rm -f "$HOME_DIR/config/model-allow-list.json" "$HOME_DIR/config/model-ban-lifts"
printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
printf '# accounts that serve the 1M window\n\nordinary\n' > "$HOME_DIR/config/claude-1m-accounts"

# T9
fresh
scaffold "$id" || fail "T9 could not scaffold"
out=$(spawn_claude "$id" --model claude-opus-5-5); rc=$?
expect_code 0 "$rc" "T9 a Claude spawn on a listed account should succeed: $out"
[ "$(model_of "$id")" = 'claude-opus-5-5[1m]' ] || fail "T9 the task record holds model=$(model_of "$id"), not claude-opus-5-5[1m]"
assert_grep 'account=ordinary' "$HOME_DIR/state/$id.meta" "T9 the task record lacks the pinned account"
assert_contains "$(cat "$W/launch-$id.log")" "--model 'claude-opus-5-5[1m]'" "T9 the launch line does not run the [1m] id"
assert_contains "$out" "1M context window" "T9 the spawn printed no notice for the [1m] id"
out=$(JG_FAKE_DUPLICATE_WINDOW="jg-$id" jg_test_run_spawn "$HOME_DIR" "$W/wt-$id" "$FAKEBIN" "$id" --relaunch 2>&1); rc=$?
expect_code 0 "$rc" "T9 a relaunch of the [1m] record should succeed: $out"
[ "$(model_of "$id")" = 'claude-opus-5-5[1m]' ] || fail "T9 the relaunch recorded model=$(model_of "$id"), not claude-opus-5-5[1m]"
pass "T9 a Claude lane on a listed account runs and records the [1m] id, and a relaunch keeps it"

# T10
fresh
scaffold "$id" || fail "T10 could not scaffold"
out=$(spawn_claude "$id" --model 'claude-fable-5-2[1m]'); rc=$?
expect_code 0 "$rc" "T10 a Claude spawn with a [1m] id should succeed: $out"
[ "$(model_of "$id")" = 'claude-fable-5-2[1m]' ] || fail "T10 the task record holds model=$(model_of "$id"), not claude-fable-5-2[1m]"
pass "T10 an id that already ends in [1m] is not doubled"

# T11
printf '/nonexistent/other-claude-root\n' > "$HOME_DIR/config/claude-1m-accounts"
fresh
scaffold "$id" || fail "T11 could not scaffold"
out=$(spawn_claude "$id" --model claude-sonnet-5-5); rc=$?
expect_code 0 "$rc" "T11 a Claude spawn on an unlisted account should succeed: $out"
[ "$(model_of "$id")" = claude-sonnet-5-5 ] || fail "T11 an unlisted account recorded model=$(model_of "$id")"
printf 'ordinary\n' > "$HOME_DIR/config/claude-1m-accounts"
fresh
scaffold "$id" || fail "T11 could not scaffold the codex lane"
out=$(spawn "$id" --model gpt-5.6-sol); rc=$?
expect_code 0 "$rc" "T11 a codex spawn should succeed: $out"
[ "$(model_of "$id")" = gpt-5.6-sol ] || fail "T11 a codex lane recorded model=$(model_of "$id")"
rm -f "$HOME_DIR/config/claude-account" "$HOME_DIR/config/claude-1m-accounts"
pass "T11 an unlisted account and a codex lane keep the model as chosen"

echo "all jg-spawn-model tests passed"
