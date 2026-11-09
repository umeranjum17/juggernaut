#!/usr/bin/env bash
# Behavior tests for the captain-call machine (core/machines/tables/captain-call.tsv).
# A captain call has one state, read through the existing jg-captain-hold.sh predicates: the
# observer never reimplements them. Each task here is seeded by seed_call_home in a throwaway home
# with a real Beads store; no fleet record is copied. Each move the table lists is taken for real
# (hold, answer, re-hold, a resolved status line, reconcile close), and the `diverged` state must
# agree with `jg-captain-hold.sh diverged` on every seeded task.
set -u
export JG_TASK_PRIORITY_CHECK=/nonexistent
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-call)
HOME_DIR="$T/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
jg_test_beads_home "$HOME_DIR"
: > "$HOME_DIR/config/backlog-intake-loose"
FB=$(jg_fakebin "$HOME_DIR"); jg_fake_exit0 "$FB" tmux treehouse no-mistakes gh gh-axi

export PATH="$FB:$PATH" JG_HOME="$HOME_DIR" JG_STATE_OVERRIDE="$HOME_DIR/state" \
  JG_DATA_OVERRIDE="$HOME_DIR/data" JG_CONFIG_OVERRIDE="$HOME_DIR/config"
unset JG_MACHINES_TABLES
hold() { "$ROOT/bin/jg-captain-hold.sh" "$@"; }
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
state_of() { jm show captain-call "$1"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="state"{print $2}'; }
diverged_ids() { hold diverged | cut -f1 | LC_ALL=C sort; }
status_line() { printf '%s\n' "$2" >> "$HOME_DIR/state/$1.status"; }
reason="the captain must choose the sample option"

# Every call below is a captain call about a made-up sample; the ids are generated here.
seed_call_home() {
  local id
  jg_test_backlog "$HOME_DIR" add sm8-plain "Ordinary sample work" --kind ship --repo sample >/dev/null || fail "seed plain"
  for id in sm8-open sm8-answered sm8-diverged sm8-reconciled; do
    hold hold "$id" --title "Choose the sample option for $id" --reason "$reason" --repo sample >/dev/null || fail "seed hold $id"
  done
  printf 'Use the first sample option.\n' > "$T/answer.txt"
  hold answer sm8-answered --decision-file "$T/answer.txt" --release >/dev/null || fail "seed answer"
  status_line sm8-origin "needs-decision [key=sm8-diverged]: choose the sample option"
  status_line sm8-origin "resolved [key=sm8-diverged]: answered: first option"
}
seed_call_home

# The table must exist and be legal: the engine lints it before it answers.
jm check captain-call; expect_code 0 "$RC" "the captain-call table passes the engine lint"
assert_contains "$OUT" "ok captain-call:" "check names the machine"
pass "the captain-call table lints clean"

# One state word per seeded record, from the existing predicates.
assert_equals none "$(state_of sm8-plain)" "a task that is no captain call"
assert_equals open "$(state_of sm8-open)" "a call held for the captain"
assert_equals answered "$(state_of sm8-answered)" "a call with the captain's recorded answer"
assert_equals diverged "$(state_of sm8-diverged)" "a held call whose status log already says resolved"
jm show captain-call sm8-absent; expect_code 1 "$RC" "a task this home does not carry is in no state"
assert_contains "$OUT" "no state" "show names the missing state"
pass "show reports open, answered, diverged and none from the existing predicates"

# The diverged verdict agrees with `jg-captain-hold.sh diverged` on every seeded task.
want=$(diverged_ids)
got=''
for id in sm8-plain sm8-open sm8-answered sm8-diverged sm8-reconciled; do
  [ "$(state_of "$id")" = diverged ] && got="$got$id"$'\n'
done
assert_equals "$want" "$(printf '%s' "$got" | LC_ALL=C sort)" "diverged agrees with jg-captain-hold.sh diverged"
assert_equals sm8-diverged "$want" "the guard names exactly the seeded divergence"
pass "the machine's diverged verdict equals jg-captain-hold.sh diverged on every seeded task"

# Each move the table lists is taken for real, and the state lands on its `to`.
moves_of() { jm next captain-call "$1"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="move"{print $2">"$3}' | LC_ALL=C sort | paste -sd' '; }
assert_equals "answer>answered reconcile>none resolved-in-log>diverged" "$(moves_of sm8-open)" "open moves"
assert_equals "answer>answered reconcile>none" "$(moves_of sm8-diverged)" "diverged moves"
assert_equals "hold>open" "$(moves_of sm8-answered)" "answered moves"
assert_equals "hold>open" "$(moves_of sm8-plain)" "none moves"

hold hold sm8-answered --reason "$reason again" >/dev/null || fail "re-hold"
assert_equals open "$(state_of sm8-answered)" "answered -hold-> open"
hold hold sm8-plain --reason "$reason" >/dev/null || fail "hold a plain task"
assert_equals open "$(state_of sm8-plain)" "none -hold-> open"
hold answer sm8-plain --decision-file "$T/answer.txt" >/dev/null || fail "answer open"
assert_equals answered "$(state_of sm8-plain)" "open -answer-> answered"
status_line sm8-origin "needs-decision [key=sm8-open]: choose the sample option"
status_line sm8-origin "resolved [key=sm8-open]: answered: first option"
assert_equals diverged "$(state_of sm8-open)" "open -resolved-in-log-> diverged"
hold answer sm8-diverged --decision-file "$T/answer.txt" >/dev/null || fail "answer diverged"
assert_equals answered "$(state_of sm8-diverged)" "diverged -answer-> answered"
printf 'The sample option no longer applies.\n' > "$T/evidence.txt"
hold bind sm8-source >/dev/null || fail "bind the reconcile source"
printf '%s\n' sm8-reconciled | hold reconcile-requests --source-id sm8-source --source "captured board result" >/dev/null \
  || fail "request a reconcile"
hold reconcile close sm8-reconciled --evidence-file "$T/evidence.txt" >/dev/null || fail "reconcile close"
assert_equals none "$(state_of sm8-reconciled)" "open -reconcile-> none"
printf 'sm8-open\n' | hold reconcile-requests --source-id sm8-source --source "captured board result" >/dev/null || fail "request a second reconcile"
hold reconcile close sm8-open --evidence-file "$T/evidence.txt" >/dev/null || fail "reconcile close a diverged call"
assert_equals none "$(state_of sm8-open)" "diverged -reconcile-> none"
assert_equals "" "$(diverged_ids)" "no divergence is left once every call is settled"
pass "every listed move lands on its to state"

# The observer reads through the owner: no copy of its logic lives in the observer.
if grep -E 'show_field|status_key_closing_verb|Captain hold set|Resolution mode' "$ROOT/core/machines/observers/call.sh" >/dev/null; then
  fail "the observer reimplements jg-captain-hold.sh"
fi
grep -q 'jg-captain-hold.sh' "$ROOT/core/machines/observers/call.sh" || fail "the observer does not call jg-captain-hold.sh"
pass "the observer calls jg-captain-hold.sh and holds none of its logic"
