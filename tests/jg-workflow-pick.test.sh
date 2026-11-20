#!/usr/bin/env bash
# jg-workflow-pick: the owner's plain words become a workflow, and a ticket with none gets the default the pick lines of the
# workflows files name. Real bin/jg-workflow.sh words|define|pick|set over a scratch home whose backlog is the ticket tables.
#
# T1 `words` reads plain phrases into one canonical spec and tells the owner(plan-approval) it added.  T2 an unknown word is refused by name.
# T3 any order and any count, and a deep Recon always has its critic.  T4 a name the owner defines is a word at once.
# T5 `pick` follows the pick lines, and a home's pick lines replace the shipped ones.  T6 a ticket with the owner's record is kept.
# T7 `pick --set` files the rows and inherits the ticket's order, or refuses and files nothing.  T8 a pick rule that does not parse is refused.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jg-workflow-pick-test.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP"' EXIT
WF=$ROOT/bin/jg-workflow.sh
BD=(python3 -I "$ROOT/core/item-store/adapters/bd_compat.py")

# home <name> [<ticket title>] [<body>] [<lead>]: a scratch home with one ticket, jg-t1; a fourth argument makes it a Squad Lead home.
home() {
  local h=$TMP/$1
  jg_test_beads_home "$h"
  mkdir -p "$h/state"
  [ -z "${4-}" ] || printf 'crewhouse\n' > "$h/.jg-squad-lead-home"
  jg_test_add "$h" jg-t1 "${2-[feature] Faster sign in}" --body "${3-Owner order: Main42707.}"
  printf '%s\n' "$h"
}
wf() {  # <home> <args...>: res (stdout), err and rc
  local h=$1; shift
  res=$(JG_HOME=$h "$WF" "$@" 2>"$TMP/err"); rc=$?
  err=$(cat "$TMP/err")
}
meta() { JG_HOME=$1 "${BD[@]}" show "$2" --json | jq -r --arg k "$3" '.[0].metadata[$k] // ""'; }
count() { JG_HOME=$1 "${BD[@]}" list --parent jg-t1 --all --limit 0 --json | jq 'length'; }
# says <home> <words> <spec> <label>: the words read as the spec
says() {
  wf "$1" words "$2"
  expect_code 0 "$rc" "$4: $err"
  assert_equals "$3" "$res" "$4"
}

H=$(home t1)
# T1
says "$H" "2 scouts then 2 workers" 'recon(quick)*2 > owner(plan-approval) > worker*2' "T1 two scouts then two workers"
assert_equals "added: owner(plan-approval) before worker (owner rule 2026-11-05)" "$err" "T1 the added line"
says "$H" "war room then blitz" 'war-room(fast) > owner(plan-approval) > fanout' "T1 war room then blitz"
says "$H" "war room first and then go Blitz on it" 'war-room(fast) > owner(plan-approval) > fanout' "T1 the owner's own sentence"
assert_equals "" "$err" "T1 blitz brings its own approval"
says "$H" "deep recon then slices" 'recon(deep) > critic > owner(plan-approval) > fanout' "T1 deep recon then slices"
says "$H" "just a worker" 'worker' "T1 just a worker"
says "$H" "scout then worker" 'recon(quick) > owner(plan-approval) > worker' "T1 scout then worker"
pass "T1 plain words become a canonical spec"

# T2
wf "$H" words "two dragons"
expect_code 2 "$rc" "T2 an unknown word"
assert_contains "$err" 'I do not know "dragons"; I know:' "T2 the refusal names the word and lists the words"
assert_contains "$err" "war room" "T2 the list names the step words"
assert_contains "$err" "scout-worker" "T2 the list names the workflow names"
assert_equals "" "$res" "T2 nothing on stdout"
pass "T2 an unknown word is refused by name"

# T3
says "$H" "a worker then 3 scouts then my approval then 20 workers and 5 scouts" \
  'worker > recon(quick)*3 > owner(plan-approval) > worker*20 + recon(quick)*5' "T3 any order and count"
assert_equals "" "$err" "T3 no line added when the owner's yes is in the words"
says "$H" "war room then 2 workers then deep recon then slices" \
  'war-room(fast) > owner(plan-approval) > worker*2 > recon(deep) > critic > owner(plan-approval) > fanout' "T3 a build after a war room, then slices"
assert_equals "added: owner(plan-approval) before worker (owner rule 2026-11-05)" "$err" "T3 one line added: slices bring the second yes"
says "$H" "2 deep recons then slices" 'recon(deep)*2 > critic > owner(plan-approval) > fanout' "T3 two deep recons"
says "$H" "2 deep recons then a critic then slices" 'recon(deep)*2 > critic > owner(plan-approval) > fanout' "T3 a critic of the owner's own is not doubled"
pass "T3 any order and any count are covered"

# T4
H=$(home t4)
wf "$H" words "recon pair then 4 workers"
expect_code 2 "$rc" "T4 before the define"
assert_contains "$err" '"pair"' "T4 the refusal names pair"
wf "$H" define recon-pair 'scout*2' --by owner
expect_code 0 "$rc" "T4 define: $err"
says "$H" "recon pair then 4 workers" 'recon(quick)*2 > owner(plan-approval) > worker*4' "T4 a name the owner defined is a word"
says "$H" "recon-pair then 4 workers" 'recon(quick)*2 > owner(plan-approval) > worker*4' "T4 written with a dash"
pass "T4 a home name is a word at once"

# T5
H=$(home t5 "[design-ux] Calmer sign in")
wf "$H" pick jg-t1
expect_code 0 "$rc" "T5 pick: $err"
assert_equals "scout-worker	recon(quick) > owner(plan-approval) > worker	title-tag [design-ux]" "$res" "T5 a design ticket picks scout-worker"
assert_equals 0 "$(count "$H")" "T5 pick without --set files nothing"
H2=$(home t5b)
wf "$H2" pick jg-t1
assert_equals "worker	worker	any" "$res" "T5 a plain ticket picks worker"
printf 'pick any: deep-slices\n' > "$H/config/workflows"
wf "$H" pick jg-t1
expect_code 0 "$rc" "T5 a home pick line: $err"
assert_contains "$res" "deep-slices	" "T5 the home's pick lines replace the shipped ones"
pass "T5 pick follows the pick lines of the files"

# T6
H=$(home t6 "[design-ux] Calmer sign in")
wf "$H" set jg-t1 worker --by owner --quote "just one worker" --note n1
expect_code 0 "$rc" "T6 the owner's record: $err"
rows=$(count "$H")
wf "$H" pick jg-t1 --set
expect_code 0 "$rc" "T6 pick --set: $err"
assert_contains "$res" "kept: named by owner" "T6 the owner's record is kept"
assert_equals worker "$(meta "$H" jg-t1 workflow)" "T6 the record is unchanged"
assert_equals owner "$(meta "$H" jg-t1 workflow_by)" "T6 still named by the owner"
assert_equals "$rows" "$(count "$H")" "T6 no row filed"
pass "T6 a ticket with a record keeps it"

# T7
H=$(home t7)
wf "$H" pick jg-t1 --set
expect_code 0 "$rc" "T7 pick --set: $err"
assert_equals "main" "$(meta "$H" jg-t1 workflow_by)" "T7 chosen by main"
assert_equals worker "$(meta "$H" jg-t1 workflow)" "T7 the pick is on the ticket"
row=$(JG_HOME=$H "${BD[@]}" list --parent jg-t1 --all --limit 0 --json | jq -r '.[0].id')
assert_contains "$(JG_HOME=$H "${BD[@]}" show "$row" --json | jq -r '.[0].description')" "Owner order: Main42707." "T7 the row carries the ticket's order"
H=$(home t7b "[feature] Faster sign in" "Owner order: Main42707." lead)
wf "$H" pick jg-t1 --set
assert_equals "lead" "$(meta "$H" jg-t1 workflow_by)" "T7 chosen by the lead in a Squad Lead home"
H=$(home t7c "[feature] Faster sign in" "No order here.")
wf "$H" pick jg-t1 --set
expect_code 2 "$rc" "T7 no order"
assert_contains "$err" "no owner order" "T7 the refusal is printed"
assert_equals "" "$res" "T7 nothing on stdout"
assert_equals 0 "$(count "$H")" "T7 nothing filed"
assert_equals "" "$(meta "$H" jg-t1 workflow)" "T7 nothing on the ticket"
pass "T7 --set files the rows with the ticket's own order, or refuses"

# T8
H=$(home t8)
printf 'pick any: bogus\n' > "$H/config/workflows"
wf "$H" pick jg-t1 --set
expect_code 2 "$rc" "T8 a rule that does not parse"
assert_contains "$err" "refused: pick rule" "T8 the refusal names the rule"
assert_equals "" "$(meta "$H" jg-t1 workflow)" "T8 nothing set"
assert_equals 0 "$(count "$H")" "T8 nothing filed"
pass "T8 a broken pick rule is refused and sets nothing"
