#!/usr/bin/env bash
# Behavior tests for the captain-call machine (core/machines/tables/captain-call.tsv) run by bin/jg-machine.sh.
# A captain call has one state, read through the existing bin/jg-captain-hold.sh predicates: the observer never
# reimplements them. This suite proves the table lints, each state reads from the owner, the `diverged` state agrees
# with `jg-captain-hold.sh diverged` on every seeded task, and each state lists the moves its table rows name.
# The moves are taken for real in tests/jg-machine-call-b.test.sh and tests/jg-machine-call-c.test.sh; all three share
# tests/jg-machine-call-fixture.sh.
# shellcheck source=tests/jg-machine-call-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-machine-call-fixture.sh"

seed_call none sm8-plain
seed_call open sm8-open
seed_call answered sm8-answered
seed_call diverged sm8-diverged

# The table must exist and be legal: the engine lints it before it answers.
jm check captain-call; expect_code 0 "$RC" "the captain-call table passes the engine lint"
assert_contains "$OUT" "ok captain-call:" "check names the machine"
pass "the captain-call table lints clean"

# One state word per seeded record, from the existing predicates; each is read once and judged twice below.
states=''
for id in sm8-plain sm8-open sm8-answered sm8-diverged; do states="$states$id $(state_of "$id")"$'\n'; done
state() { printf '%s' "$states" | awk -v id="$1" '$1 == id { print $2 }'; }
assert_equals none "$(state sm8-plain)" "a task that is no captain call"
assert_equals open "$(state sm8-open)" "a call held for the captain"
assert_equals answered "$(state sm8-answered)" "a call with the captain's recorded answer"
assert_equals diverged "$(state sm8-diverged)" "a held call whose status log already says resolved"
jm show captain-call sm8-absent; expect_code 1 "$RC" "a task this home does not carry is in no state"
assert_contains "$OUT" "no state" "show names the missing state"
pass "show reports open, answered, diverged and none from the existing predicates"

# The diverged verdict agrees with `jg-captain-hold.sh diverged` on every seeded task.
want=$(diverged_ids)
assert_equals "$want" "$(printf '%s' "$states" | awk '$2 == "diverged" { print $1 }' | LC_ALL=C sort)" \
  "diverged agrees with jg-captain-hold.sh diverged"
assert_equals sm8-diverged "$want" "the guard names exactly the seeded divergence"
pass "the machine's diverged verdict equals jg-captain-hold.sh diverged on every seeded task"

# Each state lists exactly the moves its table rows name.
moves_of() { jm next captain-call "$1"; printf '%s\n' "$OUT" | awk -F'\t' '$1=="move"{print $2">"$3}' | LC_ALL=C sort | paste -sd' '; }
assert_equals "answer>answered reconcile>none resolved-in-log>diverged" "$(moves_of sm8-open)" "open moves"
assert_equals "answer>answered reconcile>none" "$(moves_of sm8-diverged)" "diverged moves"
assert_equals "hold>open" "$(moves_of sm8-answered)" "answered moves"
assert_equals "hold>open" "$(moves_of sm8-plain)" "none moves"
pass "each state lists the moves its table rows name"

# The observer reads through the owner: no copy of its logic lives in the observer.
if grep -E 'show_field|status_key_closing_verb|Captain hold set|Resolution mode' "$ROOT/core/machines/observers/call.sh" >/dev/null; then
  fail "the observer reimplements jg-captain-hold.sh"
fi
grep -q 'jg-captain-hold.sh' "$ROOT/core/machines/observers/call.sh" || fail "the observer does not call jg-captain-hold.sh"
pass "the observer calls jg-captain-hold.sh and holds none of its logic"
