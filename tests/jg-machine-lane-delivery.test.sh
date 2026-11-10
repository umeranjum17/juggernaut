#!/usr/bin/env bash
# Behavior test for the lane-delivery machine (core/machines/tables/lane-delivery.tsv): one command says where a lane's
# change stands between the worker's done line and the main branch. Every record is made here in the shape its writer
# prints (status lines, lane meta, landing state files, data/trunk-*.tsv rows, the red pin, a stub gh for the release
# pull request); no fleet record is copied. The six shapes of section 6.5 of the plan are built from these records:
#   fric-s2-wait-or-final: done, then a `final` landing refusal (9 Nov)                     -> refused
#   a landing row with an empty verify log (lead-sweeps-landed-lanes, 9 Nov)               -> landed
#   the green pin b7b93282e: a hook-failed project row, a rolled-back home row, no live row -> home-behind
#   release pull request 813 with run 42711888100 red (Changed tests 3, CI required)       -> release-red
#   the same pull request, 18 of 18 checks green and not merged (10 Nov)                    -> release-green
#   01:23:11Z on 10 Nov: the red pin 9f5bbb3af0d1 stands, the fixes-red commit 77c927cfa landed and its verify log
#   says it passed only with a flaky failure set aside (fric-gate-shard-timeout)            -> red-fix-landed
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
# gh pr view <url> --json ...: prints the seeded pull request; a pull request with no seed is a failed read.
# shellcheck disable=SC2016 # the stub body is written out verbatim and expands when the stub runs
printf '#!/bin/sh\ncat "%s/pr/${3##*/}.json" 2>/dev/null || { echo "could not resolve to a PullRequest" >&2; exit 1; }\n' "$T" > "$T/bin/gh"; chmod +x "$T/bin/gh"

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
release() { tab "$1" trunk-v3 "$2" 3 "$(date +%s)" "https://github.com/umeranjum17/juggernaut/pull/$3" >> "$D/trunk-releases.tsv"; }
NAMES=("Repo invariants" "Lint 1" "Lint 2" "Lint 3" "Lint 4" "Shell syntax" "Smoke" "Fast evals" "Bus service" "Changed tests 1" "Changed tests 2" "Changed tests 3" "Changed tests 4" "Changed tests 5" "Changed tests 6" "Changed tests 7" "Changed tests 8" "CI required")
pr() {  # <number> <OPEN|MERGED> none|running|red|green: the pull request's checks on its head, as gh prints them
  local n s c rows=()
  for n in "${NAMES[@]}"; do s=COMPLETED; c=SUCCESS
    case "$3:$n" in none:*) continue ;; running:Changed*) s=IN_PROGRESS; c= ;; "red:Changed tests 3"|"red:CI required") c=FAILURE ;; esac
    rows+=("$(printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":"%s"}' "$n" "$s" "$c")")
  done
  printf '{"state":"%s","statusCheckRollup":[%s]}\n' "$2" "$(IFS=,; printf '%s' "${rows[*]}")" > "$T/pr/$1.json"
}
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
assert_equals 20 "$(grep -c '^state	' "$TABLES/lane-delivery.tsv")" "the table holds the 20 states of section 6.5"
assert_equals 14 "$(awk -F'\t' '$1 == "edge" && $3 ~ /^t[0-9]+-/ { split($3, a, "-"); print a[1] }' "$TABLES/lane-delivery.tsv" | sort -u | wc -l)" "its edges carry the 14 transitions t1 to t14"
pass "the table holds 20 states and the 14 transitions"

# Walk 1, fric-s2-wait-or-final: from coding to rolled, through a refusal, a refused cleanup, a hold and a red release run.
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
live p1 "${H[$L]}" "held:the trunk is red at 9f5bbb3af0d1"; see $L t6-held live-held
live p1 "${H[$L]}" live; see $L t7-live live
release p1 "${H[$L]}" 813; pr 813 OPEN none; see $L t8-release release-open
pr 813 OPEN running; see $L t9-run release-ci-running
pr 813 OPEN red; see $L t9-red release-red
pr 813 OPEN none; see $L t10-push release-open
pr 813 OPEN green; see $L t9-green release-green
pr 813 MERGED green; see $L t11-merge merged
printf '%s\n' https://github.com/umeranjum17/juggernaut/pull/813 > "$S/trunk-rolled-p1"; see $L t12-rollover rolled
pass "walk 1: coding to rolled; a final refusal, a red release run and 18 green checks not merged are named"

# Walk 2, the green pin b7b93282e and the red of 01:23:11Z.
L=b7-lane; lane $L p2; land $L; : > "$M/$L.${H[$L]}.verify.log"; see $L - landed
printf '%s\n' "${H[$L]}" > "$S/trunk-green-p2"
live p2 "${H[$L]}" "hook-failed:fleet: not every home is at ${H[$L]:0:12}: crewhouse (rollout stopped there)"
live p2:crewhouse "${H[$L]}" "rolled-back:missing-guard: missing: no home guard hook"; see $L t7-behind home-behind
live p2:primary "${H[$L]}" live; see $L t7-partial live-partial
live p2 "${H[$L]}" live; see $L t7-live live
live p2 "$BASE" "live,pinned-back-from:${H[$L]:0:12}"; live p2:primary "$BASE" "live,pinned-back-from:${H[$L]:0:12}"
printf '%s\n' "${H[$L]}" > "$S/trunk-red-p2"; see $L x1-red red
F=fric-gate-shard-timeout; lane $F p2 "${H[$L]}" "$F: a shard over its budget runs once more"$'\n\n'"fixes-red: ${H[$L]}"; land $F
printf '%s\n' "verify: judging every change since the release base b96c903b0486" "note: passed on the rerun, so judged flaky and not charged: tests/jg-tmp-reaper.test.sh" \
  "verify: ${H[$F]:0:12} passed only with a flaky failure set aside; the green pin stays" > "$M/$F.${H[$F]}.verify.log"
see $L x2-fix red-fix-landed; see $F - red-fix-landed
pass "walk 2: failed move rows are home-behind, and a red pin with a fix that passed only with a flaky failure set aside is red-fix-landed"

# Walks 3 to 10: each other edge, one project each so their records stay apart.
L=w3; lane $L p3; land $L; see $L - landed; printf '%s\n' "${H[$L]}" > "$S/trunk-red-p3"; see $L x1-red red
rm -f "$S/trunk-red-p3"; see $L t14-clear landed; live p3 "${H[$L]}" live; see $L t7-live live
L=w4; lane $L p4; land $L; see $L - landed; live p4:primary "${H[$L]}" live; see $L t7-partial live-partial
printf '%s\n' "${H[$L]}" > "$S/trunk-red-p4"; see $L x1-red red
L=w5; lane $L p5; land $L; see $L - landed; live p5 "${H[$L]}" "hook-failed:the live hook exited 1"; see $L t7-behind home-behind
printf '%s\n' "${H[$L]}" > "$S/trunk-red-p5"; see $L x1-red red
L=w6; lane $L p6; land $L; see $L - landed; live p6 "${H[$L]}" "hook-failed:the live hook exited 1"; see $L t7-behind home-behind
live p6 "${H[$L]}" live; see $L t7-live live
L=w7; lane $L p7; land $L; see $L - landed; release p7 "${H[$L]}" 7; pr 7 OPEN none; see $L t8-release release-open
pr 7 OPEN red; see $L t9-red release-red; tab "revert-$L" p7 "$(mk "${H[$L]}" revert)" "$(date +%s)" "reverts-${H[$L]:0:12}" >> "$D/trunk-landings.tsv"
see $L t10-revert reverted
L=w8; lane $L p8; land $L; see $L - landed; live p8 "${H[$L]}" "hook-failed:the live hook exited 1"; see $L t7-behind home-behind
release p8 "${H[$L]}" 8; pr 8 OPEN none; see $L t8-release release-open; pr 8 OPEN running; see $L t9-run release-ci-running
pr 8 OPEN green; see $L t9-green release-green
L=w9; lane $L p9; land $L; see $L - landed; live p9:primary "${H[$L]}" live; see $L t7-partial live-partial
release p9 "${H[$L]}" 9; pr 9 OPEN none; see $L t8-release release-open
L=w10; lane $L p10; land $L; see $L - landed; tab "revert-$L" p10 "$(mk "${H[$L]}" revert)" "$(date +%s)" "reverts-${H[$L]:0:12}" >> "$D/trunk-landings.tsv"
see $L s18-revert reverted
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
rm -f "$T/pr/9.json"; out=$(bash "$JM" show lane-delivery w9 2>&1); expect_code 1 "$?" "a failed pull request read is no state"
assert_contains "$out" "release-unread" "the failed read is named"
bash "$JM" show lane-delivery no-such-lane >/dev/null 2>&1; expect_code 1 "$?" "a lane with no record is no state"
pass "the observer writes nothing, and a read it cannot make is no state"
