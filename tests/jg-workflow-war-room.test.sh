#!/usr/bin/env bash
# Run the war-room workflow through advance, real critic handoffs and real plan holds.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(jg_test_tmproot jg-workflow-war-room)
export HOME=$TMP/home XDG_DATA_HOME=$TMP/xdg-data XDG_CONFIG_HOME=$TMP/xdg-config
export XDG_STATE_HOME=$TMP/xdg-state XDG_CACHE_HOME=$TMP/xdg-cache SIGN_OFF_HOME=$TMP/signoff
export PATH="$TMP/bin:$PATH"
mkdir -p "$HOME" "$TMP/bin" "$SIGN_OFF_HOME"
WF=$ROOT/bin/jg-workflow.sh
WAR=$ROOT/bin/jg-war-room.sh
HO=$ROOT/bin/jg-recon-handoff.sh
BD=(python3 -I "$ROOT/core/item-store/adapters/bd_compat.py")
export JG_WORKFLOW_WAR_ROOM=$TMP/bin/war JG_WORKFLOW_ALERT=$TMP/bin/alert
export JG_WORKFLOW_SEND=$TMP/bin/send JG_WORKFLOW_CREW_STATE=$TMP/bin/crew JG_WORKFLOW_PROJECT_MODE=$TMP/bin/mode
export JG_WAR_ROOM_NEXT=0 JG_WAR_ROOM_GATE=$TMP/bin/gate WAR
cat > "$JG_WORKFLOW_WAR_ROOM" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$JG_HOME/war-calls"
case $1 in
  start)
    if [ -f "$JG_HOME/slow-start" ]; then
      printf '%s\n' "$$" > "$JG_HOME/sleeper"
      exec sleep 60
    fi ;;
  next)
    case $(cat "$JG_HOME/next-mode" 2>/dev/null) in
      fail) echo 'owner approval not asked: fixture refusal'; exit 1 ;;
      real) exec "$WAR" "$@" ;;
    esac ;;
esac
exit 0
SH
cat > "$TMP/bin/sign-off-axi" <<'SH'
#!/bin/bash
if [ "$1" = raise ]; then
  printf 'card\n' >> "$JG_HOME/cards"
  while [ "$#" -gt 0 ]; do
    case $1 in
      --title|--about|--why|--detail|--outcome)
        printf '%s\n' "$2" >> "$JG_HOME/card-text"
        shift ;;
    esac
    shift
  done
fi
SH
# shellcheck disable=SC2016 # The stand-ins read their own arguments and environment.
{
  printf '#!/bin/sh\necho "$*" >> "$JG_HOME/alerts"\n' > "$JG_WORKFLOW_ALERT"
  printf '#!/bin/sh\necho "$*" >> "$JG_HOME/sends"\n' > "$JG_WORKFLOW_SEND"
}
printf '#!/bin/sh\necho source: pane\n' > "$JG_WORKFLOW_CREW_STATE"
printf '#!/bin/sh\necho "local off"\n' > "$JG_WORKFLOW_PROJECT_MODE"
cat > "$JG_WAR_ROOM_GATE" <<'SH'
#!/bin/sh
[ -f "$JG_HOME/passed/$1" ]
SH
printf '#!/bin/sh\nexit 3\n' > "$TMP/bin/core-signoff"
chmod +x "$TMP/bin/"*

wait_for() {
  local i
  for ((i = 0; i < 150; i++)); do [ ! -s "$1" ] || return 0; sleep 0.1; done
  fail "no record at $1"
}
adv() { timeout 20 "$WF" advance "$JG_HOME"; }
row() { "${BD[@]}" list --parent "$1" --all --limit 0 --json | jq -er --arg kind "$2" '.[] | select(.metadata.wf_kind == $kind) | .id'; }
count() { if [ -f "$1" ]; then grep -cF -- "$2" "$1" || true; else echo 0; fi; }

setup() {
  export JG_HOME=$TMP/$1 JG_STATE_OVERRIDE=$TMP/$1/state JG_DATA_OVERRIDE=$TMP/$1/data
  export JG_CONFIG_OVERRIDE=$TMP/$1/config JG_PROJECTS_OVERRIDE=$TMP/$1/projects
  jg_test_beads_home "$JG_HOME"
  mkdir -p "$JG_STATE_OVERRIDE" "$JG_PROJECTS_OVERRIDE/demo" "$JG_HOME/passed"
  printf '%s\n' '- demo' > "$JG_DATA_OVERRIDE/projects.md"
  jg_test_add "$JG_HOME" jg-t1 "[feature] Run the council" --body "Owner order: Main42747. Compare plans."
  "$WF" set jg-t1 "${2:-war-room-blitz}" --by main "${@:3}" > /dev/null
  R=$(row jg-t1 war-room); O=$(row jg-t1 owner)
  jobs=$JG_DATA_OVERRIDE/workflows
  council=$JG_DATA_OVERRIDE/war-room/$R
  mkdir -p "$council"
}
start() {
  local out
  out=$(adv)
  assert_contains "$out" "started $R (war-room)" "advance starts the council job"
  wait_for "$jobs/$R.start.rc"
  assert_contains "$(cat "$jobs/$R.start.rc")" '0 started' "the war-room step starts"
}
child() { # <title> -> task id, using the real council's child ticket form
  local id
  id=$(jg_test_backlog "$JG_HOME" add --parent "$R" "$1" --repo demo --priority 2 --body "Council fixture." --json | jq -er '(.task // .).id')
  printf '%s\n' "${id//./-}"
}
done_lane() { printf 'done [at=%s]: fixture complete\n' "$(date +%s)" > "$JG_STATE_OVERRIDE/$1.status"; }
round_for() {
  local lane=$1 gaps=$2 hash
  mkdir -p "$JG_DATA_OVERRIDE/$lane" "$JG_DATA_OVERRIDE/jg-critic"
  printf 'Draft of the plan\n' > "$JG_DATA_OVERRIDE/$lane/report.md"
  hash=$(sha256sum "$JG_DATA_OVERRIDE/$lane/report.md"); hash=${hash%% *}
  "$HO" draft "$lane" > /dev/null
  "$HO" assign "$lane" --critic jg-critic > /dev/null
  "$HO" verdict "$lane" --critic jg-critic --hash "$hash" --gaps "$gaps" > /dev/null
  adv > /dev/null
  wait_for "$JG_HOME/sends"
  adv > /dev/null
  assert_equals 1 "$(count "$JG_HOME/sends" "$lane Critic round 1")" "exactly one round reaches $lane"
  assert_contains "$(cat "$JG_HOME/sends")" "$gaps gaps" "the researcher receives the gap count"
}
record() {
  printf 'kind=variants\ncouncil=%s\nproject=demo\nangles=%s\ndepth=%s\nsynthesis_depth=deep\nvariant_critics=%s\nharness=codex\nmodel=gpt-5.5\neffort=high\n' \
    "$R" "$1" "$2" "$3" > "$council/record"
}

setup fast
start
assert_contains "$(cat "$JG_HOME/war-calls")" "start $R --project demo --angles smallest change,strongest guarantees,outside prior art first" "T1 default angles"
assert_contains "$(cat "$JG_HOME/war-calls")" '--depth standard --synthesis-depth deep --no-variant-critics' "T1 fast profile"
pass "T1 the workflow starts its council in fast mode"

record 'alpha,bravo,gamma' standard 0
variants=()
for angle in alpha bravo gamma; do variants+=("$(child "$angle variant Recon")"); done
adv >/dev/null
wait_for "$jobs/$R.next.rc"
for lane in "${variants[@]}"; do done_lane "$lane"; done
adv >/dev/null
wait_for "$jobs/$R.next.rc"
assert_equals 2 "$(count "$JG_HOME/war-calls" "next $R")" "T2 done variants kick next before the retry interval"
adv >/dev/null
assert_equals 2 "$(count "$JG_HOME/war-calls" "next $R")" "T2 no new status does not kick next again"
pass "T2 done variant lines advance the fast council without a handoff"

setup full war-room-full-blitz --angles 'alpha,bravo'
printf 'war-room codex gpt-5.5 high\n' > "$JG_CONFIG_OVERRIDE/workflow-routes"
start
assert_contains "$(cat "$JG_HOME/war-calls")" '--angles alpha,bravo --harness codex --model gpt-5.5 --effort high' "T3 custom angles and route"
assert_contains "$(cat "$JG_HOME/war-calls")" '--depth deep' "T3 full profile"
assert_not_contains "$(cat "$JG_HOME/war-calls")" '--no-variant-critics' "T3 full keeps variant critics"
pass "T3 the full workflow uses its configured angles and route"

setup failure
start
record alpha standard 0
printf 'fail\n' > "$JG_HOME/next-mode"
adv >/dev/null
wait_for "$jobs/$R.next.rc"
adv >/dev/null
adv >/dev/null
assert_equals 1 "$(count "$JG_HOME/alerts" "workflow-step-failed $R")" "T4 the refusal raises one alert"
assert_contains "$(cat "$JG_HOME/alerts")" 'owner approval not asked: fixture refusal' "T4 the alert names the refusal"
assert_absent "$jobs/$O.started" "T4 the failed council leaves the owner step pending"
pass "T4 a next refusal raises one alert and leaves its dependent step pending"

setup synthesis
start
record alpha standard 0
round_for "$(child 'synthesis Recon')" 3
pass "T5 a synthesis researcher gets its three gaps once"

setup slow
: > "$JG_HOME/slow-start"
jg_test_add "$JG_HOME" jg-t2 "[feature] Build the widget" --body "Owner order: Main42748. Build the widget."
"$WF" set jg-t2 worker --by main >/dev/null
worker=$(row jg-t2 worker)
out=$(adv)
assert_contains "$out" "started $R (war-room)" "T6 the slow council starts"
assert_contains "$out" "started $worker (worker)" "T6 a second ticket starts in the same pass"
wait_for "$JG_HOME/sleeper"
adv >/dev/null
assert_absent "$jobs/$R.start.rc" "T6 council setup is still running"
assert_equals 1 "$(count "$JG_HOME/war-calls" "start $R")" "T6 a second pass does not start again"
assert_absent "$JG_HOME/alerts" "T6 no alert during the slow start"
kill -TERM -- "$(cat "$JG_HOME/sleeper")"
wait_for "$jobs/$R.start.rc"
wait_for "$jobs/$worker.start.rc"
assert_contains "$(cat "$jobs/$worker.start.rc")" '0 started' "T6 the worker start succeeds"
pass "T6 a slow council start does not hold back a ready worker"

setup variant war-room-full-blitz
start
record alpha deep 1
round_for "$(child 'alpha variant Recon')" 2
pass "T7 a full council's variant gets its two gaps once"

approval() {
  local variant synth dry plan title=$3 out
  setup "$1"
  start
  record alpha standard 0
  "$ROOT/bin/jg-muster-depth.sh" record --ticket "$R" --depth skip --reason 'The fixture is aligned.' >/dev/null
  variant=$(child 'alpha variant Recon')
  synth=$(child 'synthesis Recon')
  dry=$(child 'dry run of order 1')
  mkdir -p "$JG_DATA_OVERRIDE/$synth/orders" "$JG_DATA_OVERRIDE/$dry" "$JG_STATE_OVERRIDE/procevent"
  : > "$JG_HOME/passed/$variant"; : > "$JG_HOME/passed/$synth"
  printf 'Role: synthesis\nRecon depth: deep\n' > "$JG_DATA_OVERRIDE/$synth/brief.md"
  printf 'Role: dry run\n' > "$JG_DATA_OVERRIDE/$dry/brief.md"
  printf 'working [at=1]: fixture running\n' | tee "$JG_STATE_OVERRIDE/$synth.status" > "$JG_STATE_OVERRIDE/$dry.status"
  plan=$JG_DATA_OVERRIDE/$synth/orders/plan.json
  printf 'Build the fixture.\n' > "${plan%/*}/a.md"
  jq -n --arg title "$title" '{plan:"jg-wk6", title:$title, report:"/tmp/report.md", intent:"Build the fixture.",
    prior_art:"Prior art: none needed - a fixture",
    slices:[{id:"a", title:"Build the fixture", owner_home:"main", project:"demo", size:"S", risk:"Low", depends_on:[],
             files:["bin/a.sh (new)"], machine:null, order:"a.md", owner_word:null, gate:null}]}' > "$plan"
  : > "$JG_STATE_OVERRIDE/procevent/signoff.source"
  export JG_SIGNOFF_SCRIPT=$2
  printf 'real\n' > "$JG_HOME/next-mode"
  adv >/dev/null
  wait_for "$jobs/$R.next.rc"
  assert_absent "$council/plan-asked" "T8 the working dry run leaves the plan pending"
  done_lane "$dry"
  adv >/dev/null
  wait_for "$jobs/$R.next.rc"
  assert_equals 2 "$(count "$JG_HOME/war-calls" "next $R")" "T8 the dry run kicks next exactly once"
  assert_equals "$plan" "$(cat "$council/plan-asked")" "T8 the real next records the plan"
  assert_not_contains "$(cat "$jobs/$R.next.log")" 'owner approval not asked' "T8 the real next did not refuse the hold"
  if [ "$2" = "$TMP/bin/core-signoff" ]; then
    assert_absent "$JG_HOME/cards" "T8 the core adapter can intentionally post no card"
  else
    assert_equals 1 "$(count "$JG_HOME/cards" card)" "T8 the answer-intake path posts one card"
  fi
  out=$(adv)
  assert_contains "$out" "started $O (owner)" "T8 the owner step starts on the council's existing question"
  wait_for "$jobs/$O.start.rc"
  assert_contains "$(cat "$jobs/$O.start.rc")" '0 waits' "T8 the owner step waits for approval"
  assert_equals open "$("${BD[@]}" show "$R" --json | jq -r '.[0].status')" "T8 the council stays open for the answer"
  assert_equals 1 "$(jg_test_backlog "$JG_HOME" questions --ticket "$R" --json | jq length)" "T8 the council keeps its question"
  assert_equals 0 "$(jg_test_backlog "$JG_HOME" questions --ticket "$O" --json | jq length)" "T8 the owner step adds no second question"
  assert_equals 1 "$(count "$JG_HOME/cards" card)" "T8 the workflow has one board card"
}

approval core-board "$TMP/bin/core-signoff" 'Every ticket runs its own workflow'
marker=$(find "$JG_STATE_OVERRIDE/workflow-cards" -maxdepth 1 -type f)
values=$(cut -f6 "$marker")
"$WF" answer "${marker##*/}" --answer "${values%%,*}" --at 1 --label "Owner approval"
assert_not_contains "$(adv)" "closed $R (war-room)" "T8 open child tickets still keep the council open"
while IFS= read -r piece; do
  jg_test_backlog "$JG_HOME" 'done' "$piece" --note 'Fixture lane finished.' >/dev/null
done < <("${BD[@]}" list --parent "$R" --all --limit 0 --json | jq -r '.[].id')
assert_contains "$(adv)" "closed $R (war-room)" "T8 the council closes after approval"
approval answer-board "$ROOT/bin/jg-procevent-signoff.sh" 'Every ticket runs its own workflow'
assert_not_contains "$(cat "$JG_HOME/card-text")" / "T8 card text names no path"
assert_not_contains "$(cat "$JG_HOME/card-text")" Main "T8 card text names no Main"
assert_not_contains "$(cat "$JG_HOME/card-text")" jg- "T8 card text names no ticket id"
assert_contains "$(cat "$JG_HOME/card-text")" 'A plan of 1 parts in 1 stages is ready: Every ticket runs its own workflow.' "T8 the approval keeps the plain title"
pass "T8 both sign-off adapters hand off to the owner step while the council waits for approval"

# shellcheck source=bin/jg-ask-gate-lib.sh
. "$ROOT/bin/jg-ask-gate-lib.sh"
jg_ask_card_refusal "$R" 2 'Is the plan ready?' 'A plan of 1 parts in 1 stages is ready: Every ticket runs its own workflow.'
approval unsafe-title "$ROOT/bin/jg-procevent-signoff.sh" 'Show the Main route'
grep -Fxq 'A plan of 1 parts in 1 stages is ready.' "$JG_HOME/card-text" || fail "T9 the unsafe title is dropped"
pass "T9 plain plan titles pass the card rule and unsafe titles use the fallback"
