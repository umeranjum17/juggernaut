#!/usr/bin/env bash
# Behavior tests for the hold machine (core/machines/tables/hold.tsv, observer core/machines/observers/hold.sh): a question held for the owner
# has 5 states (raised, deferred, answered, diverged, closed) and 8 moves. Every record is made through the real bin/jg-captain-hold.sh and
# a real Beads store in the shape its writer prints; no fleet record is copied. The word of each task is read through the real
# bin/jg-machine.sh, which runs the real observer, which asks bin/jg-captain-hold.sh (`diverged`, `phase`) and holds none of its rules.
# This suite owns the lint, the moves and the open states (raised, deferred, answered, diverged); tests/jg-machine-hold-b.test.sh owns the
# settled ones (closed) and the task with no hold. Both share tests/jg-machine-hold-fixture.sh. The table is report-only.
# shellcheck source=tests/jg-machine-hold-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-machine-hold-fixture.sh"

jm check hold; expect_code 0 "$RC" "the hold table lints"; assert_equals "ok hold: 5 states, 8 edges" "$OUT" "lint golden"
jm enum hold; expect_code 0 "$RC" "the enum lints"; assert_contains "$OUT" 5 "five values"
jm coverage hold; expect_code 0 "$RC" "every edge names its test"
assert_equals "raised deferred answered diverged closed" \
  "$(awk -F'\t' '$1=="state"{printf "%s ", $2}' "$ROOT/core/machines/tables/hold.tsv" | sed 's/ $//')" "the five states"
if [ -e "$ROOT/core/machines/tables/captain-call.tsv" ]; then fail "captain-call.tsv is replaced by hold.tsv and must be gone"; fi
pass "the hold table lints with 5 states and 8 moves, each with a test, and captain-call.tsv is gone"

# A fixture record in every state. Each is made through the real CLI (hold, answer) or, for the answer that is recorded and not yet
# completed, in the exact body shape write_resolution_record leaves while the close is still to come.
hold hold h-raised --title "Choose the sample option for h-raised" --reason "$reason" --repo sample >/dev/null || fail "seed raised"
hold hold h-later --title "Choose the sample option for h-later" --reason "$reason" --repo sample --until 2099-01-01 >/dev/null || fail "seed deferred"
hold hold h-flight --title "Choose the sample option for h-flight" --reason "$reason" --repo sample >/dev/null || fail "seed answered"
printf 'Captain hold set: 2026-11-12T10:00:00Z\n\nResolution recorded by jg-captain-hold.\nDecision digest: abc123\nResolution mode: answered\n\nCaptain decision:\nUse the first sample option.\n' > "$T/inflight.body"
jg_test_backlog "$HOME_DIR" update h-flight --body-file "$T/inflight.body" >/dev/null || fail "write the in-flight answer"
hold hold h-diverged --title "Choose the sample option for h-diverged" --reason "$reason" --repo sample >/dev/null || fail "seed diverged"
printf 'needs-decision [key=h-diverged]: choose the sample option\nresolved [key=h-diverged]: answered: first option\n' > "$HOME_DIR/state/h-origin.status"

: > "$T/states.corpus"
for pair in h-raised:raised h-later:deferred h-flight:answered h-diverged:diverged; do
  id=${pair%:*}; want=${pair#*:}; got=$(word_of "$id")
  echo "show hold $id -> $got"
  assert_equals "$want" "$got" "$id is $want"
  printf '%s\n' "$got" >> "$T/states.corpus"
done
for st in raised deferred answered diverged; do grep -qx "$st" "$T/states.corpus" || fail "no fixture is in state $st"; done
jm check hold --corpus "$T/states.corpus"; expect_code 0 "$RC" "every word a fixture printed is a state"
pass "a fixture record in each open state prints the right word"


# Moves: the 8 legal moves replay clean; a move out of a final state is a finding.
{ tab raised later deferred; tab deferred date raised; tab raised answer answered; tab raised withdraw closed; tab answered route closed
  tab raised diverge diverged; tab answered diverge diverged; tab diverged reconcile raised; } > "$T/moves.corpus"
jm check hold --corpus "$T/moves.corpus"; expect_code 0 "$RC" "legal moves replay clean"
tab closed hold raised > "$T/bad-move.corpus"
jm check hold --corpus "$T/bad-move.corpus"; expect_code 1 "$RC" "a move out of closed"
assert_contains "$OUT" "closed hold raised is not a move" "check names the move"
pass "check replays the legal moves and refuses a move out of a final state"

# The shadow log: a legal move adds no line, an illegal one adds exactly one, and the writer carries on.
LOG=$HOME_DIR/data/machine-shadow.log
lines() { [ -f "$LOG" ] && wc -l < "$LOG" || echo 0; }
shadow() { local b; b=$(lines); bash "$ROOT/bin/jg-machine-shadow.sh" hold "$1" "$2" || fail "the shadow helper must always exit 0"; echo $(( $(lines) - b )); }
echo "shadow log before: $(lines) lines"
assert_equals 0 "$(shadow h-raised answered)" "raised -> answered is legal: the move the answer reports"
assert_equals 0 "$(shadow h-raised deferred)" "raised -> deferred is legal"
assert_equals 0 "$(shadow h-later raised)" "deferred -> raised is legal"
assert_equals 0 "$(shadow h-flight closed)" "answered -> closed is legal"
assert_equals 0 "$(shadow h-diverged raised)" "diverged -> raised is legal"
echo "shadow log after the five legal moves: $(lines) lines"
assert_equals 1 "$(shadow h-later answered)" "deferred -> answered skips the date and is illegal"
assert_contains "$(tail -n 1 "$LOG")" hold "the shadow line names the machine"
pass "a legal move adds no shadow line, an illegal move adds one"

# The observer reads through the owner: no copy of its logic lives in the observer.
if grep -E 'show_field|status_key_closing_verb|Captain hold set|Resolution mode' "$ROOT/core/machines/observers/hold.sh" >/dev/null; then
  fail "the observer reimplements jg-captain-hold.sh"
fi
grep -q 'jg-captain-hold.sh' "$ROOT/core/machines/observers/hold.sh" || fail "the observer does not call jg-captain-hold.sh"
pass "the observer calls jg-captain-hold.sh and holds none of its logic"
