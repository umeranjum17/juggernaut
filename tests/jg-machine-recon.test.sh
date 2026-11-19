#!/usr/bin/env bash
# Behavior test for the recon machine (core/machines/tables/recon.tsv, owner bin/jg-recon-handoff.sh, observer core/machines/observers/recon.sh).
# The journey runs through the real script over a throwaway home: draft, critic verdict with gaps, revise, critic verdict clear, accept. A verdict
# that names an older report hash is refused and cannot close the newer draft. Every record is written by the script itself.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
JM="$ROOT/bin/jg-machine.sh"; RH="$ROOT/bin/jg-recon-handoff.sh"
T=$(jg_test_tmproot jg-machine-recon)
export JG_HOME="$T/home"; D=$JG_HOME/data/rc-1; mkdir -p "$D" "$JG_HOME/state"
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
rh() { OUT=$(bash "$RH" "$@" 2>&1); RC=$?; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

jm enum recon; expect_code 0 "$RC" "the enum lints"
jm coverage recon; expect_code 0 "$RC" "every edge names its test"
pass "the recon table lints with 4 states and 8 moves, each with a test"

rh phase rc-1; assert_equals none "$OUT" "no record yet"
rh draft rc-1; expect_code 1 "$RC" "a draft needs a report"
assert_contains "$OUT" "no report.md" "the refusal names the cause"
echo "draft one" > "$D/report.md"; H1=$(sha "$D/report.md")
rh verdict rc-1 --critic c-1 --hash "$H1" --gaps 0; expect_code 1 "$RC" "no verdict before a draft"
assert_contains "$OUT" "no draft is recorded" "the refusal names the cause"
rh revise rc-1; expect_code 1 "$RC" "no revision before a verdict"

rh draft rc-1; expect_code 0 "$RC" "the draft is recorded"
assert_equals drafted "$(bash "$ROOT/core/machines/observers/recon.sh" rc-1)" "the observer reads drafted"
jm show recon rc-1; assert_contains "$OUT" drafted "show reads the state through the table observer"
rh draft rc-1; expect_code 1 "$RC" "a second draft is refused"
pass "draft is recorded once, tied to the report hash"

# A verdict for another hash is stale and changes nothing.
STALE=$(printf 'older draft' | sha256sum | cut -d' ' -f1)
rh verdict rc-1 --critic c-1 --hash "$STALE" --gaps 0; expect_code 1 "$RC" "a verdict for another hash is refused"
assert_contains "$OUT" "stale verdict" "the refusal says stale"
assert_equals drafted "$(bash "$RH" phase rc-1)" "a stale verdict did not close the draft"
pass "a stale verdict cannot close a draft"

rh verdict rc-1 --critic c-1 --hash "$H1" --gaps 2; expect_code 0 "$RC" "the critic's verdict with gaps is recorded"
assert_equals critiqued "$(bash "$RH" phase rc-1)" "gaps move the draft to critiqued"
rh verdict rc-1 --critic c-1 --hash "$H1" --gaps 0; expect_code 1 "$RC" "a second verdict on the critiqued draft is refused"
rh revise rc-1; expect_code 1 "$RC" "a revision of an unchanged report is refused"
assert_contains "$OUT" "still holds the critiqued draft" "the refusal names the cause"
echo "draft two" > "$D/report.md"; H2=$(sha "$D/report.md")
rh revise rc-1; expect_code 0 "$RC" "the revision is recorded"
assert_equals drafted "$(bash "$RH" phase rc-1)" "the revision waits for its critic"

# The old verdict (hash H1) cannot close the revised draft; a report edited after the revise needs its own revise.
rh verdict rc-1 --critic c-1 --hash "$H1" --gaps 0; expect_code 1 "$RC" "the verdict for the older hash is refused"
assert_contains "$OUT" "stale verdict" "stale again"
echo "draft two, edited" > "$D/report.md"
rh verdict rc-1 --critic c-1 --hash "$H2" --gaps 0; expect_code 1 "$RC" "a report changed after the draft is refused"
assert_contains "$OUT" "report.md changed" "the refusal names the change"
echo "draft two" > "$D/report.md"
rh verdict rc-1 --critic c-1 --hash "$H2" --gaps 0; expect_code 0 "$RC" "the verdict for the current draft is recorded"
assert_equals accepted "$(bash "$RH" phase rc-1)" "no new gaps accepts the draft"
rh revise rc-1; expect_code 1 "$RC" "accepted is final"
rh verdict rc-1 --critic c-1 --hash "$H2" --gaps 3; expect_code 1 "$RC" "no move out of accepted"
pass "draft, verdict with gaps, revise and accept drive through the real script"

# The record and the gate's critic.md hold the same story.
assert_equals "draft gaps revise clear" "$(cut -f2 "$D/handoff.tsv" | tr '\n' ' ' | sed 's/ $//')" "the record holds every event in order"
assert_equals "$(printf 'Critic: c-1\nRound 1: new gaps 2 report %s\nRound 2: new gaps 0 report %s' "$H1" "$H2")" "$(cat "$D/critic.md")" "critic.md is in the gate's format"
echo "recon move events:"; cut -f2,3 "$D/handoff.tsv"
pass "the record, critic.md and the table agree"


# Critic ticket assignment (a separate ticket, its own task directory) and parent verdict ownership.
mkdir -p "$JG_HOME/data/rc-2" "$JG_HOME/data/rc-2-critic" "$JG_HOME/data/rc-2-critic-b"; D2=$JG_HOME/data/rc-2; C=$JG_HOME/data/rc-2-critic
echo "plan one" > "$D2/report.md"; G1=$(sha "$D2/report.md")
rh assign rc-2 --critic rc-2-critic; expect_code 1 "$RC" "no critic before a draft"; assert_contains "$OUT" "no draft is recorded" "the refusal names the cause"
rh draft rc-2; expect_code 0 "$RC" "rc-2 draft is recorded"
rh assign rc-2 --critic rc-2; expect_code 1 "$RC" "the researcher is not its own critic"; assert_contains "$OUT" "separate ticket" "the refusal names the cause"
rh assign rc-2 --critic no-such-ticket; expect_code 2 "$RC" "the critic ticket must exist"
rh assign rc-2 --critic rc-2-critic; expect_code 0 "$RC" "the critic ticket is assigned"
assert_equals assigned "$(bash "$RH" phase rc-2)" "an assigned draft reads assigned"
assert_equals "assigned" "$(bash "$ROOT/core/machines/observers/recon.sh" rc-2)" "the observer reads assigned"
assert_equals "$(printf 'rc-2-critic\t1\t%s' "$G1")" "$(bash "$RH" assignee rc-2)" "the assignee names critic, generation and hash"
assert_equals "$(printf 'rc-2\t1\t%s' "$G1")" "$(cat "$C/assignment.tsv")" "the critic ticket holds the pointer to its parent"
assert_equals "Critic: rc-2-critic" "$(cat "$C/critic.md")" "the critic ticket names itself as the gate reads it"

# The assignment is the record on disk: a new process in another directory, with only JG_HOME, reads the same answer (a restart).
RESTART=$(cd / && env -i PATH="$PATH" JG_HOME="$JG_HOME" bash "$RH" assignee rc-2)
assert_equals "$(printf 'rc-2-critic\t1\t%s' "$G1")" "$RESTART" "the assignment survives a restart"
rh assign rc-2 --critic rc-2-critic; expect_code 0 "$RC" "assigning the same critic again is a no-op"
assert_contains "$OUT" "already holds" "the retry says so"
assert_equals 2 "$(grep -c . "$D2/handoff.tsv")" "the retry wrote no second assignment"
rh assign rc-2 --critic rc-2-critic-b; expect_code 1 "$RC" "a second critic is refused while one holds the draft"
assert_contains "$OUT" "already holds" "the refusal names the holder"

# Only the assigned critic's verdict counts, and the parent record alone decides.
rh verdict rc-2 --critic rc-2-critic-b --hash "$G1" --gaps 0; expect_code 1 "$RC" "another critic's verdict is refused"
assert_contains "$OUT" "does not count" "the refusal names the cause"
assert_equals assigned "$(bash "$RH" phase rc-2)" "a verdict from another ticket closed nothing"
echo "plan two" > "$D2/report.md"; G2=$(sha "$D2/report.md")
rh verdict rc-2 --critic rc-2-critic --hash "$G1" --gaps 0; expect_code 1 "$RC" "the verdict for a report changed under review is refused"
rh revise rc-2; expect_code 0 "$RC" "a changed report retires the assignment"
assert_equals drafted "$(bash "$RH" phase rc-2)" "the revision waits for a critic again"
assert_equals none "$(bash "$RH" assignee rc-2)" "no assignment holds the new draft"
rh verdict rc-2 --critic rc-2-critic --hash "$G1" --gaps 0; expect_code 1 "$RC" "a late verdict for the old draft is refused"
assert_contains "$OUT" "stale verdict" "the refusal says stale"
rh assign rc-2 --critic rc-2-critic; expect_code 0 "$RC" "the same critic ticket takes the next generation"
assert_equals "$(printf 'rc-2-critic\t2\t%s' "$G2")" "$(bash "$RH" assignee rc-2)" "generation 2 holds the new hash"
rh verdict rc-2 --critic rc-2-critic --hash "$G2" --gaps 0; expect_code 0 "$RC" "the assigned critic's verdict is recorded"
assert_equals accepted "$(bash "$RH" phase rc-2)" "the parent record accepts the draft"
assert_equals none "$(bash "$RH" assignee rc-2)" "a finished review holds no assignment"
assert_equals "$(printf 'Critic: rc-2-critic\nRound 1: new gaps 0 report %s' "$G2")" "$(cat "$D2/critic.md")" "the parent critic.md is in the gate's format"
assert_equals "$(printf 'Critic: rc-2-critic\nRound 1: new gaps 0 report %s' "$G2")" "$(cat "$C/critic.md")" "the critic ticket's file follows the parent's verdict"
OUTG=$(JG_HOME=$JG_HOME bash "$ROOT/bin/jg-recon-gate.sh" rc-2-critic 2>&1); expect_code 0 "$?" "the gate passes the critic ticket on the owner's lines"
assert_contains "$OUTG" "PASS - critic task" "the gate reads the critic ticket's file"
assert_equals "assign revise assign clear" "$(cut -f2 "$D2/handoff.tsv" | tr '\n' ' ' | sed 's/ $//' | sed 's/^draft //')" "the record holds the assignments in order"
pass "critic ticket assignment, parent verdict ownership and restart survival drive through the real script"
