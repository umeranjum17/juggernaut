#!/usr/bin/env bash
# A charged trunk verify leaves the pin below the failing commit and starts one repair.
# If the approval write fails, the next verify tick resubmits the same ticket without running the gate again.
# shellcheck source=tests/jg-trunk-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-trunk-fixture.sh"

world repair
rig
repair_fixture
printf 'gate-full=true\ngate-verify=bash %s/rig.sh --all\n' "$W" >> "$HOME_D/config/trunk-policy"
lane baseline 'exit 0' t/a.test.sh
trunk land baseline >/dev/null 2>&1 || fail "the baseline must land"
trunk verify "$PROJ" >/dev/null 2>&1 || fail "the baseline must pass verify"
green=$(tip)
[ ! -s "$W/spawn-calls" ] || fail "the green baseline must not start a repair"

# A Juggernaut trunk supplies its own verify code, while the installed home still supplies the brief templates.
git -C "$PROJ" worktree add -q -b seed-code "$W/seed" trunk || fail "create the fixture's verifier tree"
cp -r "$W/root/bin" "$ROOT/core" "$ROOT/policy" "$W/seed/"
git -C "$W/seed" add bin core policy || fail "stage the verifier code"
commit_in "$W/seed" t/a.test.sh 'echo "not ok - fixture regression"; exit 1' "seed a red commit with the verifier"
JG_TRUNK_WRITER=1 git -C "$PROJ" update-ref refs/heads/trunk "$(git -C "$W/seed" rev-parse HEAD)" || fail "seed the fixture trunk"
red=$(tip)
printf '%s\n' "$red" > "$HOME_D/state/trunk-tip-proj"
item=verify-red-proj-${red:0:12}
: > "$W/approval-outage"
out=$(trunk verify "$PROJ" 2>&1) && fail "the test failure must keep verify red"
assert_contains "$out" "judging with the code of the tip" "the test exercises the archived verifier"
assert_contains "$out" "verify: trunk is red at ${red:0:12}" "the verify charges the new commit"
assert_contains "$out" "fixture approval temporarily unavailable" "the failed handoff reports the cause"
assert_contains "$(cat "$W/tickets/$item")" "$red" "the fix ticket names the failing commit"
[ ! -s "$W/spawn-calls" ] || fail "dispatch must wait for approval"

rm "$W/approval-outage"
trunk verify-due "$PROJ" >/dev/null 2>&1 && fail "a charged red must not run verify again"
await_repair_lane "$item"
trunk verify-due "$PROJ" >/dev/null 2>&1 && fail "the same bad tip must stay accounted for"
[ "$(cat "$HOME_D/state/trunk-green-proj")" = "$green" ] && [ "$(tip)" = "$red" ] || fail "repair must leave the pin below the red and preserve the trunk"
[ "$(grep -c "^add $item " "$W/backlog-calls")" = 1 ] || fail "the repair ticket must be filed once"
assert_contains "$(cat "$W/spawn-calls")" "--ticket $item " "the verify starts the lane for its own ticket"
[ "$(wc -l < "$W/spawn-calls")" = 1 ] || fail "the same red must start only one lane"
pass 'verify keeps the red and pin, recovers a refused approval and starts one repair lane'
