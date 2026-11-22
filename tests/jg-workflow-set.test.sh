#!/usr/bin/env bash
# jg-workflow-set: a ticket carries its workflow in its own row and one child row per step, each stage blocked by the one before,
# and every step row passes the brief gate and the build guard. Real bin/jg-workflow.sh set|show over a scratch home whose
# backlog is the ticket tables, and the real guard_captain_ask_build of bin/jg-captain-ask-lib.sh.
#
# T1 `set` files one row per step, each stage blocked by every row of the stage before, and writes the record on the ticket.
# T2 the same call again adopts every row: nothing is filed twice.
# T3 a workflow the owner named is changed only by the owner; a worker row is Recon-born and carries no owner-words line.
# T4 the owner changes it before any step starts: the old rows close as superseded and the new rows are filed.
# T5 a step with a lane record stops a new spec, and the refusal names the step.
# T6 every row names its parent and its owner order, the brief gate's two needs.
# T7 no order anywhere: refused, nothing filed.  T8 the order of the ticket's own body is inherited.
# T9 the build guard rests on the owner step that gates each worker: the ticket's own yes, a yes on the other owner step, and a
#    row of another ticket never open it; the yes on its own owner step, or on the rows that step's wf_approved_row names, does.
# T10 the subject changes at any time and changes no step; a long subject is refused.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v openssl >/dev/null 2>&1 || { echo "skip: openssl not found"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jg-workflow-set-test.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP"' EXIT
WF=$ROOT/bin/jg-workflow.sh
BD=(python3 -I "$ROOT/core/item-store/adapters/bd_compat.py")

# home <name>: a scratch home with one ticket, jg-t1, filed with the order in its body unless $2 says otherwise.
home() {
  local h=$TMP/$1
  jg_test_beads_home "$h"
  mkdir -p "$h/state"
  jg_test_add "$h" jg-t1 "[feature] Faster sign in" --body "${2-Owner order: Main42707.}"
  printf '%s\n' "$h"
}
wf() {  # <home> <args...>: res (stdout), err and wf_rc
  local h=$1; shift
  res=$(JG_HOME=$h "$WF" "$@" 2>"$TMP/err"); wf_rc=$?
  err=$(cat "$TMP/err")
}
meta() { JG_HOME=$1 "${BD[@]}" show "$2" --json | jq -r --arg k "$3" '.[0].metadata[$k] // ""'; }
body() { JG_HOME=$1 "${BD[@]}" show "$2" --json | jq -r '.[0].description'; }
status() { JG_HOME=$1 "${BD[@]}" show "$2" --json | jq -r '.[0].status'; }
deps() { JG_HOME=$1 "${BD[@]}" show "$2" --json | jq -r '[.[0].dependencies[]? | select(.dependency_type == "blocks" or .type == "blocks") | (.id // .depends_on_id)] | sort | join(" ")'; }
steps() { JG_HOME=$1 "${BD[@]}" list --parent jg-t1 --all --limit 0 --json | jq -r --arg k "$2" '[.[] | select(.metadata.wf_kind == $k) | .id] | sort | join(" ")'; }
count() { JG_HOME=$1 "${BD[@]}" list --parent jg-t1 --all --limit 0 --json | jq 'length'; }
# row <home> <stage> <index>: the row id of a step
row() { JG_HOME=$1 "${BD[@]}" list --parent jg-t1 --all --limit 0 --json | jq -r --arg s "$2" --arg i "$3" '.[] | select(.metadata.wf_stage == $s and .metadata.wf_index == $i) | .id'; }
append_line() {  # <home> <row> <line>: add a line to the row's body
  local b
  b=$(body "$1" "$2")
  JG_HOME=$1 "${BD[@]}" update "$2" --description "$b"$'\n'"$3" >/dev/null || fail "could not write a line on $2"
}
# sign <home> <row> <ref>: write the owner's signed approval line on the row, as bin/jg-captain-hold.sh answer does
sign() {
  local line
  line=$(STATE=$1/state bash -c 'fail() { echo "$*" >&2; exit 1; }; . "$1/bin/jg-captain-ask-lib.sh" && captain_ask_approval_line "$2" "$3"' _ "$ROOT" "$2" "$3") \
    || fail "could not sign $2"
  append_line "$1" "$2" "$line"
}
# guard <home> <row>: the real build guard; its refusal text on stdout
guard() {
  ( # shellcheck disable=SC2034
    JG_HOME=$1 STATE=$1/state DATA=$1/data SCRIPT_DIR=$ROOT/bin
    # shellcheck disable=SC2329
    fail() { echo "$*"; exit 1; }
    # shellcheck source=bin/jg-backlog-transition-lib.sh disable=SC1091
    . "$ROOT/bin/jg-backlog-transition-lib.sh"
    # shellcheck source=bin/jg-captain-ask-lib.sh disable=SC1091
    . "$ROOT/bin/jg-captain-ask-lib.sh"
    guard_captain_ask_build "$2" 2>&1 )
}

SPEC='scout*2 > owner > worker*2'
CANON='recon(quick)*2 > owner(plan-approval) > worker*2'

# T1, T2, T6
H=$(home t1)
wf "$H" set jg-t1 "$SPEC" --by main --order Main42707
expect_code 0 "$wf_rc" "T1 set: $err"
assert_contains "$res" "on jg-t1: 5 steps (5 new)" "T1 the summary line"
assert_equals 5 "$(count "$H")" "T1 five step rows"
assert_equals "$CANON" "$(meta "$H" jg-t1 workflow)" "T1 the canonical spec is on the ticket"
r1=$(row "$H" 1 1); r2=$(row "$H" 1 2); o=$(row "$H" 2 1); w1=$(row "$H" 3 1); w2=$(row "$H" 3 2)
assert_equals "$r1 $r2" "$(deps "$H" "$o" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" "T1 the owner row waits for both scouts"
assert_equals "$o" "$(deps "$H" "$w1")" "T1 the first worker waits for the owner row"
assert_equals "$o" "$(deps "$H" "$w2")" "T1 the second worker waits for the owner row"
assert_equals "" "$(deps "$H" "$r1")" "T1 the first stage waits for nothing"
for f in workflow_name workflow_sha workflow_by workflow_order workflow_at; do
  [ -n "$(meta "$H" jg-t1 $f)" ] || fail "T1 the ticket has no $f"
done
assert_equals Main42707 "$(meta "$H" jg-t1 workflow_order)" "T1 the order"
assert_equals worker "$(meta "$H" "$w1" wf_kind)" "T1 wf_kind"
assert_equals "$o" "$(meta "$H" "$w1" wf_gate)" "T1 the worker row names its gate"
before=$(count "$H")
wf "$H" set jg-t1 "$SPEC" --by main --order Main42707
expect_code 0 "$wf_rc" "T2 the same call: $err"
assert_contains "$res" "(0 new)" "T2 nothing new"
assert_equals "$before" "$(count "$H")" "T2 still five rows"
assert_equals "$w1" "$(row "$H" 3 1)" "T2 the same ids"
for r in "$r1" "$r2" "$o" "$w1" "$w2"; do
  assert_contains "$(body "$H" "$r")" "parent: jg-t1" "T6 $r names its parent"
  assert_contains "$(body "$H" "$r")" "Owner order: Main42707." "T6 $r names the order"
done
wf "$H" show jg-t1
expect_code 0 "$wf_rc" "T1 show: $err"
assert_contains "$res" "stage 3 worker $w1 open task ${w1//./-} no lane" "T1 show lists a step with no lane"
assert_contains "$(JG_HOME=$H "$WF" show jg-t1 --json)" '"steps"' "T1 show --json"
pass "T1 T2 T6 a ticket carries its workflow and one blocked row per step; a second call adopts them"

# T3, T4
H=$(home t3)
wf "$H" set jg-t1 "$SPEC" --by owner --quote "two scouts then two workers" --note n1
expect_code 0 "$wf_rc" "T3 owner set: $err"
wf "$H" set jg-t1 worker --by main
expect_code 2 "$wf_rc" "T3 main changing the owner's workflow"
assert_contains "$err" 'the owner named this workflow: "two scouts then two workers"' "T3 the refusal quotes the owner"
assert_equals 5 "$(count "$H")" "T3 rows unchanged"
assert_equals "$CANON" "$(meta "$H" jg-t1 workflow)" "T3 the record is unchanged"
for r in $(steps "$H" worker); do
  assert_contains "$(body "$H" "$r")" "born-from: recon" "T3 a worker row is Recon-born"
  assert_not_contains "$(body "$H" "$r")" "owner-words" "T3 no owner-words line"
done
wf "$H" set jg-t1 'scout > owner > worker' --by owner
expect_code 2 "$wf_rc" "T3 --by owner needs his words"
wf "$H" set jg-t1 worker --by owner --quote "just one worker" --note n2
expect_code 0 "$wf_rc" "T4 owner changes it: $err"
assert_contains "$res" "1 steps (1 new)" "T4 one row is filed"
open=0
for r in $(JG_HOME=$H "${BD[@]}" list --parent jg-t1 --all --limit 0 --json | jq -r '.[].id'); do
  s=$(status "$H" "$r")
  if [ "$(meta "$H" "$r" wf_superseded)" != "" ]; then assert_equals closed "$s" "T4 $r is closed"; else open=$((open + 1)); fi
done
assert_equals 1 "$open" "T4 one live step row"
assert_contains "$(JG_HOME=$H "${BD[@]}" show "$(steps "$H" recon | cut -d' ' -f1)" --json)" "superseded by workflow" "T4 the close reason"
pass "T3 T4 the owner's workflow is changed only by the owner, and an unstarted one is superseded"

# T5
H=$(home t5)
wf "$H" set jg-t1 "$SPEC" --by main
expect_code 0 "$wf_rc" "T5 set: $err"
r1=$(row "$H" 1 1)
: > "$H/state/${r1//./-}.meta"
wf "$H" set jg-t1 'worker' --by main
expect_code 2 "$wf_rc" "T5 a new spec after a start"
assert_contains "$err" "$r1" "T5 the refusal names the started step"
assert_equals 5 "$(count "$H")" "T5 nothing changed"
assert_equals "$CANON" "$(meta "$H" jg-t1 workflow)" "T5 the record is unchanged"
wf "$H" set jg-t1 "$SPEC" --by main
expect_code 0 "$wf_rc" "T5 the same spec is still adopted: $err"
pass "T5 a started step keeps its workflow"

# T7, T8
H=$(home t7 "No order here.")
wf "$H" set jg-t1 worker --by main
expect_code 2 "$wf_rc" "T7 no order"
assert_contains "$err" "refused: no owner order" "T7 the refusal"
assert_equals 0 "$(count "$H")" "T7 nothing filed"
H=$(home t8 $'Words first.\nBuild it for Main42707 please.')
wf "$H" set jg-t1 worker --by main
expect_code 0 "$wf_rc" "T8 the body's order: $err"
assert_contains "$(body "$H" "$(row "$H" 1 1)")" "Owner order: Main42707." "T8 inherited"
pass "T7 T8 the owner order is passed, inherited from the ticket's body, or refused"

# T9
H=$(home t9)
wf "$H" set jg-t1 'scout > owner > worker > scout > owner > worker' --by main
expect_code 0 "$wf_rc" "T9 set: $err"
o1=$(row "$H" 2 1); w1=$(row "$H" 3 1); o2=$(row "$H" 5 1); w2=$(row "$H" 6 1)
assert_contains "$(body "$H" "$w1")" "plan-approved-on: $o1" "T9 the first worker names its owner row"
assert_contains "$(body "$H" "$w2")" "plan-approved-on: $o2" "T9 the second worker names its owner row"
out=$(guard "$H" "$w1"); rc=$?
expect_code 1 "$rc" "T9 an unapproved worker is refused"
assert_contains "$out" "no record of the captain's yes" "T9 the guard's text"
sign "$H" jg-t1 note:t1
out=$(guard "$H" "$w1"); rc=$?
expect_code 1 "$rc" "T9 the yes on the ticket does not open the first worker: $out"
out=$(guard "$H" "$w2"); rc=$?
expect_code 1 "$rc" "T9 the yes on the ticket does not open the second worker: $out"
sign "$H" "$o1" note:o1
out=$(guard "$H" "$w1"); rc=$?
expect_code 0 "$rc" "T9 the yes on its own owner row opens the first worker: $out"
out=$(guard "$H" "$w2"); rc=$?
expect_code 1 "$rc" "T9 the first yes does not open the second worker: $out"
sign "$H" "$o2" note:o2
out=$(guard "$H" "$w2"); rc=$?
expect_code 0 "$rc" "T9 the yes on the second owner row opens the second worker: $out"
# a worker that names an approved row of another ticket
jg_test_add "$H" jg-t2 "[feature] Other work" --body "Owner order: Main42707."
other=$(JG_HOME=$H "$ROOT/bin/jg-backlog.sh" add --parent jg-t2 "Other owner row" --repo demo --priority 2 --body $'parent: jg-t2\nOwner order: Main42707.' --json | jq -r '.task.id // .id')
sign "$H" "$other" note:x
b=$(body "$H" "$w1")
JG_HOME=$H "${BD[@]}" update "$w1" --description "${b//plan-approved-on: $o1/plan-approved-on: $other}" >/dev/null
out=$(guard "$H" "$w1"); rc=$?
expect_code 1 "$rc" "T9 an approved row of another ticket does not open a worker: $out"
# a stand-in council row of the same parent named by wf_approved_row
stand=$(JG_HOME=$H "$ROOT/bin/jg-backlog.sh" add --parent jg-t1 "Council stand in" --repo demo --priority 2 --body $'parent: jg-t1\nOwner order: Main42707.' --json | jq -r '.task.id // .id')
sign "$H" "$stand" note:s
JG_HOME=$H "${BD[@]}" update "$w1" --description "$b" >/dev/null
o1b=$(row "$H" 2 1)
JG_HOME=$H "${BD[@]}" update "$o1b" --set-metadata "wf_approved_row=$stand" >/dev/null
out=$(guard "$H" "$w1"); rc=$?
expect_code 0 "$rc" "T9 wf_approved_row names a stand-in row that carries its own yes: $out"
JG_HOME=$H "${BD[@]}" update "$o1b" --set-metadata "wf_approved_row=jg-nowhere" >/dev/null
out=$(guard "$H" "$w1"); rc=$?
expect_code 1 "$rc" "T9 an unreadable approved row refuses"
assert_contains "$out" "jg-nowhere" "T9 the refusal names the row"
pass "T9 each worker's build rests on the yes of the owner step that gates it"

# T10
H=$(home t10)
wf "$H" set jg-t1 "$SPEC" --by main
r1=$(row "$H" 1 1)
: > "$H/state/${r1//./-}.meta"
wf "$H" set jg-t1 --subject "the faster sign in" --by main
expect_code 0 "$wf_rc" "T10 subject after a start: $err"
assert_equals "the faster sign in" "$(meta "$H" jg-t1 workflow_subject)" "T10 the subject is written"
assert_equals 5 "$(count "$H")" "T10 every row unchanged"
wf "$H" set jg-t1 --subject "one two three four five six seven eight nine"
expect_code 2 "$wf_rc" "T10 nine words"
assert_equals "the faster sign in" "$(meta "$H" jg-t1 workflow_subject)" "T10 the subject is kept"
pass "T10 the subject changes at any time and changes no step"
