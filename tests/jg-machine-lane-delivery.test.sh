#!/usr/bin/env bash
# Behavior test for the lane-delivery machine (core/machines/tables/lane-delivery.tsv): one command says where a lane's
# change stands between the worker's done line and the main branch. Every record is made here in the shape its writer
# prints (status lines, lane meta, landing state files, data/trunk-*.tsv rows); no fleet record is copied. The shapes of section 6.5 of the plan are built from these records:
#   fric-s2-wait-or-final: done, then a `final` landing refusal (9 Nov)                     -> refused
#   a landing row with an empty verify log (lead-sweeps-landed-lanes, 9 Nov)               -> landed
#   the green pin b7b93282e: a hook-failed project row, a rolled-back home row, no live row -> home-behind
#   a red CI at the live commit pins the green pin and every home back                    -> home-behind
# A red trunk is no state: nothing pins it or holds a go-live (fric-no-red-trunk-stop), so section 6.5's red, red-fix-landed
# and live-held states and its t6 and t14 moves are gone.
# A change in a release pull request is read by the release observer (tests/jg-machine-release.test.sh); the lane
# table stops at the trunk and the go-live, so its readers read the ticket's sub-state for the release.
# Each walk takes the moves its writers make, every observation is replayed against the table as a corpus, every edge
# of the table is seen at least once, and each state names the state of an older table that it was read from.
set -u
export LC_ALL=C
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"; OBS="$ROOT/core/machines/observers/lane-delivery.sh"; TABLES="$ROOT/core/machines/tables"
T=$(jg_test_tmproot jg-machine-lane-delivery)
export JG_HOME="$T/home" PATH="$T/bin:$PATH" GIT_CONFIG_COUNT=0
unset JG_STATE_OVERRIDE JG_DATA_OVERRIDE JG_CONFIG_OVERRIDE JG_MACHINES_TABLES
S=$JG_HOME/state; D=$JG_HOME/data; M=$D/jg-trunk-landing; R=$JG_HOME/projects/repo
mkdir -p "$S" "$M" "$JG_HOME/config" "$T/bin" "$T/pr" "$R"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
g() { git -C "$R" -c user.name=t -c user.email=t@example.test -c commit.gpgsign=false "$@"; }
git init -q -b trunk "$R"; g commit -q --allow-empty -m base; BASE=$(g rev-parse HEAD)
mk() { g commit-tree "$BASE^{tree}" -p "$1" -m "$2"; }  # <parent> <message>: a new commit; prints its sha

declare -A P H LAST
lane() {  # <lane> <project> [<parent>] [<message>]: a ship branch with one commit and the lane's meta
  [ -e "$JG_HOME/projects/$2" ] || ln -s repo "$JG_HOME/projects/$2"
  P[$1]=$2; H[$1]=$(mk "${3:-$BASE}" "${4:-$1}"); g branch -f "fm/$1" "${H[$1]}"
  jg_write_meta "$S/$1.meta" "project=$JG_HOME/projects/$2" "mode=local-trunk" "branch=fm/$1" "worktree=$T/wt-$1" "spawn_gen=g-$1"
}
status() { printf '%s [at=%s]: %s\n' "$2" "$(date +%s)" "$3" >> "$S/$1.status"; }
lstate() { printf '%s\n' "$2" > "$M/$1.${H[$1]}.state"; }
prove() {  # <lane>: the receipt, the approved merge-card evidence and the sealed run at the head, as the lane publishes them
  local d=$D/$1 h=${H[$1]}; mkdir -p "$d/.done-done/runs"; printf 'ok\n' > "$d/run.log"
  printf '{"schema":1,"task":"%s","mode":"local-trunk","spawn_gen":"g-%s","head":"%s","pr":"","verdict":"PASS","at":1,"evidence":"done-done run: ok"}\n' "$1" "$1" "$h" > "$S/$1.run-receipt.json"
  printf '{"head":"%s","verdict":"pass","check":{"claim":"a user can land","evidence":["%s/run.log"]}}\n' "$h" "$d" > "$d/merge-card.json"
  printf '{"schema":1,"run_id":"20261109T000000Z-%s-ab","commit":"%s","exit":0,"dirty":false,"started_at":"2026-11-09T00:00:00Z","files":["run.log"]}\n' "${h:0:8}" "$h" > "$d/.done-done/runs/run-$h.json"
}
land() { tab "$1" "${P[$1]}" "${H[$1]}" "$(date +%s)" full >> "$D/trunk-landings.tsv"; printf '%s\n' "${H[$1]}" > "$S/trunk-tip-${P[$1]}"; }
live() { tab "$1" "$2" "$(date +%s)" "$3" "$2" >> "$D/trunk-live.tsv"; }  # <project[:home]> <sha> <status>
# see <lane> <event> <word>: the observer names <word>; the state it says it was read from is a state of that older table;
# the move from the lane's last word is kept for the corpus.
see() {
  local out from
  out=$(bash "$JM" show lane-delivery "$1" 2>&1); assert_contains "$out" $'\nstate\t'"$3"$'\n' "$1 after $2 is $3: $out"
  from=$(bash "$OBS" detail "$1" | awk -F'\t' '$1 == "from" { print $2 }')
  [ "$from" = none ] || grep -q "^state	${from#*:}	" "$TABLES/${from%%:*}.tsv" || fail "$1 is $3, read from $from, which no older table holds"
  if [ -n "${LAST[$1]:-}" ]; then tab "${LAST[$1]}" "$2" "$3"; else printf '%s\n' "$3"; fi >> "$T/corpus"
  LAST[$1]=$3
}

bash "$JM" check lane-delivery >/dev/null; expect_code 0 "$?" "the table lints"
bash "$JM" coverage lane-delivery >/dev/null; expect_code 0 "$?" "every edge names its test"
assert_equals 12 "$(grep -c '^state	' "$TABLES/lane-delivery.tsv")" "the table holds 12 states: the release states are the release table's"
assert_equals 0 "$(grep -cE '^state	(release-|merged|rolled)' "$TABLES/lane-delivery.tsv")" "no release state is left in the lane table"
assert_equals 7 "$(awk -F'\t' '$1 == "edge" && $3 ~ /^t[0-9]+-/ { split($3, a, "-"); print a[1] }' "$TABLES/lane-delivery.tsv" | sort -u | wc -l)" "its edges carry the 7 transitions t1 to t5, t7 and t13"
pass "the table holds 12 states and the 7 transitions"

# Walk 1, fric-s2-wait-or-final: from coding to live, through a refusal and a refused cleanup.
L=fric-s2-wait-or-final; lane $L p1
status $L working "on it"; see $L - coding
status $L "done" "ready in branch feature/$L (local-trunk)"; see $L t1-done ready
prove $L; see $L t2-proof admitted
lstate $L "running $(date +%s) $$"; see $L t3-start landing
lstate $L "final REFUSED: the landing gate failed: tests/jg-trunk-wait-final.test.sh"; see $L t4-refuse refused
assert_contains "$(bash "$OBS" detail $L)" $'from\tlanding:final' "the refusal is read from the landing table's final"
lstate $L "running $(date +%s) $$"; see $L t5-retry landing
land $L; see $L t4-land landed
lstate $L "landed cleanup refused, nothing was forced: refused: the worktree has uncommitted changes"; see $L t13-refused cleanup-refused
assert_contains "$(bash "$OBS" detail $L)" $'chain\tlanded' "a refused cleanup still names where the change is"
rm -f "$S/$L.meta"; see $L t13-cleaned landed
live p1 "${H[$L]}" live; see $L t7-live live
pass "walk 1: coding to live; a final refusal and a refused cleanup are named"

# Walk 2, the green pin b7b93282e, then a red CI that pins it back.
L=b7-lane; lane $L p2; land $L; : > "$M/$L.${H[$L]}.verify.log"; see $L - landed
printf '%s\n' "${H[$L]}" > "$S/trunk-green-p2"
live p2 "${H[$L]}" "hook-failed:fleet: not every home is at ${H[$L]:0:12}: crewhouse (rollout stopped there)"
live p2:crewhouse "${H[$L]}" "rolled-back:missing-guard: missing: no home guard hook"; see $L t7-behind home-behind
live p2:primary "${H[$L]}" live; see $L t7-partial live-partial
live p2 "${H[$L]}" live; see $L t7-live live
live p2 "$BASE" "live,pinned-back-from:${H[$L]:0:12}"; live p2:primary "$BASE" "live,pinned-back-from:${H[$L]:0:12}"
see $L x1-ci-red home-behind
pass "walk 2: failed move rows are home-behind, and a red CI that pins every home back leaves the change home-behind, never red"

# Walks 3 to 10: each other edge, one project each so their records stay apart.
L=w3; lane $L p3; land $L; see $L - landed; live p3 "${H[$L]}" live; see $L t7-live live
L=w4; lane $L p4; land $L; see $L - landed; live p4:primary "${H[$L]}" live; see $L t7-partial live-partial
L=w5; lane $L p5; land $L; see $L - landed; live p5 "${H[$L]}" "hook-failed:the live hook exited 1"; see $L t7-behind home-behind
L=w6; lane $L p6; land $L; see $L - landed; live p6 "${H[$L]}" "hook-failed:the live hook exited 1"; see $L t7-behind home-behind
live p6 "${H[$L]}" live; see $L t7-live live
L=w7; lane $L p7; land $L; see $L - landed; tab "revert-$L" p7 "$(mk "${H[$L]}" revert)" "$(date +%s)" "reverts-${H[$L]:0:12}" >> "$D/trunk-landings.tsv"
see $L s18-revert reverted
L=w8; lane $L p8; land $L; see $L - landed; live p8 "${H[$L]}" "hook-failed:the live hook exited 1"; see $L t7-behind home-behind
L=w9; lane $L p9; land $L; see $L - landed; live p9:primary "${H[$L]}" live; see $L t7-partial live-partial
L=w10; lane $L p10; land $L; see $L - landed; tab "revert-$L" p10 "$(mk "${H[$L]}" revert)" "$(date +%s)" "reverts-${H[$L]:0:12}" >> "$D/trunk-landings.tsv"
see $L s18-revert reverted
L=w12; lane $L p12; status $L working "on it"; see $L - coding
printf 'task=%s\nhead=%s\n' "$L" "${H[$L]}" > "$S/$L.parked"; rm -f "$S/$L.meta"; see $L s27-park parked
pass "walks 3 to 10 take every other edge"

# Every observation is a state of the table, every observed move is a table edge, and every edge and state was seen.
bash "$JM" check lane-delivery --corpus "$T/corpus" >/dev/null; expect_code 0 "$?" "the observed states and moves are in the table"
awk -F'\t' '$1 == "edge" { print $2 "\t" $3 "\t" $4 }' "$TABLES/lane-delivery.tsv" | sort -u > "$T/edges"
assert_equals "" "$(grep $'\t' "$T/corpus" | sort -u | comm -23 "$T/edges" -)" "every edge of the table was walked"
assert_equals "" "$(awk -F'\t' '$1 == "state" { print $2 }' "$TABLES/lane-delivery.tsv" | sort | comm -23 - <(cut -f1,3 "$T/corpus" | tr '\t' '\n' | sort -u))" "every state was seen"
bash "$JM" check lane-delivery --corpus <(tab live t13-refused cleanup-refused) >/dev/null; expect_code 1 "$?" "a move the table lacks is refused"
pass "the walks cover every edge and state, and the table refuses a move it lacks"

L=w11; lane $L p11; status $L "done" "ready"; prove $L; see $L - admitted
# The command only reads: asking every lane again changes no file of the home. A failed pull request read and an
# unknown lane are no state, never a guess.
before=$(cd "$JG_HOME" && find . -type f -exec cksum {} + | sort)
for l in "${!LAST[@]}"; do bash "$JM" show lane-delivery "$l" >/dev/null 2>&1; done
assert_equals "$before" "$(cd "$JG_HOME" && find . -type f -exec cksum {} + | sort)" "the observer writes no record"
bash "$JM" show lane-delivery no-such-lane >/dev/null 2>&1; expect_code 1 "$?" "a lane with no record is no state"
pass "the observer writes nothing, and a lane with no record is no state"
