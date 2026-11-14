# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 9. Reconcile: every edge of a traffic log gets its count, writer and verdict; a real edge no table and no named defect covers is UNNAMED.
SH=$T/reconcile-shadow.log MV=$T/reconcile-moves.log
{ for _ in 1 2 3; do tab 1 ticket delivering.batched close shadow; done
  tab 2 ticket building start shadow; tab 3 ticket released go-live shadow; tab 4 ticket proving.running new-head shadow; tab 5 ticket proving.running claim-done shadow
  tab 6 task unknown "done" shadow; } > "$SH"
{ tab 7 jg-x building claim-done proving.planned; tab 8 jg-y delivering.batched go-live delivering.live; } > "$MV"
jm reconcile ticket --shadow "$SH" --moves "$MV"; expect_code 0 "$RC" "every edge of the log is covered"
assert_contains "$OUT" "ok reconcile ticket: 7 edges, 9 lines, 0 unnamed" "the count line counts only the ticket's lines"
assert_contains "$OUT" "$(tab delivering.batched close 3 3 0 bin/jg-teardown.sh:main legal)" "a close from batched is a legal edge, with its writer and count"
assert_contains "$OUT" "$(tab building start 1 1 0 bin/jg-spawn.sh:main settled read-before-claim)" "a repeated claim is settled and named"
assert_contains "$OUT" "$(tab building claim-done 1 0 1 bin/jg-lavish-guard.sh:append legal)" "a legal move of the move log counts as moves"
assert_contains "$OUT" "$(tab proving.running new-head 1 1 0 bin/jg-lavish-guard.sh:append history old-done-line-move)" "a retired edge is history"
tab 9 ticket intake approve-twice shadow >> "$SH"; tab 10 ticket intake claim-done shadow >> "$SH"
jm reconcile ticket --shadow "$SH" --moves "$MV"; expect_code 1 "$RC" "an edge nobody names fails"
assert_contains "$OUT" "UNNAMED" "the verdict says so"; assert_contains "$OUT" "2 unnamed" "the count line counts both"
# The names are checked against the table: a row that names a state the table lacks is refused.
mkdir -p "$T/rmap/maps" "$T/rmap/tables"; cp "$TABLES"/*.tsv "$T/rmap/tables/"; cp "$ROOT"/core/machines/*.states "$T/rmap/"; cp "$ROOT/core/machines/observers" -r "$T/rmap/" 2>/dev/null
tab settled nowhere start x y > "$T/rmap/maps/ticket-traffic.tsv"
OUT=$(JG_MACHINES_TABLES=$T/rmap/tables JG_MACHINES_ENUMS=$T/rmap bash "$JM" settled ticket building start 2>&1); RC=$?
expect_code 1 "$RC" "a defect row that names a state the table lacks is refused"; assert_contains "$OUT" "a state of ticket" "the refusal says what a row is"
pass "reconcile lists each observed edge with its count, writer and verdict, and fails on an unnamed real edge"
