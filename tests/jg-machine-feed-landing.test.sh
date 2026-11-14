#!/usr/bin/env bash
# The landing and release feed: a fixture home with real git history and the lander's own records becomes moves in
# data/machine-moves.log, each one a legal table edge with the record's time; a second run adds nothing; a move a
# writer already logged is kept.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(jg_test_tmproot jg-machine-feed-landing)
H="$TMP_ROOT/home"; D="$H/data"; P="$H/projects/demo"; MOVES="$D/machine-moves.log"
FEED="$ROOT/core/machines/feeds/landing-release.sh"
export JG_HOME="$H"
mkdir -p "$D"
jg_git_init_commit "$P"
c() { printf '%s\n' "$1" >"$P/$1"; git -C "$P" add "$1"; git -C "$P" -c user.name=t -c user.email=t@example.invalid commit -qm "$1"; git -C "$P" rev-parse HEAD; }
head1=$(c a); land1=$(c b)   # the lane's head and the trunk commit that carries it
live1=$(c c); rel1=$(c d); base1=$(c e)
T=$'\t'
printf 'task%shead%scommit%sfirst_done%sready%sgate_start%slaunch%slanded%sminutes\n' "$T" "$T" "$T" "$T" "$T" "$T" "$T" "$T" >"$D/trunk-latency.tsv"
printf 'lane1\t%s\t%s\t1000\t1010\t\t1030\t1100\t2\tqueue\n' "$head1" "$land1" >>"$D/trunk-latency.tsv"
printf 'lane1\tdemo\t%s\t%s\tno-landing-gate\n' "$land1" 1100 >"$D/trunk-landings.tsv"
printf 'lane1\tdemo\t%s\t%s\tresolving\t1040\t\nlane1\tdemo\t%s\t%s\tresolved\t1050\t\n' "$land1" "$head1" "$land1" "$head1" >"$D/trunk-resolving.tsv"
printf 'lane1\tdemo\t%s\t%s\tchecking\t1060\t\n' "$land1" "$head1" >"$D/trunk-landing-phases.tsv"
printf 'demo\t%s\t1200\tlive\t%s\n' "$live1" "$land1" >"$D/trunk-in-use.tsv"
printf 'demo\ttrunk-v1\t%s\t3\t1300\thttps://example.invalid/pull/1\n' "$rel1" >"$D/trunk-releases.tsv"
printf 'demo\t1\ttrunk-v1\t%s\t1400\n' "$base1" >"$D/trunk-versions.tsv"
# the lander already logged one move of this run: the feed keeps it and adds no second one
printf '1100\tlanding\tlane1.%s\tchecking\tcheck-ok\tlanded\tcore/trunk-landing/trunk-landing.sh:run\n' "$head1" >"$MOVES"

"$FEED" 2>/dev/null || fail "the feed failed"
want="1010 landing enqueue
1030 landing start
1040 landing conflict
1050 landing conflict-resolved
1060 landing retest-ok
1030 lane-delivery t3-start
1100 lane-delivery t4-land
1200 lane-delivery t7-live
1300 release open
1400 release merge"
got=$(awk -F'\t' -v h="$head1" 'NR > 1 { print $1, $2, $5 }' "$MOVES" | sort -n -s)
[ "$got" = "$(printf '%s\n' "$want" | sort -n -s)" ] || fail "the moves are wrong: $got"
[ "$(awk -F'\t' '$5 == "check-ok"' "$MOVES" | wc -l)" -eq 1 ] || fail "the lander's own move was written twice"
pass "each record becomes its move with its own time; the lander's own move stays single"

while IFS=$'\t' read -r _ machine _ from event to writer; do
  tab=$ROOT/core/machines/tables/$machine.tsv
  awk -F'\t' -v f="$from" -v e="$event" -v t="$to" '$1 == "edge" && $2 == f && $3 == e && $4 == t { ok = 1 } END { exit !ok }' "$tab" ||
    awk -F'\t' -v f="$from" -v e="$event" -v t="$to" '$1 == "edge" && $3 == e && $4 == t { ok = 1 } END { exit !ok }' "$tab" ||
    fail "$machine $from $event $to is no edge of its table"
  case $writer in feed:landing-release | core/trunk-landing/*) ;; *) fail "unexpected writer $writer" ;; esac
done <"$MOVES"
pass "every move is an edge of its machine's table"

before=$(cksum <"$MOVES")
"$FEED" 2>/dev/null || fail "the second run failed"
[ "$(cksum <"$MOVES")" = "$before" ] || fail "a second run changed the log"
pass "a second run adds nothing"

n=$(wc -l <"$MOVES"); "$FEED" --dry-run >/dev/null 2>&1; [ "$(wc -l <"$MOVES")" -eq "$n" ] || fail "--dry-run wrote"
pass "--dry-run writes nothing"
