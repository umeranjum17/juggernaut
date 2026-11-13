#!/usr/bin/env bash
# Behavior test for the owner's proof bypass (bin/jg-proof-bypass.sh, core/machines/tables/bypass.tsv; machine 17 of the plan).
# Everything runs through the real command and the real delivery tick in a fixture home: a worker is refused, a grant with no word
# id is refused, a project grant with no end time gets 24 hours, list shows it, a ticket bypass ends when the ticket is released,
# a bypass past its end time reads ended and `find` then says the next done line is proved. The session digest line is covered by
# test_context_digest_proof_bypass in tests/jg-session-start.test.sh.
# shellcheck disable=SC2016
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PB="$ROOT/bin/jg-proof-bypass.sh"; JM="$ROOT/bin/jg-machine.sh"
T=$(cd "$(jg_test_tmproot jg-proof-bypass)" && pwd); H=$T/home
mkdir -p "$H/state" "$H/config" "$H/data"
printf '#!/usr/bin/env bash\ncat "%s/stage-$1" 2>/dev/null\n' "$T" > "$T/stage"; chmod +x "$T/stage"
export JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" JG_CONFIG_OVERRIDE="$H/config" JG_DATA_OVERRIDE="$H/data" JG_PROOF_BYPASS_STAGE_CMD="$T/stage"
unset JG_TASK_ID
pb() { OUT=$(bash "$PB" "$@" 2>&1); RC=$?; }
tick() { bash "$ROOT/bin/jg-delivery-tick.sh" "$H" >/dev/null 2>&1; }
col() { awk -F'\t' -v i="$1" -v c="$2" '$1 == i { print $c }' "$H/config/proof-bypass"; }

# 1. A worker never writes it, and a grant names its scope and the id that holds the owner's words.
JG_TASK_ID=jg-w1 pb grant --home --word owner-rule-abc123; expect_code 1 "$RC" "a call with a task id set"; assert_contains "$OUT" "a worker never writes" "the worker refusal says why"
[ ! -e "$H/config/proof-bypass" ] || fail "a refused grant wrote the record"
pb grant --project demo; expect_code 1 "$RC" "a grant with no word id"; assert_contains "$OUT" "owner rule or the board answer" "the refusal names what is needed"
pb grant --project demo --word "trust me"; expect_code 1 "$RC" "a word that is not an id"
pb grant --word owner-rule-abc123; expect_code 1 "$RC" "a grant with no scope"
pb grant --ticket jg-t1 --project demo --word owner-rule-abc123; expect_code 1 "$RC" "two scopes"
pb grant --ticket jg-t1 --word owner-rule-abc123 --hours 3; expect_code 1 "$RC" "a ticket with an end time"
pb grant --project demo --word owner-rule-abc123 --until 2001-01-01T00:00Z; expect_code 1 "$RC" "an end time in the past"
[ ! -e "$H/config/proof-bypass" ] || fail "a refused grant wrote the record"
pass "a worker, a missing word id, a bad scope and a past end time are refused and write nothing"

# 2. A grant for a project with no end time gets the default end of 24 hours; list and `find` print it.
t0=$(date +%s)
pb grant --project demo --word owner-rule-abc123; expect_code 0 "$RC" "a project grant"; P=$(awk '{ print $2 }' <<< "$OUT")
end=$(col "$P" 6); [ "$end" -ge $((t0 + 86400)) ] && [ "$end" -le $(( $(date +%s) + 86400 )) ] || fail "the default end is not 24 hours: $end"
pb grant --ticket jg-t1 --word board-answer:card-9; expect_code 0 "$RC" "a ticket grant"; K=$(awk '{ print $2 }' <<< "$OUT")
assert_equals "-" "$(col "$K" 6)" "a ticket bypass has no end time"
pb list; assert_contains "$OUT" "$P	standing	project	demo	word=owner-rule-abc123" "list shows the project bypass"; assert_contains "$OUT" "uses=0" "list shows the uses"
assert_equals "$K" "$(bash "$PB" find jg-t1 demo)" "the ticket's own bypass wins"
assert_equals "$P" "$(bash "$PB" find jg-t2 demo)" "a ticket of the project is covered by the project bypass"
bash "$PB" find jg-t2 other >/dev/null; expect_code 1 "$?" "a ticket of another project is proved"
bash "$JM" check bypass >/dev/null; expect_code 0 "$?" "the table lints"; assert_equals standing "$(bash "$JM" show bypass "$P" | awk -F'\t' '$1=="state"{print $2}')" "the machine reads standing"
pass "a project grant gets the default end and list, find and the machine print it"

# 3. A use is counted; a worker cannot count it, end it, or expire anything.
pb use "$P"; expect_code 0 "$RC" "a use"; assert_equals 1 "$(col "$P" 8)" "one use is counted"
JG_TASK_ID=jg-w1 pb use "$P"; expect_code 1 "$RC" "a worker counting a use"
JG_TASK_ID=jg-w1 pb end "$P"; expect_code 1 "$RC" "a worker ending a bypass"; assert_equals standing "$(bash "$PB" state "$P")" "the refused end changed nothing"
pass "a use is counted by the owner's side only"

# 4. The tick ends a ticket bypass when the ticket is released or closed, and not before.
echo building > "$T/stage-jg-t1"; tick; assert_equals standing "$(bash "$PB" state "$K")" "a building ticket keeps its bypass"
echo released > "$T/stage-jg-t1"; tick; assert_equals ended "$(bash "$PB" state "$K")" "a released ticket ends its bypass"
assert_contains "$(col "$K" 10)" "released" "the record says why"
assert_equals "$P" "$(bash "$PB" find jg-t1 demo)" "the ticket now falls under the project bypass"
pass "the tick ends a ticket bypass at release"

# 5. Past its end time a bypass reads ended before the tick runs, the tick writes it, and the next done line is proved.
awk -F'\t' -v OFS='\t' -v i="$P" -v e="$(( $(date +%s) - 5 ))" '$1 == i { $6 = e } { print }' "$H/config/proof-bypass" > "$T/pb.new" && mv "$T/pb.new" "$H/config/proof-bypass"
assert_equals ended "$(bash "$PB" state "$P")" "a bypass past its end time reads ended"
bash "$PB" find jg-t2 demo >/dev/null; expect_code 1 "$?" "the next done line is proved"
pb list; assert_contains "$OUT" "$P	ended" "list reads ended"
assert_equals ended "$(bash "$JM" show bypass "$P" | awk -F'\t' '$1=="state"{print $2}')" "the machine reads ended"
tick; assert_equals ended "$(col "$P" 7)" "the tick wrote the end"; assert_contains "$(col "$P" 10)" "end time" "the record says why"
pass "an expired bypass reads ended and the next done line is proved"

# 6. The owner ends one by his word; ending a second time is refused; a home bypass covers every ticket until then.
pb grant --home --word owner-rule-abc123 --hours 2; H1=$(awk '{ print $2 }' <<< "$OUT")
assert_equals "$H1" "$(bash "$PB" find jg-t9 anything)" "a home bypass covers a ticket of any project"
pb end "$H1"; expect_code 0 "$RC" "the owner ends it"; pb end "$H1"; expect_code 1 "$RC" "a second end"
bash "$PB" find jg-t9 anything >/dev/null; expect_code 1 "$?" "an ended home bypass covers nothing"
assert_equals "" "$(bash "$PB" digest)" "the digest prints nothing when none stands"
pb grant --home --word owner-rule-abc123 --hours 2; assert_contains "$(bash "$PB" digest)" "uses=0" "the digest prints a standing bypass with its uses"
pass "end is the owner's, and the digest prints what stands"
