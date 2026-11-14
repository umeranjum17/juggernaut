#!/usr/bin/env bash
# The captain-hold writer reports its moves to the one move log (data/machine-moves.log): a hold writes held, an answer writes answered and
# closed, so held -> answered has a time; a diverged call and its reconcile are reported once. Every record is made through the real
# bin/jg-captain-hold.sh over a real Beads store; the log is read as written.
# shellcheck source=tests/jg-machine-hold-fixture.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/jg-machine-hold-fixture.sh"
MOVES=$HOME_DIR/data/machine-moves.log SHADOW=$HOME_DIR/data/machine-shadow.log
moves_of() { awk -F'\t' -v id="$1" '$2 == "hold" && $3 == id { printf "%s>%s ", $4, $6 }' "$MOVES" 2>/dev/null | sed 's/ $//'; }
printf 'Use the first sample option.\n' > "$T/answer.txt"

hold hold m-ans --title "Choose the sample option for m-ans" --reason "$reason" --repo sample >/dev/null || fail "seed m-ans"
assert_equals "(none)>raised" "$(moves_of m-ans)" "a hold reports held"
hold answer m-ans --decision-file "$T/answer.txt" >/dev/null || fail "answer m-ans"
assert_equals "(none)>raised raised>answered answered>closed" "$(moves_of m-ans)" "an answer reports answered and closed"
epochs=$(awk -F'\t' '$3 == "m-ans" { print $1 }' "$MOVES")
for e in $epochs; do case "$e" in '' | *[!0-9]*) fail "a move line has no time: $e" ;; esac; done
pass "held -> answered is two lines of the move log, each with a time"

hold hold m-rel --title "Choose the sample option for m-rel" --reason "$reason" --repo sample >/dev/null || fail "seed m-rel"
hold answer m-rel --decision-file "$T/answer.txt" --release >/dev/null || fail "release m-rel"
assert_equals "(none)>raised raised>closed" "$(moves_of m-rel)" "a released answer reports closed"
hold hold m-later --title "Choose the sample option for m-later" --reason "$reason" --repo sample --until 2099-01-01 >/dev/null || fail "seed m-later"
assert_equals "(none)>raised raised>deferred" "$(moves_of m-later)" "a dated hold reports raised, then deferred"
pass "a release and a dated hold report their own moves"

hold hold m-div --title "Choose the sample option for m-div" --reason "$reason" --repo sample >/dev/null || fail "seed m-div"
printf 'needs-decision [key=m-div]: choose the sample option\nresolved [key=m-div]: answered: first option\n' > "$HOME_DIR/state/m-origin.status"
hold diverged >/dev/null; hold diverged >/dev/null
assert_equals "(none)>raised raised>diverged" "$(moves_of m-div)" "a diverged call is reported once, however often it is listed"
pass "a diverged call is reported once"

[ ! -s "$SHADOW" ] || fail "a writer report reached the shadow log: $(cat "$SHADOW")"
pass "no report was an illegal move"
