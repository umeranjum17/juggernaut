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

jm check recon; expect_code 0 "$RC" "the recon table lints"; assert_equals "ok recon: 3 states, 4 edges" "$OUT" "lint golden"
jm enum recon; expect_code 0 "$RC" "the enum lints"
jm coverage recon; expect_code 0 "$RC" "every edge names its test"
pass "the recon table lints with 3 states and 4 moves, each with a test"

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
jm check recon --corpus <(printf 'drafted\tgaps\tcritiqued\ncritiqued\trevise\tdrafted\ndrafted\tclear\taccepted\n'); expect_code 0 "$RC" "the moves the script wrote replay clean"
pass "the record, critic.md and the table agree"

# The guard: an illegal move out of the final state is logged in shadow.
bash "$ROOT/bin/jg-machine-guard.sh" edge recon accepted drafted rc-1 >/dev/null 2>&1; expect_code 0 "$?" "an illegal move in shadow is allowed by the guard"
LOG=$JG_HOME/data/machine-shadow.log; [ -s "$LOG" ] || fail "the illegal move left no shadow line"
pass "an illegal move out of accepted is logged by the guard in shadow"
