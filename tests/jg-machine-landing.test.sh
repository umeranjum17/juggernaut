#!/usr/bin/env bash
# Behavior tests for the landing and trunk-pointers machine tables (core/machines/tables).
# Every record is generated here by a seed function in the shape its writer prints; no fleet record is copied.
# The tables are report-only: `show` and `check` print findings and nothing in the landing chain calls them.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-landing)
export JG_HOME="$T/home"
M=$JG_HOME/data/jg-trunk-landing; S=$JG_HOME/state
mkdir -p "$M" "$S"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }
rep() { printf "$1%.0s" $(seq "$2"); }
H=$(rep a 40); X=$(rep b 40); NOW=$(date +%s)

seed_land() { printf '%s\n' "$2" > "$M/$1.state"; }  # <file stem> <content as the writer prints it>
word_of() {  # the state word `show` found, or the word the observer printed when it found none
  jm show landing "$1"
  if [ "$RC" -eq 0 ]; then printf '%s\n' "$OUT" | awk -F'\t' '$1 == "state" { print $2 }'
  else printf '%s\n' "$OUT" | sed -n "s/.*observer printed '\(.*\)'.*/\1/p"; fi
}

jm check landing; expect_code 0 "$RC" "the landing table lints"; assert_contains "$OUT" "ok landing" "check names the landing table"
jm check trunk-pointers; expect_code 0 "$RC" "the trunk-pointers table lints"
pass "both tables pass the engine lint"

# Both writers: trunk-v3 (running <epoch>, landed, wait <why>, final <why>) and c63db7ed (running <epoch> <pid>,
# landed <output>, and the jg-trunk.sh shape <kind> <count> <reason> in a three-part file name).
seed_land "t1.$H" "running $NOW";                        seed_land "t2.$H" "running $NOW 4242"
seed_land "t3.$H" "landed";                              seed_land "t4.$H" "landed cleaned up"
seed_land "t5.$H" "wait REFUSED: trunk is red";          seed_land "t6.$H.$X" "wait 0 REFUSED: away mode"
seed_land "t7.$H.$X" "retry 1 REFUSED: read bound";      seed_land "t8.$H" "final REFUSED: conflict in a.txt"
seed_land "t9.$H.$X" "final 2 REFUSED: gate failed; full log: /x"
: > "$T/shapes.corpus"
for id in "t1.$H:running" "t2.$H:running" "t3.$H:landed" "t4.$H:landed" "t5.$H:wait" "t6.$H.$X:wait" \
  "t7.$H.$X:retry" "t8.$H:final" "t9.$H.$X:final" "none.$H:new"; do
  assert_equals "${id##*:}" "$(word_of "${id%:*}")" "${id%:*} is ${id##*:}"
  word_of "${id%:*}" >> "$T/shapes.corpus"
done
jm check landing --corpus "$T/shapes.corpus"; expect_code 0 "$RC" "both writer shapes are accepted"
assert_equals "ok landing: 10 lines, 0 findings" "$OUT" "check counts the shapes"
pass "check accepts both writer shapes"

# A running record with no epoch above 0, an epoch past the 6-hour expiry, or a pid that is not a number is a finding.
seed_land "r0.$H.$X" "running 0"; seed_land "r1.$H" "running"; seed_land "r2.$H" "running $((NOW - 30000))"
seed_land "r3.$H" "running $NOW 4x2"; seed_land "r4.$H" "env-wait away"
: > "$T/bad.corpus"
for id in r0.$H.$X:running-no-epoch r1.$H:running-no-epoch r2.$H:running-expired r3.$H:running-bad-pid r4.$H:env-wait; do
  jm show landing "${id%:*}"; expect_code 1 "$RC" "${id%:*} is a finding"
  assert_contains "$OUT" "no state: the observer printed '${id##*:}'" "${id%:*} names ${id##*:}"
  printf '%s\n' "${id##*:}" >> "$T/bad.corpus"
done
jm check landing --corpus "$T/bad.corpus"; expect_code 1 "$RC" "check flags running 0 and the other bad shapes"
assert_contains "$OUT" "bad landing corpus:1: running-no-epoch is not a state" "check names running 0"
assert_contains "$OUT" "fail landing: 5 lines, 5 findings" "check counts the findings"
jm check landing; expect_code 0 "$RC" "a bad record never fails the table check (report-only)"
pass "check flags running 0, expiry, a bad pid and an unlisted state, and blocks nothing"

# Moves: the writers' legal moves replay clean; a move out of a terminal state is a finding.
{ tab new start running; tab running land landed; tab running refuse-wait wait; tab wait restart running
  tab running refuse-final final; tab running retry retry; tab retry restart running; } > "$T/moves.corpus"
jm check landing --corpus "$T/moves.corpus"; expect_code 0 "$RC" "legal moves replay clean"
tab landed start running > "$T/bad-move.corpus"
jm check landing --corpus "$T/bad-move.corpus"; expect_code 1 "$RC" "a move out of landed"
assert_contains "$OUT" "landed start running is not a move" "check names the move"
pass "check replays the legal moves and refuses a move out of a terminal state"

# Trunk pointers: one project, its pointer files and its live rows.
P=proj; A=$(rep 1 40); B=$(rep 2 40)
seed_ptr() {  # <tip> <green> <released> [word sha] [live status for green] [rolled]
  printf '%s' "$1" > "$S/trunk-tip-$P"; printf '%s' "$2" > "$S/trunk-green-$P"; printf '%s' "$3" > "$S/trunk-released-$P"
  rm -f "$S/trunk-word-live-$P" "$S/trunk-rolled-$P" "$JG_HOME/data/trunk-live.tsv"
  [ -z "${4:-}" ] || tab "$4" 1 "ship it" > "$S/trunk-word-live-$P"
  [ -z "${5:-}" ] || tab "$P" "$2" 1 "$5" > "$JG_HOME/data/trunk-live.tsv"
  [ -z "${6:-}" ] || printf 'url' > "$S/trunk-rolled-$P"
}
ptr() { seed_ptr "$@"; jm show trunk-pointers "$P"; printf '%s\n' "$OUT" | awk -F'\t' '$1 == "state" { print $2 }'; }
assert_equals released "$(ptr "$A" "$A" "$A")" "tip, green and released agree"
assert_equals rolled "$(ptr "$A" "$A" "$A" "" "" 1)" "a cut-over trunk"
assert_equals landed "$(ptr "$B" "$A" "$A")" "tip ahead of green"
assert_equals green "$(ptr "$B" "$B" "$A")" "tip is green"
assert_equals word-given "$(ptr "$B" "$B" "$A" "$B")" "the captain's word is recorded"
assert_equals live "$(ptr "$B" "$B" "$A" "" live)" "the home runs green"
assert_equals pinned-behind "$(ptr "$B" "$A" "$A" "" "live,pinned-behind-222222222222")" "red CI pinned the home back"
assert_equals hook-failed "$(ptr "$B" "$B" "$A" "$B" hook-failed)" "the live hook failed"
jm show trunk-pointers nope; expect_code 1 "$RC" "a project with no trunk"
assert_contains "$OUT" "no state" "show names the missing state"
pass "trunk-pointers names each pointer state from the pointer files"

{ tab released land landed; tab landed verify green; tab green word word-given; tab word-given live live
  tab live release released; tab released rollover rolled; tab green ci-red pinned-behind; tab word-given hook-fail hook-failed
  tab hook-failed live live; tab pinned-behind ci-green green; } > "$T/ptr.corpus"
jm check trunk-pointers --corpus "$T/ptr.corpus"; expect_code 0 "$RC" "the trunk lifecycle replays clean"
tab landed release released > "$T/ptr-bad.corpus"
jm check trunk-pointers --corpus "$T/ptr-bad.corpus"; expect_code 1 "$RC" "a release of an unverified tip"
pass "check replays the trunk lifecycle and refuses a release of a tip that is not green"
