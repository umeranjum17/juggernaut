#!/usr/bin/env bash
# A council's plan approval question hands its plan to an owner step while the
# council remains open. Other unfinished steps still act as barriers.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(jg_test_tmproot jg-workflow-owner)
WF=$ROOT/bin/jg-workflow.sh
BACKLOG=$ROOT/bin/jg-backlog.sh
HOLD=$ROOT/bin/jg-captain-hold.sh
BD=(python3 -I "$ROOT/core/item-store/adapters/bd_compat.py")

setup_home() {
  export JG_HOME=$TMP/$1 JG_STATE_OVERRIDE=$TMP/$1/state JG_DATA_OVERRIDE=$TMP/$1/data JG_CONFIG_OVERRIDE=$TMP/$1/config
  export SIGN_OFF_HOME=$JG_HOME/board
  jg_test_beads_home "$JG_HOME"
  mkdir -p "$JG_STATE_OVERRIDE" "$SIGN_OFF_HOME"
  jg_test_add "$JG_HOME" jg-t1 '[feature] Faster sign in' --body 'Owner order: Main1.'
  "$WF" set jg-t1 "$2" --by main >/dev/null
  owner=$(row owner)
}

setup() {
  setup_home "$@"
  council=$(row war-room)
}

row() {
  "${BD[@]}" list --parent jg-t1 --all --limit 0 --json \
    | jq -er --arg kind "$1" '.[] | select(.metadata.wf_kind == $kind) | .id'
}

ask_for_plan() {
  "$HOLD" hold "$council" --reason 'Plan approval for faster sign in' --must plan-approval >/dev/null
  mkdir -p "$JG_DATA_OVERRIDE/war-room/$council"
  printf '%s\n' "$JG_DATA_OVERRIDE/plan.json" > "$JG_DATA_OVERRIDE/war-room/$council/plan-asked"
}

advance() { "$WF" advance "$JG_HOME" --dry-run; }

setup handoff 'war-room(fast) > owner > worker'
assert_not_contains "$(advance)" "would start $owner (owner)" 'owner waits for the council question'
ask_for_plan
out=$(advance)
assert_contains "$out" "would start $owner (owner)" 'council hands its plan to the owner step'
assert_equals open "$("${BD[@]}" show "$council" --json | jq -r '.[0].status')" 'the council remains open'
assert_not_contains "$out" "would start $(row worker) (worker)" 'the build still waits for approval'
pass 'a council awaiting plan approval lets its owner step start'

setup barrier 'war-room(fast) + scout > owner > worker'
ask_for_plan
assert_not_contains "$(advance)" "would start $owner (owner)" 'the other open report still blocks the owner step'
"$BACKLOG" 'done' "$(row recon)" --note 'fixture report finished' >/dev/null
assert_contains "$(advance)" "would start $owner (owner)" 'the owner step starts once the other report closes'
pass 'the council handoff leaves other dependencies in force'

setup intake 'war-room(fast) + scout > owner > worker'
ask_for_plan
ordinary=$(row recon)
"$HOLD" hold "$ordinary" --reason 'Review the draft' --must plan-approval >/dev/null
board_key() {
  local identity
  identity=$("$HOLD" open "$1" --identity)
  bash -c '. "$1"; jg_question_hold_card_key "$2" "$3"' _ "$ROOT/bin/jg-question-lib.sh" "$1" "$identity"
}
workflow_key=$(board_key "$council")
ordinary_key=$(board_key "$ordinary")
mkdir -p "$JG_STATE_OVERRIDE/workflow-cards" "$JG_HOME/fakebin"
touch "$JG_STATE_OVERRIDE/workflow-cards/$workflow_key"
jq -n --arg wf "$workflow_key" --arg ordinary "$ordinary_key" \
  '{($wf): {answer:"no",label:"Taken by default",close:"release",at:1},
    ($ordinary): {answer:"yes",label:"Yes",close:"release",at:2}}' > "$SIGN_OFF_HOME/answers.json"
cat > "$JG_HOME/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = answers ]; then cat "$SIGN_OFF_HOME/answers.json"; fi
SH
chmod +x "$JG_HOME/fakebin/sign-off-axi"
jq -nc --arg row "$council" --arg card "$workflow_key" \
  '{key:$row,card:$card,answer:"no",label:"Taken by default",close:"release",at:1}' > "$JG_HOME/early.result"
for adapter in "$ROOT/core/signoff/bin/jg-procevent-signoff.sh" "$ROOT/bin/jg-procevent-signoff.sh"; do
  out=$(PATH="$JG_HOME/fakebin:$PATH" JG_CODE_ROOT="$ROOT" "$adapter" poll)
  assert_not_contains "$out" "\"key\":\"$council\"" 'generic sign-off skips the workflow answer'
  assert_contains "$out" "\"key\":\"$ordinary\"" 'generic sign-off still takes the ordinary answer'
  out=$(JG_CODE_ROOT="$ROOT" "$adapter" answers "$JG_HOME/early.result")
  assert_equals '' "$out" 'a captured answer is skipped if its card now belongs to the workflow'
done
pass 'both sign-off adapters exclude workflow answers and still deliver ordinary answers'

fixture_path=$PATH
setup_board() {
  export PATH=$fixture_path
  setup_home "$1" "${2:-scout > owner > worker}"
  mkdir -p "$JG_HOME/fakebin"
  cat > "$JG_HOME/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
case $1 in
  answers) cat "$SIGN_OFF_HOME/answers.json" ;;
  raise) printf '%s\n' "$@" > "$SIGN_OFF_HOME/posted" ;;
  *) printf '{"decisions":[]}\n' ;;
esac
SH
  chmod +x "$JG_HOME/fakebin/sign-off-axi"
  export PATH=$JG_HOME/fakebin:$PATH
  printf '{}\n' > "$SIGN_OFF_HOME/answers.json"
  printf '#!/bin/sh\nprintf "kicked\\n" >> "%s/kicks"\n' "$JG_HOME" > "$JG_STATE_OVERRIDE/auto-dispatch.check.sh"
  chmod +x "$JG_STATE_OVERRIDE/auto-dispatch.check.sh"
  tag=${owner#jg-}; tag=${tag//./-}
  card=wf-${owner//./-}-plan
  record=$JG_DATA_OVERRIDE/workflows/$owner.answer
  marker=$JG_STATE_OVERRIDE/workflow-cards/$card
}

close_scout() { "$BACKLOG" 'done' "$(row recon)" --note 'fixture report finished' >/dev/null; }

wait_for() {
  local i
  for ((i = 0; i < 150; i++)); do [ ! -s "$1" ] || return 0; sleep 0.1; done
  fail "no record at $1"
}

setup_board approve
close_scout
out=$("$WF" advance "$JG_HOME")
assert_contains "$out" "started $owner (owner)" 'T1 started its owner step'
wait_for "$JG_DATA_OVERRIDE/workflows/$owner.start.rc"
assert_present "$marker" 'T1 the card is bound to its owner row'
assert_present "$SIGN_OFF_HOME/posted" 'T1 the real question card reached the board'
assert_contains "$(cat "$SIGN_OFF_HOME/posted")" 'Approve the plan for Faster sign in?' 'T1 the title uses plain words'
for flag in --why --recommend-reason --default; do
  assert_contains "$(cat "$SIGN_OFF_HOME/posted")" "$flag" "T1 card includes $flag"
done
assert_equals 2 "$(grep -cxF -- --outcome "$SIGN_OFF_HOME/posted")" 'T1 two outcomes'
assert_equals 1 "$("$BACKLOG" questions --ticket "$owner" --json | jq length)" 'T1 one question on the owner row'
assert_equals 0 "$("$BACKLOG" questions --ticket jg-t1 --json | jq length)" 'T1 no question on the ticket'
pass 'T1 one plain board card holds the owner row'

BOARD_ANSWERS=$ROOT/bin/jg-board-answers.sh
board_answer() {
  jq -n --arg key "$card" --arg answer "$1-$tag" --arg taken "${2:-}" --arg at "$3" \
    '{($key): {answer:$answer,taken:$taken,at:$at,label:"Owner option",note:"Change the order of the parts"}}' \
    > "$SIGN_OFF_HOME/answers.json"
  "$BOARD_ANSWERS" check
}

board_answer a default 1
assert_absent "$record" 'T4 a default answer is refused'
"$HOLD" open "$owner" >/dev/null || fail 'T4 the owner question must stay open'
pass 'T4 a board default cannot grant approval'

board_answer b '' 2
assert_equals b "$(cut -f1 "$record")" 'T3 records not yet'
assert_not_contains "$(advance)" "would start $(row worker) (worker)" 'T3 the worker still waits'
if ! grep -qF 'Change the order of the parts' "$JG_STATE_OVERRIDE"/inbox/*.note; then fail 'T3 the inbox lacks the owner words'; fi
"$HOLD" open "$owner" >/dev/null || fail 'T3 the owner question must stay open'
pass 'T3 not yet leaves the hold open and delivers the owner words'

board_answer a '' 3
assert_equals a "$(tail -n1 "$record" | cut -f1)" 'T2 records the approval'
assert_contains "$("$BACKLOG" show "$owner" --full)" 'approved-by-captain:' 'T2 approval belongs to the owner row'
assert_not_contains "$("$BACKLOG" show jg-t1 --full)" 'approved-by-captain:' 'T2 there is no approval on the ticket'
assert_equals "$owner" "$("${BD[@]}" show "$owner" --json | jq -r '.[0].metadata.wf_approved_row')" 'T2 the approval names its own row'
wait_for "$JG_HOME/kicks"
"$BOARD_ANSWERS" check
assert_equals 1 "$(wc -l < "$JG_HOME/kicks")" 'T2 replay does not kick dispatch twice'
assert_not_contains "$(cat "$JG_STATE_OVERRIDE/.wake-queue" 2>/dev/null || true)" 'board-answer-unmapped' 'T2 no undelivered alert'
pass 'T2 a board yes signs and releases the owner row once'

for adapter_result in absent adopted refused; do
  setup_board "hold-$adapter_result"
  close_scout
  export TEST_ADAPTER_RESULT=$adapter_result JG_SIGNOFF_SCRIPT=$JG_HOME/fakebin/hold-adapter
  mkdir -p "$JG_STATE_OVERRIDE/procevent"
  touch "$JG_STATE_OVERRIDE/procevent/signoff.source"
  cat > "$JG_SIGNOFF_SCRIPT" <<'SH'
#!/usr/bin/env bash
case $TEST_ADAPTER_RESULT in
  absent) exit 3 ;;
  adopted) printf 'sign-off card on the board for %s\n' "$2" ;;
  refused) printf 'no board card was posted\n' >&2; exit 1 ;;
esac
SH
  chmod +x "$JG_SIGNOFF_SCRIPT"
  "$WF" step-start "$JG_HOME" "$owner"
  assert_equals 1 "$(find "$JG_STATE_OVERRIDE/workflow-cards" -type f | wc -l)" 'T1b exactly one card marker'
  if [ "$adapter_result" = adopted ]; then
    adopted_key=$(board_key "$owner")
    assert_equals yes,no "$(cut -f6 "$JG_STATE_OVERRIDE/workflow-cards/$adopted_key")" 'T1b the adopted choices are kept'
    assert_absent "$SIGN_OFF_HOME/posted" 'T1b an adopted card does not post a second card'
    rc=0
    "$BOARD_ANSWERS" route-answer "$adopted_key" 10 "a-$tag" || rc=$?
    assert_equals 1 "$rc" 'T1b the adopted card refuses a tagged answer'
    assert_absent "$record" 'T1b the refusal writes nothing'
    "$BOARD_ANSWERS" route-answer "$adopted_key" 11 yes
    assert_equals a "$(cut -f1 "$record")" 'T1b an adopted yes becomes an approval'
    assert_equals 1 "$("$BACKLOG" show "$owner" --full | grep -cF 'approved-by-captain:')" 'T1b exactly one signed approval'
    assert_contains "$("$WF" advance "$JG_HOME" --close-only)" "closed $owner (owner)" 'T1b verification closes the adopted owner step'
  else
    assert_present "$marker" 'T1b an adapter without a card is followed by a workflow card'
    assert_present "$SIGN_OFF_HOME/posted" 'T1b the workflow posted the replacement card'
  fi
  unset JG_SIGNOFF_SCRIPT TEST_ADAPTER_RESULT
done
pass 'T1b hold adapters can hand off a card or let the workflow post one'

setup_board subject
close_scout
"${BD[@]}" update jg-t1 --title 'Make jg-x1 easy to use' >/dev/null
rc=0
"$WF" step-start "$JG_HOME" "$owner" || rc=$?
assert_equals 1 "$rc" 'T8 the card text rule refuses an internal name'
assert_absent "$SIGN_OFF_HOME/posted" 'T8 an invalid title never reaches the board'
assert_contains "$(cat "$JG_DATA_OVERRIDE/workflows/$owner.start.rc")" 'Give the ticket a plain subject' 'T8 the start records the cause'
"$WF" set jg-t1 --subject 'the faster sign in' >/dev/null
"$WF" step-start "$JG_HOME" "$owner"
assert_contains "$(cat "$SIGN_OFF_HOME/posted")" 'Approve the plan for the faster sign in?' 'T8 a plain subject posts'
pass 'T8 a plain subject repairs a title refused by the board'

setup_board council 'war-room(fast) > owner > worker'
council=$(row war-room)
ask_for_plan
write_plan() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/plan.json" <<'JSON'
{"plan":"signin","title":"Faster sign in","intent":"Make sign in faster","report":"report.md","prior_art":"Fixture",
 "slices":[{"id":"one","title":"First working part","project":"demo","owner_home":"main","files":["one.txt"],"order":"order.md"},
           {"id":"two","title":"Second working part","project":"demo","owner_home":"main","files":["two.txt"],"order":"order.md","depends_on":["one"]}]}
JSON
  printf '# Build the part\n' > "$dir/order.md"
}
write_plan "$JG_DATA_OVERRIDE"
"$WF" step-start "$JG_HOME" "$owner"
assert_equals 0 "$("$BACKLOG" questions --ticket "$owner" --json | jq length)" 'T5 no second question on the owner row'
assert_equals 1 "$("$BACKLOG" questions --ticket "$council" --json | jq length)" 'T5 the council keeps its question'
assert_contains "$(cat "$SIGN_OFF_HOME/posted")" 'The plan builds 2 parts; 1 start at once when you approve.' 'T5 counts come from the plan check'
"$BOARD_ANSWERS" route-answer "$card" 21 "a-$tag"
assert_equals "$council" "$("${BD[@]}" show "$owner" --json | jq -r '.[0].metadata.wf_approved_row')" 'T5 the yes is bound to the council'
pass 'T5 a council hands off its existing hold and checked plan'

setup_board fanout 'deep-slices'
close_scout
"$BACKLOG" 'done' "$(row critic)" --note 'fixture plan reviewed' >/dev/null
recon=$(row recon)
write_plan "$JG_DATA_OVERRIDE/${recon//./-}/orders"
fanout=$(row fanout)
# Verify scheduling here. Running the downstream swarm belongs to the fanout slice.
export JG_WORKFLOW_KIND_DIR=$JG_HOME/kinds
mkdir -p "$JG_WORKFLOW_KIND_DIR"
ln -sn "$ROOT/core/workflows/kinds/owner.py" "$JG_WORKFLOW_KIND_DIR/owner.py"
cat > "$JG_WORKFLOW_KIND_DIR/fanout.py" <<'PY'
def start(home, step):
    return "started", "the downstream step job ran"
PY
"$WF" step-start "$JG_HOME" "$owner"
assert_not_contains "$(advance)" "would start $fanout (fanout)" 'T6 fanout waits for approval'
"$BOARD_ANSWERS" route-answer "$card" 25 "a-$tag"
out=$("$WF" advance "$JG_HOME")
assert_contains "$out" "closed $owner (owner)" 'T6 advance closes the owner step'
assert_contains "$out" "started $fanout (fanout)" 'T6 the same advance starts fanout'
wait_for "$JG_DATA_OVERRIDE/workflows/$fanout.start.rc"
assert_contains "$(cat "$JG_DATA_OVERRIDE/workflows/$fanout.start.rc")" 'the downstream step job ran' 'T6 detached fanout job ran'
unset JG_WORKFLOW_KIND_DIR
pass 'T6 one advance closes the owner step and starts the downstream job'

(
  export PATH=$fixture_path HOME=$TMP/real-board-home
  mkdir -p "$HOME" "$TMP/board-init-bin"
  ln -sn "$(node -p 'process.execPath')" "$TMP/board-init-bin/node"
  signoff=$(command -v sign-off-axi)
  setup_home real-board 'scout > owner > worker'
  PATH="$TMP/board-init-bin" "$signoff" init "$SIGN_OFF_HOME" >/dev/null
  first=$owner
  jg_test_add "$JG_HOME" jg-t2 '[feature] Faster sign in' --body 'Owner order: Main2.'
  "$WF" set jg-t2 'scout > owner > worker' --by main >/dev/null
  second=$("${BD[@]}" list --parent jg-t2 --all --limit 0 --json | jq -er '.[] | select(.metadata.wf_kind == "owner") | .id')
  for row in "$first" "$second"; do "$WF" step-start "$JG_HOME" "$row"; done
  first_key=wf-${first//./-}-plan; second_key=wf-${second//./-}-plan
  cards=$(sign-off-axi list --full --json)
  assert_equals 2 "$(jq '[.decisions[] | select(.state == "open" and .answer == null)] | length' <<<"$cards")" 'T9 two identical titles have two waiting cards'
  for pair in "$first_key:jg-t1" "$second_key:jg-t2"; do
    assert_equals "${pair#*:}" "$(jq -r --arg key "${pair%:*}" '.decisions[] | select(.key == $key) | .ticket' <<<"$cards")" 'T9 each card names its own ticket'
  done
  other=$(cat "$JG_STATE_OVERRIDE/workflow-cards/$second_key")
  first_tag=${first#jg-}; first_tag=${first_tag//./-}
  "$BOARD_ANSWERS" route-answer "$first_key" 31 "a-$first_tag"
  assert_equals a "$(cut -f1 "$JG_DATA_OVERRIDE/workflows/$first.answer")" 'T9 the first owner step is approved'
  assert_absent "$JG_DATA_OVERRIDE/workflows/$second.answer" 'T9 the other plan has no approval'
  assert_equals open "$(sign-off-axi list --full --json | jq -r --arg key "$second_key" '.decisions[] | select(.key == $key and .answer == null) | .state')" 'T9 the other card still waits'
  assert_equals "$other" "$(cat "$JG_STATE_OVERRIDE/workflow-cards/$second_key")" 'T9 the other marker is unchanged'
)
pass 'T9 real sign-off keeps identical questions independent'

setup_board twice 'scout > owner > worker > scout > owner > worker'
mapfile -t owners < <(row owner | sort -V)
mapfile -t workers < <(row worker | sort -V)
while read -r scout; do "$BACKLOG" 'done' "$scout" --note 'fixture report finished' >/dev/null; done < <(row recon)
build_guard() {
  ( # shellcheck disable=SC2034
    STATE=$JG_STATE_OVERRIDE DATA=$JG_DATA_OVERRIDE SCRIPT_DIR=$ROOT/bin
    # shellcheck disable=SC2329
    fail() { echo "$*"; exit 1; }
    # shellcheck source=bin/jg-backlog-transition-lib.sh disable=SC1091
    . "$ROOT/bin/jg-backlog-transition-lib.sh"
    # shellcheck source=bin/jg-captain-ask-lib.sh disable=SC1091
    . "$ROOT/bin/jg-captain-ask-lib.sh"
    # shellcheck source=bin/jg-squad-lead-parent-lib.sh disable=SC1091
    . "$ROOT/bin/jg-squad-lead-parent-lib.sh"
    guard_captain_ask_build "$1"
  )
}
"$HOLD" hold jg-t1 --reason 'Fixture approves the ticket' --must plan-approval >/dev/null
printf 'Yes to the ticket only.\n' > "$JG_HOME/words"
"$HOLD" answer jg-t1 --decision-file "$JG_HOME/words" --release >/dev/null
for worker in "${workers[@]}"; do
  if build_guard "$worker" >/dev/null 2>&1; then fail 'T10 a ticket-only approval cannot authorize a worker'; fi
done
for index in 0 1; do
  owner=${owners[index]}
  tag=${owner#jg-}; tag=${tag//./-}
  card=wf-${owner//./-}-plan
  "$WF" step-start "$JG_HOME" "$owner"
  assert_present "$JG_STATE_OVERRIDE/workflow-cards/$card" 'T10 each owner step has its own card'
  "$BOARD_ANSWERS" route-answer "$card" "$((41 + index))" "a-$tag"
  out=$("$WF" advance "$JG_HOME" --close-only)
  assert_contains "$out" "closed $owner (owner)" 'T10 the approved owner step closes'
  build_guard "${workers[index]}"
  if [ "$index" = 0 ] && build_guard "${workers[1]}" >/dev/null 2>&1; then
    fail 'T10 the first approval cannot authorize the second worker'
  fi
done
pass 'T10 each worker needs the board yes from its own owner step'

parent=$TMP/signing-parent
lead=$TMP/signing-lead
mkdir -p "$parent/state" "$parent/data" "$parent/config" "$lead"
ln -sn "$ROOT/bin" "$parent/bin"
ln -sn "$ROOT/core" "$parent/core"
printf 'signing-lead\n' > "$lead/.jg-squad-lead-home"
printf 'schema=jg-squad-lead-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$lead/.jg-squad-lead-parent"
setup_board signing-lead
close_scout
"$WF" step-start "$JG_HOME" "$owner"
"$BOARD_ANSWERS" route-answer "$card" 51 "a-$tag"
assert_present "$parent/state/captain-approval.key" 'T7 the parent signs the lead approval'
assert_absent "$lead/state/captain-approval.key" 'T7 the lead does not create its own key'
assert_contains "$("$BACKLOG" show "$owner" --full)" 'approved-by-captain:' 'T7 the signed line is on the lead row'
assert_equals "$owner" "$("${BD[@]}" show "$owner" --json | jq -r '.[0].metadata.wf_approved_row')" 'T7 the lead row has its approval metadata'
build_guard "$(row worker)"
assert_contains "$("$WF" advance "$JG_HOME" --close-only)" "closed $owner (owner)" 'T7 the lead can complete the owner step'
pass 'T7 a parent-signed approval unlocks the build in the lead home'
