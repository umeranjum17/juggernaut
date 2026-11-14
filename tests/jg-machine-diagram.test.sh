#!/usr/bin/env bash
# Behavior tests for the diagram command of bin/jg-machine.sh (slice J30): Graphviz draws a machine in the notation of section 6.12, in a
# wide and a narrow layout, and the chart check fails on a crossing arrow, an arrow with no arrowhead, a label off its plate, labels that
# overlap, a label on a state and a narrow layout over 450 pt. The table also gets two columns for each state (what it emits and to which
# machine, and the alert of its timeout), read by `escalation`.
#
# The checks that need only Python (the check on SVG fixtures, the table columns, the dot text, the missing renderer) always run. The checks
# that draw need @viz-js/viz (toolchain.versions pins it; JG_VIZ_DIR names a folder that holds it): without it they print a SKIP line, and
# with JG_DIAGRAM_REQUIRE=1 (the machine-diagram journey) their absence is a failure. JG_DIAGRAM_OUT keeps the drawn charts in that folder.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

JM="$ROOT/bin/jg-machine.sh"
T=$(jg_test_tmproot jg-machine-diagram); mkdir -p "$T/tables" "$T/svg"
tab() { local IFS=$'\t'; printf '%s\n' "$*"; }
jm() { OUT=$(JG_MACHINES_TABLES="${TABLES:-$T/tables}" bash "$JM" "$@" 2>&1); RC=$?; }

# --- the table columns: emits, and the alert of a timeout --------------------------------------------------------------------------------
seed() {  # <file> <emits> <alert>: a three-state machine whose waiting state carries the two new columns
  { tab machine job "jobs" tests/jg-machine-diagram.test.sh
    tab state new initial "Filed." -
    tab state wait normal "Waiting for a lane." - waiting "10m -> alert ready-idle" "$2" "$3"
    tab state "done" terminal "Finished." -
    tab edge '(none)' file new w:f - "a job is filed" t
    tab edge new queue wait w:f - "a lane is asked for" t
    tab edge wait finish "done" w:f - "the lane is done" t
    tab observer "echo new"; } > "$1"
}
seed "$T/tables/job.tsv" - ready-idle
jm check job; expect_code 0 "$RC" "a timeout that names an alert of the alert table passes"
pass "a timeout that names an alert of the alert table passes"

seed "$T/tables/bad.tsv" - -; sed -i 's/alert ready-idle/alert no-such-alert/' "$T/tables/bad.tsv"
jm check bad; expect_code 1 "$RC" "a timeout that names no alert of the alert table must fail"
assert_contains "$OUT" "state wait has a timeout that names the alert no-such-alert, which is not in the alert table" "the lint names the state and the alert"
assert_contains "$OUT" "legal: security line-red" "the lint lists the alerts of the alert table"
pass "a state whose timeout names no alert of the alert table fails, naming the state and the alert"

seed "$T/tables/bad.tsv" - drift
jm check bad; expect_code 1 "$RC" "an alert column that disagrees with the timeout must fail"
assert_contains "$OUT" "state wait names the alert drift, but its timeout is '10m -> alert ready-idle'" "the lint names the disagreement"
seed "$T/tables/bad.tsv" - not-an-alert
jm check bad; expect_code 1 "$RC" "an alert column with no such alert must fail"
assert_contains "$OUT" "state wait names the alert not-an-alert, which is not in the alert table" "the lint names the unknown alert"
pass "the alert column must agree with the timeout and name an alert of the table"

cp "$T/tables/job.tsv" "$T/tables/other.tsv"; sed -i 's/^machine\tjob/machine\tother/' "$T/tables/other.tsv"
seed "$T/tables/bad.tsv" queue@job -
jm check bad; expect_code 0 "$RC" "an emit of an event the other machine has must pass"
seed "$T/tables/bad.tsv" nothing@job -
jm check bad; expect_code 1 "$RC" "an emit of an event the other machine lacks must fail"
assert_contains "$OUT" "state wait emits nothing to the machine job, which has no such event" "the lint names the missing event"
seed "$T/tables/bad.tsv" queue@ghost -
jm check bad; expect_code 1 "$RC" "an emit to a machine with no table must fail"
assert_contains "$OUT" "state wait emits queue to the machine ghost, which has no table" "the lint names the missing machine"
seed "$T/tables/bad.tsv" queue -
jm check bad; expect_code 1 "$RC" "an emit that is not event@machine must fail"
assert_contains "$OUT" "state wait emits 'queue', which is not <event>@<machine>" "the lint names the bad form"
pass "the emits column names an event that the receiving machine has"

TABLES=$ROOT/core/machines/tables jm escalation ticket; expect_code 0 "$RC" "escalation reads the shipped ticket table"
assert_contains "$OUT" "$(printf 'ready\twaiting\t-\t10m -> alert ready-idle\tready-idle\tthe lead\tMain\tnever')" "ready: ready-idle tells the lead, then Main, and no board card"
assert_contains "$OUT" "$(printf 'released\twaiting\t-\t10m -> alert drift\tdrift\tthe lead\tMain\twhen owner-answer')" "released: drift tells the lead, then Main"
pass "escalation prints who is told first, next, and by a board card"

# --- the dot text ----------------------------------------------------------------------------------------------------------------------
TABLES=$ROOT/core/machines/tables jm diagram ticket --dot wide; expect_code 0 "$RC" "the dot text of the ticket"
assert_contains "$OUT" 'class="init"' "an initial dot"
assert_contains "$OUT" '"closed" [class="kf", label="◎ closed"]' "a ring on a final state"
assert_contains "$OUT" '"proving" [class="ka", label="proving\n(proving inside)"]' "a composite stage is one box that names its inner machine"
assert_contains "$OUT" 'label=" start' "an event on each arrow"
assert_contains "$OUT" 'label=" start\n[a lane is free and the]\n[spawn…] "' "the guard follows the event in brackets, cut to its first words"
assert_contains "$OUT" 'subgraph "cluster_open"' "a group is a dashed cluster"
assert_contains "$OUT" 'ltail="cluster_open"' "an arrow that leaves a group leaves its cluster"
case "$OUT" in *'"proving.planned"'*) fail "a state inside a composite stage is drawn in the chart of its own table" ;; esac
pass "diagram --dot prints the notation of section 6.12"

# --- the chart check on SVG fixtures: no renderer needed --------------------------------------------------------------------------------
svg() {  # <file> <width pt> <edges...> -- <labels...>: a chart with two boxes and the pieces named
  local f=$1 w=$2; shift 2; local edges=() labels=() mode=e x
  for x in "$@"; do [ "$x" != -- ] && { if [ "$mode" = e ]; then edges+=("$x"); else labels+=("$x"); fi; continue; }; mode=l; done
  { printf '<svg width="%spt" height="200pt" viewBox="0 0 %s 200">\n<g id="graph0" class="graph">\n' "$w" "$w"
    printf '<g id="node1" class="node"><title>a</title><polygon points="0,10 40,10 40,40 0,40"/></g>\n<g id="node2" class="node"><title>b</title><polygon points="100,150 140,150 140,190 100,190"/></g>\n'
    printf '%s\n' "${edges[@]}"
    printf '<g class="labels">\n%s\n</g>\n</g>\n</svg>\n' "$(printf '%s' "${labels[@]}")"; } > "$f"
}
edge() { printf '<g id="e%s_%s" class="edge"><title>%s</title><path d="M%s"/>%s</g>' "$1" "$2" "$3" "$4" "${5-<polygon points=\"1,1 2,2 3,1\"/>}"; }
label() { printf '<g class="label"><rect class="plate pe" x="%s" y="%s" width="%s" height="%s"/><text x="%s" y="%s" font-size="11" text-anchor="middle">%s</text></g>' "$1" "$2" "$3" "$4" "$(($1 + $3 / 2))" "$(($2 + 9))" "$5"; }
E1=$(edge 0 go 'a&#45;&gt;b' '20,40 20,90 100,100 120,150')
E2=$(edge 1 stop 'b&#45;&gt;a' '120,150 90,100 30,90 20,40')
X1=$(edge 0 left 'a&#45;&gt;b' '10,40 10,40 130,150 130,150')
X2=$(edge 1 right 'a&#45;&gt;b' '130,40 130,40 20,140 20,140')
svg "$T/svg/ok-LR.svg" 300 "$E1" "$E2" -- "$(label 60 60 40 12 go)" "$(label 200 60 40 12 stop)"
jm chart-check "$T/svg/ok-LR.svg"; expect_code 0 "$RC" "a clean chart passes: $OUT"
svg "$T/svg/cross-LR.svg" 300 "$X1" "$X2" -- "$(label 60 60 40 12 left)" "$(label 200 60 40 12 right)"
jm chart-check "$T/svg/cross-LR.svg"; expect_code 1 "$RC" "two crossing arrows must fail"
assert_contains "$OUT" "the arrows left (a->b) and right (a->b) cross" "the check names the two arrows"
svg "$T/svg/head-LR.svg" 300 "$(edge 0 go 'a&#45;&gt;b' '20,40 20,90 100,100 120,150' '')" -- "$(label 60 60 40 12 go)"
jm chart-check "$T/svg/head-LR.svg"; expect_code 1 "$RC" "an arrow with no arrowhead must fail"
assert_contains "$OUT" "the arrow go (a->b) has no arrowhead" "the check names the arrow with no head"
svg "$T/svg/plate-LR.svg" 300 "$(edge 0 go 'a&#45;&gt;b' '20,40 20,90 100,100 120,150' '<polygon points="1,1 2,2 3,1"/><text x="60" y="70" font-size="11">go</text>')" --
jm chart-check "$T/svg/plate-LR.svg"; expect_code 1 "$RC" "a label off its plate must fail"
assert_contains "$OUT" "the label of go (a->b) is not on its plate in the top layer" "the check names the label"
svg "$T/svg/noplate-LR.svg" 300 "$E1" -- '<g class="label"><text x="60" y="70" font-size="11">go</text></g>'
jm chart-check "$T/svg/noplate-LR.svg"; expect_code 1 "$RC" "a label with no plate must fail"
assert_contains "$OUT" "a label has no plate" "the check says a label has no plate"
svg "$T/svg/over-LR.svg" 300 "$E1" "$E2" -- "$(label 60 60 40 12 go)" "$(label 70 62 40 12 stop)"
jm chart-check "$T/svg/over-LR.svg"; expect_code 1 "$RC" "two overlapping labels must fail"
assert_contains "$OUT" "the labels 'go' and 'stop' overlap" "the check names the two labels"
svg "$T/svg/onstate-LR.svg" 300 "$E1" -- "$(label 10 15 40 12 go)"
jm chart-check "$T/svg/onstate-LR.svg"; expect_code 1 "$RC" "a label on a state must fail"
assert_contains "$OUT" "the label 'go' overlaps the state a" "the check names the label and the state"
svg "$T/svg/wide-TB.svg" 451 "$E1" -- "$(label 60 60 40 12 go)"
jm chart-check "$T/svg/wide-TB.svg"; expect_code 1 "$RC" "a narrow layout over 450 wide must fail"
assert_contains "$OUT" "the narrow layout is 451 wide, over 450" "the check names the width"
svg "$T/svg/narrow-TB.svg" 450 "$E1" -- "$(label 60 60 40 12 go)"
jm chart-check "$T/svg/narrow-TB.svg"; expect_code 0 "$RC" "a narrow layout of 450 passes: $OUT"
svg "$T/svg/wide-LR.svg" 1500 "$E1" -- "$(label 60 60 40 12 go)"
jm chart-check "$T/svg/wide-LR.svg"; expect_code 0 "$RC" "a wide layout has no width limit: $OUT"
pass "the chart check fails on each of its six faults and names them"

# --- the renderer ------------------------------------------------------------------------------------------------------------------------
mkdir -p "$T/nonpm"; printf '#!/bin/sh\necho %s/none\n' "$T" > "$T/nonpm/npm"; chmod +x "$T/nonpm/npm"
OUT=$(PATH="$T/nonpm:$PATH" JG_VIZ_DIR="$T/none" JG_MACHINES_TABLES="$ROOT/core/machines/tables" bash "$JM" diagram bypass --out "$T/x" 2>&1); RC=$?
expect_code 1 "$RC" "a missing renderer stops the command"
assert_contains "$OUT" "npm install -g @viz-js/viz@" "the refusal gives the pinned install line"
assert_contains "$OUT" "$(awk '$1=="viz"{print $2}' "$ROOT/toolchain.versions")" "the install line is the version toolchain.versions pins"
[ ! -e "$T/x" ] || [ -z "$(ls "$T/x")" ] || fail "a refused drawing must write no chart"
pass "a missing renderer stops the command with the pinned install line"

have_viz() { PATH="$PATH" JG_VIZ_DIR="${JG_VIZ_DIR:-}" node -e "
const {execFileSync}=require('child_process');
const p=[process.env.JG_VIZ_DIR,(()=>{try{return execFileSync('npm',['root','-g'],{encoding:'utf8'}).trim()}catch(e){return null}})()].filter(Boolean);
require.resolve('@viz-js/viz',{paths:p})" >/dev/null 2>&1; }
if ! have_viz; then
  [ "${JG_DIAGRAM_REQUIRE:-}" != 1 ] || fail "the drawing checks need @viz-js/viz and JG_DIAGRAM_REQUIRE=1 is set: npm install -g $(awk '$1=="viz"{print $2}' "$ROOT/toolchain.versions")"
  printf 'SKIP - the drawing checks: @viz-js/viz is not installed (set JG_VIZ_DIR, or npm install -g %s)\n' "$(awk '$1=="viz"{print $2}' "$ROOT/toolchain.versions")"
  exit 0
fi

# --- drawing: a table whose arrows must cross fails, naming two arrows -------------------------------------------------------------------
{ tab machine knot "K3,3: three states each with an arrow to three others, which no drawing can keep apart" tests/jg-machine-diagram.test.sh
  tab state s0 initial "Filed." -
  for s in a b c; do tab state $s normal "Holds $s." -; done
  for s in x y z; do tab state $s terminal "Ends $s." -; done
  tab edge '(none)' file s0 w:f - "filed" t
  for s in a b c; do tab edge s0 "to-$s" $s w:f - "go $s" t; done
  for s in a b c; do for d in x y z; do tab edge $s "$s$d" $d w:f - "$s to $d" t; done; done
  tab observer "echo s0"; } > "$T/tables/knot.tsv"
jm diagram knot --out "$T/knot" --tries 24; expect_code 1 "$RC" "a table whose arrows must cross fails"
assert_contains "$OUT" "fail knot-LR.svg" "the wide layout fails"
if ! printf '%s\n' "$OUT" | grep -Eq 'chart knot-LR: the arrows [a-c][x-z] \([a-c]->[x-z]\) and [a-c][x-z] \([a-c]->[x-z]\) cross'; then fail "the fault names the two crossing arrows: $OUT"; fi
pass "a table whose arrows must cross fails with the two arrows named"

# --- drawing: every statechart table of the repository passes in both layouts ------------------------------------------------------------
OUTDIR=${JG_DIAGRAM_OUT:-$T/charts}
TABLES=$ROOT/core/machines/tables
n=0
for m in alert bypass delivering message presence proving release squad-lead supervision ticket worker; do
  jm diagram "$m" --out "$OUTDIR"; expect_code 0 "$RC" "the charts of $m pass the check: $OUT"
  n=$((n + 1))
done
for f in "$OUTDIR"/*-TB.svg; do
  w=$(sed -n 's/^<svg width="\([0-9]*\)pt".*/\1/p' "$f"); [ "$w" -le 450 ] || fail "$(basename "$f") is $w wide, over 450"
done
jm chart-check "$OUTDIR"/*.svg; expect_code 0 "$RC" "chart-check agrees on the files: $OUT"
[ "$(find "$OUTDIR" -name '*.svg' | wc -l)" = $((n * 2)) ] || fail "each machine has a wide and a narrow chart"
grep -q 'class="plate' "$OUTDIR/ticket-LR.svg" || fail "the labels of the ticket chart sit on plates"
printf '%s\n' "$OUT" > "$OUTDIR/chart-check.txt"
pass "the charts of $n statechart tables pass the check in a wide and a narrow layout"
