#!/usr/bin/env bash
# One hook dispatcher, one beat: a spawned Claude agent writes state/beats/<task-id> from its own hooks.
# Real bin/jg-brief.sh and bin/jg-spawn.sh write the agent's hook wiring; the test then runs each wired hook
# command exactly as Claude Code would (payload on stdin), through the real bin/jg-hook.sh, core/hooks/ and
# bin/jg-beat.sh. Only the terminal and the worktree tool are stand-ins.
#
# T1 the spawn wires the dispatcher for UserPromptSubmit, PostToolBatch, Stop, StopFailure and SessionEnd,
#    and the busy-state hooks stay beside it.
# T2 each wired event appends one line to the beat record, in order.
# T3 a StopFailure payload with an API error writes its type; a payload with none writes `unknown`.
# T4 a hook that fails (no state dir) still exits 0 and the record is untouched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset JG_SPAWN_TEST_MODEL_OPTIONAL

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-hook-beat)
W="$TMP_ROOT/world"; H="$W/home"; PROJ="$W/proj"
mkdir -p "$W"
git init -q --bare "$W/origin.git"
git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$W/origin.git" "$PROJ" 2>/dev/null
printf 'v1\n' > "$PROJ/AGENTS.md"
git -C "$PROJ" add -A; git -C "$PROJ" commit -qm c1
git -C "$PROJ" push -q origin HEAD:refs/heads/main; git -C "$PROJ" fetch -q
git -C "$PROJ" remote set-head origin main >/dev/null 2>&1 || true

jg_test_spawn_home "$H"
FAKEBIN=$(make_spawn_fakebin "$W/fake" claude)
jg_test_fake_sleep_noop "$FAKEBIN"
sed -i '/^set -u$/a case "$*" in *pane_current_command*) echo bash; exit 0 ;; esac' "$FAKEBIN/tmux"
printf 'wait_pressure=100\nalert_pressure=100\nwait_available_gb=0\nalert_available_gb=0\n' > "$H/config/host-memory"

id=jg-beat1
JG_HOME="$H" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" >"$W/brief.out" 2>&1 || { cat "$W/brief.out" >&2; fail "could not scaffold"; }
sed -i 's/{TASK}/Exercise the beat./;s/{JUGGERNAUT_SPEC}/Exercise the beat end to end./' "$H/data/$id/brief.md"
WT="$W/wt-$id"
git -C "$PROJ" worktree add -q --detach "$WT" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
out=$(jg_test_run_spawn "$H" "$WT" "$FAKEBIN" "$id" "$PROJ" claude --mode direct-PR --yolo off --model claude-haiku-5-5 2>&1); rc=$?
expect_code 0 "$rc" "the Claude spawn should succeed: $out"

S="$WT/.claude/settings.local.json"
# beat_cmd <event>: the wired dispatcher command for that event
beat_cmd() { jq -r --arg e "$1" '.hooks[$e][].hooks[].command | select(contains("jg-hook.sh"))' "$S"; }
run_hook() { # <event> <payload>: run the wired command as Claude Code does
  printf '%s' "$2" | bash -c "$(beat_cmd "$1")"
}

# T1
for e in UserPromptSubmit PostToolBatch Stop StopFailure SessionEnd; do
  [ "$(beat_cmd $e | wc -l)" -eq 1 ] || fail "T1 $e has no single dispatcher hook in $S"
done
grep -q 'jg-busy-event.sh' "$S" || fail "T1 the busy-state hooks are gone"
pass "T1 the spawn wires the dispatcher for the five events beside the busy-state hooks"

# T2
REC="$H/state/beats/$id"
for e in UserPromptSubmit PostToolBatch PostToolBatch Stop; do run_hook "$e" '{}'; done
[ "$(awk '{print $2}' "$REC" | paste -sd' ')" = "UserPromptSubmit PostToolBatch PostToolBatch Stop" ] \
  || fail "T2 the beat record holds: $(cat "$REC" 2>&1)"
awk '$1 !~ /^[0-9]+$/ {bad=1} END {exit bad}' "$REC" || fail "T2 a beat line has no epoch"
pass "T2 each wired event appends one timed line to the beat record"

# T3
run_hook StopFailure '{"hook_event_name":"StopFailure","error":"billing_error"}'
run_hook StopFailure '{}'
run_hook SessionEnd '{}'
tail -n 3 "$REC" | sed 's/^[0-9]* //' | paste -sd'|' | grep -qx 'StopFailure error=billing_error|StopFailure error=unknown|SessionEnd' \
  || fail "T3 the error lines are: $(tail -n 3 "$REC")"
pass "T3 an API error writes its type, and a missing one writes unknown"

# T4
before=$(wc -l <"$REC")
rc=0; printf '{}' | bash -c "$(beat_cmd Stop | sed "s#$H/state#$H/no-such-state#")" || rc=$?
expect_code 0 "$rc" "T4 a failing hook broke the agent"
[ "$(wc -l <"$REC")" -eq "$before" ] || fail "T4 a failing hook still wrote the record"
pass "T4 a failing hook exits 0 and leaves the record alone"

echo "all jg-hook-beat tests passed"
