#!/usr/bin/env bash
# Behavior test for the four delivery words in the machine tables (H49e): the lane-delivery and release observers print
# Built, Landed, In use or Released for a lane, and the trunk-pointers table reads the same lane as built, landed, in-use or
# released through bin/jg-machine.sh. Records are made here in the shape their writers print; no fleet record is copied.
set -u
export LC_ALL=C
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"; M="$ROOT/core/machines"; WORDS="$ROOT/core/fleet-status/words.tsv"
T=$(jg_test_tmproot jg-machine-stage-words)
export JG_HOME="$T/home" PATH="$T/bin:$PATH" GIT_CONFIG_COUNT=0
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_MACHINES_TABLES
S=$JG_HOME/state D=$JG_HOME/data R=$JG_HOME/projects/repo
mkdir -p "$S" "$D/jg-trunk-landing" "$T/bin" "$T/pr" "$R"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
g() { git -C "$R" -c user.name=t -c user.email=t@example.test -c commit.gpgsign=false "$@"; }
git init -q -b trunk "$R"; g commit -q --allow-empty -m base; BASE=$(g rev-parse HEAD)
# shellcheck disable=SC2016 # the stub body is written out verbatim and expands when the stub runs
printf '#!/bin/sh\ncat "%s/pr/${3##*/}.json" 2>/dev/null || exit 1\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"

for m in lane-delivery release trunk-pointers; do bash "$JM" check "$m" >/dev/null; expect_code 0 "$?" "$m lints"; done
bash "$JM" coverage trunk-pointers >/dev/null; expect_code 0 "$?" "every trunk-pointers move names its test"
assert_equals "built landed in-use released" "$(awk -F'\t' '$1 == "state" { printf "%s ", $2 }' "$M/tables/trunk-pointers.tsv" | sed 's/ $//')" "the pointers are the four words"

# The Built group of the lane table is the Built row of the list of the four words; the other groups name the states of the
# table that hold the stages Landed, In use and Released.
assert_equals "$(awk -F'\t' '$1 == "Built" { for (i = 3; i <= NF; i++) printf "%s ", $i }' "$WORDS")" "$(awk -F'\t' '$2 == "word-built" { for (i = 3; i <= NF; i++) printf "%s ", $i }' "$M/tables/lane-delivery.tsv")" "the Built group is the Built row of the list"
assert_equals "merged" "$(awk -F'\t' '$2 == "word-released" { print $3 }' "$M/tables/release.tsv")" "Released is the merged release, as the list says"
pass "the tables and the list of the four words agree"

lane() {  # <lane> <project>: a ship branch with one commit and the lane's meta
  ln -sfn repo "$JG_HOME/projects/$2"
  H[$1]=$(g commit-tree "$BASE^{tree}" -p "$BASE" -m "$1"); g branch -f "fm/$1" "${H[$1]}"
  jg_write_meta "$S/$1.meta" "project=$JG_HOME/projects/$2" "mode=local-trunk" "branch=fm/$1" "spawn_gen=g-$1"
}
declare -A H
land() { tab "$1" "$2" "${H[$1]}" "$(date +%s)" full >> "$D/trunk-landings.tsv"; }
rel() {  # <lane> <project> <number> <OPEN|MERGED> <rollup>
  tab "$2" trunk-v3 "${H[$1]}" 3 "$(date +%s)" "https://github.com/example/$2/pull/$3" >> "$D/trunk-releases.tsv"
  printf '{"state":"%s","statusCheckRollup":[%s]}\n' "$4" "$5" > "$T/pr/$3.json"
}
OK='{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}'

expect() {  # <lane> <stage word or empty> <pointer or empty>
  assert_equals "$2" "$(bash "$M/observers/lane-delivery.sh" stage "$1")" "$1 stage word"
  assert_equals "$3" "$(bash "$M/observers/lane-delivery.sh" pointer "$1")" "$1 pointer"
  if [ -n "$3" ]; then assert_contains "$(bash "$JM" show trunk-pointers "$1")" $'state\t'"$3" "jg-machine shows $1 as $3"; fi
}
printf 'working [at=1]: on it\n' > "$S/a.status"; lane a p1; expect a "" ""                              # coding: not built yet
lane b p2; printf 'done [at=1]: ready\n' > "$S/b.status"; expect b Built built                              # done, proof incomplete
lane c p3; land c p3; expect c Landed landed
lane d p4; land d p4; tab p4 "${H[d]}" 1 live "${H[d]}" >> "$D/trunk-live.tsv"; expect d "In use" in-use
lane e p5; land e p5; rel e p5 5 OPEN "$OK"; expect e Landed landed                                          # an open release is still Landed
assert_equals "Landed" "$(bash "$M/observers/release.sh" stage e)" "an open release is Landed"
lane f p6; land f p6; tab p6 "${H[f]}" 1 live "${H[f]}" >> "$D/trunk-live.tsv"; rel f p6 6 MERGED "$OK"
assert_equals "Released" "$(bash "$M/observers/release.sh" stage f)" "a merged release is Released"
expect f "In use" released                                                                                  # the merged release wins the pointer
lane g p7; land g p7; tab "revert-g" p7 "$(g commit-tree "$BASE^{tree}" -p "$BASE" -m revert)" "$(date +%s)" reverts >> "$D/trunk-landings.tsv"; expect g "" ""
assert_equals "" "$(bash "$M/observers/release.sh" stage no-such-lane)" "a lane in no release has no release stage"
bash "$M/observers/lane-delivery.sh" stage >/dev/null 2>&1; expect_code 2 "$?" "stage without a lane is a usage error"
bash "$JM" check trunk-pointers --corpus <(printf 'built\nbuilt\tland\tlanded\nlanded\tgo-live\tin-use\nin-use\trelease\treleased\n') >/dev/null; expect_code 0 "$?" "the walk built to released is in the table"
bash "$JM" check trunk-pointers --corpus <(tab built release released) >/dev/null; expect_code 1 "$?" "a move the table lacks is refused"
pass "each lane reads its four-word stage through the observers and jg-machine"
