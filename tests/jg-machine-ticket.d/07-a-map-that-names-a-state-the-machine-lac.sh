# shellcheck shell=bash disable=SC2016,SC2013,SC2034,SC2154  # a case of the test that sources it: it shares that test's variables
# 7. A map that names a state the machine lacks, or a wait the enums lack, is refused.
mkdir -p "$T/maps"; cp "$ROOT/core/machines/maps/ticket-words.tsv" "$T/maps/"; tab word task bogus nowhere lead ok >> "$T/maps/ticket-words.tsv"
OUT=$(JG_MACHINES_MAPS="$T/maps" bash "$JM" word ticket-words task rework 2>&1); RC=$?; expect_code 1 "$RC" "a map with a bad target"
assert_contains "$OUT" "word task bogus: target nowhere is not a state of ticket" "the bad target is named"
pass "a bad map is refused"
