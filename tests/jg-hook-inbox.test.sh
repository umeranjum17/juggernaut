#!/usr/bin/env bash
# An agent pulls its steering inbox at each turn end and tool batch; the read is an event.
# A real bin/jg-spawn.sh of a Claude lane wires the hooks; a real bin/jg-send.sh stores the steers; the test runs each wired
# hook command exactly as Claude Code would (payload on stdin), through bin/jg-hook.sh and core/hooks/inbox.sh. Only the
# terminal and the worktree tool are stand-ins.
#
# T1 a steer sent while the agent works comes back in the PostToolBatch answer as additional context, moved to handled/,
#    with the `read` word on its delivery record, and the message machine reads it as `read`.
# T2 a steer waiting at turn end comes back as a Stop block carrying its text; steers arrive in numeric order.
# T3 an empty inbox prints nothing, so the turn ends as before; a second pull finds nothing.
# T4 the agent's claim after the pull ends the ladder: jg-delivery handled records it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset JG_SPAWN_TEST_MODEL_OPTIONAL

jg_git_identity fmtest fmtest@example.com
TMP_ROOT=$(jg_test_tmproot jg-hook-inbox)
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

id=jg-inb1
JG_HOME="$H" "$ROOT/bin/jg-brief.sh" "$id" proj --mode direct-PR --project "$PROJ" >"$W/brief.out" 2>&1 || { cat "$W/brief.out" >&2; fail "could not scaffold"; }
sed -i 's/{TASK}/Exercise the inbox pull./;s/{JUGGERNAUT_SPEC}/Exercise the inbox pull end to end./' "$H/data/$id/brief.md"
WT="$W/wt-$id"
git -C "$PROJ" worktree add -q --detach "$WT" origin/main >/dev/null 2>&1 || fail "could not prepare the isolated copy"
out=$(jg_test_run_spawn "$H" "$WT" "$FAKEBIN" "$id" "$PROJ" claude --mode direct-PR --yolo off --model claude-haiku-5-5 2>&1); rc=$?
expect_code 0 "$rc" "the Claude spawn should succeed: $out"

S="$WT/.claude/settings.local.json"
hook_cmd() { jq -r --arg e "$1" '.hooks[$e][].hooks[].command | select(contains("jg-hook.sh"))' "$S"; }
run_hook() { printf '%s' "$2" | bash -c "$(hook_cmd "$1")"; }   # <event> <payload>
INBOX="$H/state/$id.inbox"
# A steer that is stored but fails to ring still counts, so the send's exit is not the verdict: the store is, and a steer that
# is not stored fails here with the send's own output instead of as a missing steer further down.
steer() {
  local before after sendout
  before=$(msgs)
  sendout=$(JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" "$ROOT/bin/jg-send.sh" "$id" "$1" 2>&1) || true
  after=$(msgs)
  [ "$after" -gt "$before" ] || fail "the steer '$1' was not stored: $sendout"
}
msgs() { find "$INBOX" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' '; }
mstate() { JG_HOME="$ROOT" JG_STATE_OVERRIDE="$H/state" bash "$ROOT/bin/jg-machine.sh" show message "$id:$1" | awk -F'\t' '$1=="state"{print $2}'; }

# T1
steer "first steer: rename the flag"
[ "$(msgs)" -ge 1 ] || fail "T1 the steer was not stored in $INBOX"
seq1=$(find "$INBOX" -maxdepth 1 -name '*.msg' | sed 's#.*/##;s#\.msg##' | sort | head -n 1)
out=$(run_hook PostToolBatch '{}')
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" = PostToolBatch ] || fail "T1 no PostToolBatch answer: $out"
printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'rename the flag' || fail "T1 the context lacks the steer: $out"
[ "$(msgs)" -eq 0 ] || fail "T1 the steer is still in the inbox"
[ -f "$INBOX/handled/$seq1.msg" ] || fail "T1 the steer is not in handled/"
jq -e --argjson s "$((10#$seq1))" 'select(.seq == $s and .word == "read" and .pointer == "hook:PostToolBatch")' "$INBOX/.delivery.jsonl" >/dev/null \
  || fail "T1 no read word with the hook event: $(cat "$INBOX/.delivery.jsonl")"
[ "$(mstate "$seq1")" = read ] || fail "T1 the machine reads: $(mstate "$seq1")"
pass "T1 a PostToolBatch pull hands the steer to the agent, moves it to handled/ and records read"

# T2
steer "second steer: add a test"
steer "third steer: run the lint"
out=$(run_hook Stop '{"stop_hook_active":false}')
[ "$(printf '%s' "$out" | jq -r '.decision')" = block ] || fail "T2 the Stop hook did not block: $out"
reason=$(printf '%s' "$out" | jq -r '.reason')
a=$(printf '%s' "$reason" | grep -n 'add a test' | cut -d: -f1); b=$(printf '%s' "$reason" | grep -n 'run the lint' | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "T2 the steers are missing or out of order: $reason"
[ "$(msgs)" -eq 0 ] || fail "T2 steers remain in the inbox"
pass "T2 a Stop pull blocks the turn end with the waiting steers in numeric order"

# T3
out=$(run_hook Stop '{}'); [ -z "$out" ] || fail "T3 an empty inbox printed: $out"
out=$(run_hook PostToolBatch '{}'); [ -z "$out" ] || fail "T3 an empty inbox printed: $out"
pass "T3 an empty inbox prints nothing, so the turn ends as before"

# T4
seq2=$(find "$INBOX/handled" -name '*.msg' | sed 's#.*/##;s#\.msg##' | sort | sed -n 2p)
JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" "$ROOT/bin/jg-delivery.sh" handled "$id" "$seq2" --evidence "commit:abc123" >/dev/null 2>&1 \
  || fail "T4 the claim was refused"
[ "$(mstate "$seq2")" = handled ] || fail "T4 the machine reads: $(mstate "$seq2")"
pass "T4 the claim after the pull moves the steer to handled"

echo "all jg-hook-inbox tests passed"
