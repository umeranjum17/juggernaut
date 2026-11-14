#!/usr/bin/env bash
# Behavior tests for bin/jg-machine.sh: a machine table, one command for a state and its legal moves.
# The fixture machine is generated here by seed_table; no fleet record is copied. Each lint defect has its
# own failing table, show/next/check match golden output, and the AX proof reads only `next` output,
# runs the command it names, and asserts the state moved to the `to` it listed.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine); mkdir -p "$T/tables" "$T/rec"
export JG_MACHINES_TABLES="$T/tables"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
jm() { OUT=$(bash "$JM" "$@" 2>&1); RC=$?; }

seed_table() {  # <file>: a three-state document machine whose records are files under $T/rec
  { tab machine doc "files in $T/rec" tests/jg-machine.test.sh
    tab state draft initial "A draft is being written." body
    tab state review normal "The draft waits for a reviewer." body,reviewer
    tab state published terminal "The draft is published." -
    tab edge draft submit review author:submit "printf review > $T/rec/{id}" "the author finishes" t-submit
    tab edge review approve published reviewer:approve "printf published > $T/rec/{id}" "a reviewer agrees" t-approve
    tab edge review reject draft reviewer:reject "printf draft > $T/rec/{id}" "a reviewer disagrees" t-reject
    tab observer "cat $T/rec/\$1 2>/dev/null"; } > "$1"
}
seed_table "$T/tables/doc.tsv"; printf draft > "$T/rec/a1"

defect() {  # <name> <expected text> <line to append>: the table breaks one rule and check refuses it
  seed_table "$T/tables/bad.tsv"; printf '%s\n' "$3" >> "$T/tables/bad.tsv"
  jm check bad; expect_code 1 "$RC" "lint should refuse: $1"; assert_contains "$OUT" "$2" "lint should name: $1"
}
defect "an unreachable state" "unreachable state orphan" "$(tab state orphan normal "Nobody gets here." -)"
defect "an exit edge from a terminal state" "terminal state published has an exit edge" "$(tab edge published reopen draft w:f c g t)"
defect "a duplicate (from, event)" "duplicate edge draft submit" "$(tab edge draft submit published w:f c g t)"
defect "an edge with no writer" "edge draft skip has no writer" "$(tab edge draft skip review - c g t)"
defect "a state with no captain sentence" "state lost has no captain sentence" "$(tab state lost normal "" -)"
pass "lint refuses each defect of rule 3"

jm show doc a1; expect_code 0 "$RC" "show"
assert_equals "$(printf 'machine\tdoc\nid\ta1\nstate\tdraft\nkind\tinitial\nsentence\tA draft is being written.\nrequires\tbody')" "$OUT" "show golden"
jm next doc a1
assert_equals "$(printf 'machine\tdoc\nid\ta1\nstate\tdraft\nmoves\t1\nmove\tsubmit\treview\tauthor:submit\tprintf review > %s/rec/a1\tthe author finishes' "$T")" "$OUT" "next golden"
jm show doc nope; expect_code 1 "$RC" "a record in no state"; assert_contains "$OUT" "no state" "show names the missing state"
pass "show and next match golden output"

printf '%s\n' draft "$(tab draft submit review)" "$(tab review approve published)" > "$T/ok.corpus"
printf '%s\n' "$(tab draft submit published)" ghost > "$T/bad.corpus"; tab doc "$(tab draft submit published)" > "$T/tables/known-baseline.tsv"
jm check doc --corpus "$T/ok.corpus"; expect_code 0 "$RC" "a legal corpus"; assert_equals "ok doc: 3 lines, 0 findings" "$OUT" "check golden"
jm check doc --corpus "$T/bad.corpus"; expect_code 1 "$RC" "an illegal corpus"
assert_equals "$(printf 'baseline doc corpus:1: draft submit published\nbad doc corpus:2: ghost is not a state\nfail doc: 2 lines, 1 findings')" "$OUT" "check names line and baseline"
pass "check matches golden output and honours the baseline"

# AX proof: only `next` output is read; the named command is run; the state lands on the listed `to`.
for _ in 1 2 3 4; do
  jm next doc a1; [ "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="moves"{print $2}')" != 0 ] || break
  want=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="move"{print $3; exit}')
  cmd=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="move"{print $5; exit}')
  bash -c "$cmd"; jm show doc a1
  assert_equals "$want" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="state"{print $2}')" "the state moved to the listed to"
done
assert_equals published "$(cat "$T/rec/a1")" "the walk reached the terminal state"
pass "AX: next names the command and the move lands on its to"

# SM1b: coverage names an edge with no test, diagram is generated from the table, edge-check answers one move.
jm coverage doc; expect_code 0 "$RC" "every edge has a test"; assert_equals "ok doc: 3 edges, 0 untested" "$OUT" "coverage golden"
{ cat "$T/tables/doc.tsv"; tab edge draft withdraw draft author:withdraw - "the author changes mind" -; } > "$T/tables/cov.tsv"
jm coverage cov; expect_code 1 "$RC" "an untested edge"
assert_equals "$(printf 'untested cov draft withdraw draft\nfail cov: 4 edges, 1 untested')" "$OUT" "coverage names the edge"
pass "coverage matches golden output"
jm diagram doc --dot wide; expect_code 0 "$RC" "diagram"
assert_equals "$(printf '%s\n' 'digraph "doc" {' \
  '  rankdir=LR; compound=true; newrank=true; nodesep=0.28; ranksep=0.5; bgcolor="transparent"; fontname="Helvetica"; fontsize=10;' \
  '  node [shape=box, style="rounded", fontname="Helvetica", fontsize=12, margin="0.10,0.05", height=0.36];' \
  '  edge [fontname="Helvetica", fontsize=11, arrowsize=0.7];' \
  '  "__init" [shape=circle, style=filled, fillcolor=black, label="", width=0.16, height=0.16, fixedsize=true, class="init"];' \
  '  "draft" [class="ka"];' '  "review" [class="ka"];' '  "published" [class="kf", label="◎ published"];' \
  '  "draft" -> "review" [label=" submit\n[the author finishes] ", id="e0_submit"];' \
  '  "review" -> "published" [label=" approve\n[a reviewer agrees] ", id="e1_approve"];' \
  '  "review" -> "draft" [label=" reject\n[a reviewer disagrees] ", id="e2_reject"];' \
  '  "__init" -> "draft";' '}')" "$OUT" "diagram golden"
pass "diagram prints the dot text of the table: an initial dot, a ring on the final state, event and guard on each arrow"
jm edge-check doc review published; expect_code 0 "$RC" "a legal move"; assert_equals "$(printf 'legal doc review published\tapprove\treviewer:approve')" "$OUT" "edge-check legal golden"
jm edge-check doc draft published; expect_code 1 "$RC" "an illegal move"; assert_equals "illegal doc draft published" "$OUT" "edge-check illegal golden"
jm edge-check doc draft nowhere; expect_code 1 "$RC" "a move to a state the table lacks"; assert_contains "$OUT" "nowhere is not a state" "edge-check names the missing state"
jm edge-check doc draft; expect_code 2 "$RC" "edge-check needs from and to"
pass "edge-check matches golden output"
