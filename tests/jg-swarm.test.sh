#!/usr/bin/env bash
# tests/jg-swarm.test.sh - bin/jg-swarm.sh starts a swarm from a plan file, on fixture stores with strict intake, a Main home
# and a lead home, no model turn. Stand-ins log the send and the card post (the card stand-in files the design row the real
# post files). Cases: 1 refusals write nothing; 2 the start files, approves, briefs and arms; 3 the chain with the real hold
# check; 4 safe twice and a resume; 5 the route dry run refuses after the plan rows; 6 the start returns at once and the run goes
# on detached, and a start while a run holds the lock does nothing; 7 a run stopped part way is resumed by the next start; 8 --order (a [captain-ask] row) names the owner order. Cases 1 to 5
# run the body in the foreground (--wait).
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWARM="$ROOT/bin/jg-swarm.sh" T=$(jg_test_tmproot jg-swarm)
T=$(cd "$T" && pwd)

# A world: Main (home $1/main) with one registered lead (lead1, home $1/lead), strict intake in both, proj on yolo in both.
mkworld() {  # <dir>
  local w=$1 h
  mkdir -p "$w"
  for h in main lead; do
    jg_test_beads_home "$w/$h"
    mkdir -p "$w/$h/state" "$w/$h/data" "$w/$h/projects/proj"
    ln -sn "$ROOT/bin" "$w/$h/bin"; ln -sn "$ROOT/core" "$w/$h/core"; ln -sn "$ROOT/toolchain.versions" "$w/$h/toolchain.versions"
    printf -- '- proj [local-trunk +yolo] - the one project (added 2026-11-19)\n' > "$w/$h/data/projects.md"
  done
  printf 'lead1\n' > "$w/lead/.jg-squad-lead-home"
  printf -- '- lead1 - the test lead (home: %s; scope: tests; projects: proj; added 2026-11-19)\n' "$w/lead" > "$w/main/data/squad_leads.md"
  printf 'kind=squad_lead\n' > "$w/main/state/lead1.meta"
}
strict() { rm -f "$1/main/config/backlog-intake-loose" "$1/lead/config/backlog-intake-loose"; }
# <home dir> <command...>: the command in that home. A lead home derives its own paths.
at() {
  local h=$1
  shift
  env HOME="$T" TMPDIR="$T" JG_HOME="$h" JG_STATE_OVERRIDE="$h/state" JG_DATA_OVERRIDE="$h/data" JG_CONFIG_OVERRIDE="$h/config" \
    JG_SWARM_SEND="$T/send" JG_SWARM_CARD="$T/card" "$@" 2>&1
}
rows_in() { at "$1" "$ROOT/bin/jg-backlog.sh" list --all | awk '/^  / && !/^  - / { n++ } END { print n + 0 }'; }
row_ids() { at "$1" "$ROOT/bin/jg-backlog.sh" list --all | awk '/^  / && !/^  - / { sub(/^  /, ""); sub(/,.*/, ""); print }' | sort | tr '\n' ' '; }
has_row() { at "$1" "$ROOT/bin/jg-backlog.sh" show "$2" >/dev/null 2>&1; }

# The plan: A; B after A; D after A with an owner word (Main); E; F after E with an owner word (lead1).
slice() {  # <id> <owner> <deps json> [<extra json>]
  jq -n --arg id "$1" --arg o "$2" --argjson d "$3" --argjson x "${4:-null}" \
    '{id: $id, title: ("Make part " + $id + " of it"), owner_home: $o, project: "proj", size: "S", risk: "Low", depends_on: $d,
      files: ["bin/\($id).sh (new)"], machine: null, order: ($id + ".md"), owner_word: null, gate: null} + ($x // {})'
}
word() {  # <question> <option a> <option b>: an owner_word with every field the board needs
  jq -n --arg q "$1" --arg a "$2" --arg b "$3" '{owner_word: {question: $q, options: {a: $a, b: $b}, why: "The owner picks before the work starts.",
    outcomes: {a: "We build \($a).", b: "We build \($b)."}, recommend: "a", recommend_reason: "It fits the rest of the page.", default: "a",
    must: "design-pick"}}'
}
mkplan() {  # <dir>: the plan file and its orders in <dir>
  mkdir -p "$1"
  jq -n '{plan: "jg-plan", title: "Swarm start test", report: "/nonexistent/report.md", intent: "The owner wants the swarm run.", owner_order: "Main1",
          prior_art: "Prior art: none needed - the test fixture is neither new nor complex.", slices: $ARGS.positional | map(fromjson)}' --args \
    "$(slice a main '[]')" "$(slice b main '["a"]')" "$(slice d main '["a"]' "$(word 'Which colour should the new button be?' blue green)")" \
    "$(slice e lead1 '[]')" "$(slice f lead1 '["e"]' "$(word 'Which size should the new panel be?' small large)")" > "$1/plan.json"
  local s
  for s in a b d e f; do printf '# Work order %s\n\n## Goal\n\nBuild part %s of it. More words.\n\n## Acceptance\n\n1. true\n' "$s" "$s" > "$1/$s.md"; done
}

# Stand-ins: the send logs its arguments; the card logs them, files the design row in Main as the real post does, and prints card-<n>.
cat > "$T/send" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" | tr '\n' ' ' >> "$T/send.log"; echo >> "$T/send.log"
SH
cat > "$T/card" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/card.log"
n=\$(( \$(wc -l < "$T/card.log") + \$(cat "$T/card.base" 2>/dev/null || echo 0) ))
raised='' title=''
while [ \$# -gt 0 ]; do case \$1 in --raised-by) raised=\$2 ;; --title) title=\$2 ;; esac; shift; done
"$ROOT/bin/jg-captain-hold.sh" design-card "card-\$n" --raised-by "\$raised" --title "\$title" >&2 || exit 1
echo "card-\$n"
SH
chmod +x "$T/send" "$T/card"
start() {  # <home> <plan.json> [<args>]: the foreground run, as the start ran before it detached
  local h=$1 p=$2
  shift 2
  at "$h" "$SWARM" start "$p" --harness claude --model sonnet --effort medium --wait "$@"
}
bgstart() {  # <home> <plan.json> [<args>]: the start as a caller runs it
  local h=$1 p=$2
  shift 2
  at "$h" "$SWARM" start "$p" --harness claude --model sonnet --effort medium "$@"
}
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

# --- Case 1: refusals write nothing ---------------------------------------------------------------------------------------
W1=$T/w1
mkworld "$W1"; strict "$W1"; mkplan "$W1/in"
M=$W1/main L=$W1/lead
jq '.slices[2].owner_word.options |= del(.b)' "$W1/in/plan.json" > "$W1/in/bad.json"
out=$(start "$M" "$W1/in/bad.json"); rc=$?
assert_equals 2 "$rc" "a plan the plan check refuses must exit 2"
assert_contains "$out" "refused:" "the plan check's refused line must be printed"
printf -- '- proj [local-trunk] - the one project (added 2026-11-19)\n' > "$M/data/projects.md"
out=$(start "$M" "$W1/in/plan.json"); rc=$?
assert_equals 2 "$rc" "a project with yolo off must exit 2"
assert_contains "$out" "yolo off" "the refusal must name yolo"
printf -- '- proj [local-trunk +yolo] - the one project (added 2026-11-19)\n' > "$M/data/projects.md"
out=$(start "$L" "$W1/in/plan.json"); rc=$?
assert_equals 2 "$rc" "a Squad Lead home must exit 2"
[ ! -e "$M/data/swarm" ] && [ ! -e "$L/data/swarm" ] || fail "a refusal must write no data/swarm"
assert_equals "0 0" "$(rows_in "$M") $(rows_in "$L")" "a refusal must file no row"

# T3: no --order and no owner_order is refused before the first write; a reference that is neither MainNNN nor a [captain-ask] row too.
jq 'del(.owner_order)' "$W1/in/plan.json" > "$W1/in/noorder.json"
out=$(start "$M" "$W1/in/noorder.json"); rc=$?
assert_equals 2 "$rc" "T3: a start with no owner order must exit 2: $out"
assert_contains "$out" "no owner order" "T3: the refusal must name the owner order"
out=$(start "$M" "$W1/in/noorder.json" --order "some prose"); rc=$?
assert_equals 2 "$rc" "T3: an order that is not a reference must exit 2: $out"
at "$M" "$ROOT/bin/jg-backlog.sh" add jg-plain-row "[feature] An ordinary row" --kind ship --repo proj --priority 2 \
  --body "$(printf '## Captain\nx\n\n## Ask\nx\n\n## Why\nx\n\n## Done when\nx\n\n## Acceptance Criteria\nx\n')" >/dev/null || fail "T3: the plain row was not filed"
out=$(start "$M" "$W1/in/noorder.json" --order jg-plain-row); rc=$?
assert_equals 2 "$rc" "T3: an order that names a row that is no [captain-ask] must exit 2: $out"
assert_contains "$out" "neither MainNNN nor the id of a [captain-ask] row" "T3: the refusal must say what an order is"
[ ! -e "$M/data/swarm" ] || fail "T3: a refusal must not create data/swarm/<plan>"

# --- Case 2: the start --------------------------------------------------------------------------------------------------------
W2=$T/w2
mkworld "$W2"; strict "$W2"; mkplan "$W2/in"
M=$W2/main L=$W2/lead
assert_equals "1 1" "$(rc_of has_row "$M" jg-plan) $(rc_of has_row "$L" jg-plan)" "no plan row may exist before the start"
out=$(start "$M" "$W2/in/plan.json") || fail "start: $out"
assert_equals "swarm jg-plan: 5 slices filed and approved in main, lead1; 2 wait for the owner" "$(tail -n 1 <<< "$out")" "the start line"
DIR=$M/data/swarm/jg-plan DP=$M/data/swarm/jg-plan/plan.json
assert_equals "Main1" "$(jq -r '.owner_order' "$DP")" "T4: the derived plan must hold the plan's owner_order"
RA0=$(jq -r '.slices[] | select(.id == "a") | .row' "$DP") RE0=$(jq -r '.slices[] | select(.id == "e") | .row' "$DP")
assert_contains "$(at "$M" "$ROOT/bin/jg-backlog.sh" show "$RA0" --full)" "Owner order: Main1." "Main's filed row must name the owner order"
assert_contains "$(at "$L" "$ROOT/bin/jg-backlog.sh" show "$RE0" --full)" "Owner order: Main1." "the lead's filed row must name the owner order"
row() { jq -r --arg s "$1" '.slices[] | select(.id == $s) | .row' "$DP"; }
RA=$(row a) RB=$(row b) RD=$(row d) RE=$(row e) RF=$(row f)
assert_equals "0 0" "$(rc_of has_row "$M" jg-plan) $(rc_of has_row "$L" jg-plan)" "the plan row must be in both stores"
assert_equals "0 0 0 1" "$(rc_of has_row "$M" jg-plan-word-d) $(rc_of has_row "$M" jg-plan-word-f) $(rc_of has_row "$L" jg-plan-word-f) $(rc_of has_row "$L" jg-plan-word-d)" \
  "the word rows must be in Main (d and f) and in the lead (f only)"
assert_equals "$(printf '%s\n' jg-plan jg-plan-word-d jg-plan-word-f "$RA" "$RB" "$RD" | sort | tr '\n' ' ')" "$(row_ids "$M")" "Main's rows"
assert_equals "$(printf '%s\n' jg-plan jg-plan-word-f "$RE" "$RF" | sort | tr '\n' ' ')" "$(row_ids "$L")" "the lead's rows"
for pair in "$M:$RA:a" "$M:$RB:b" "$M:$RD:d" "$L:$RE:e" "$L:$RF:f"; do
  IFS=: read -r h r s <<< "$pair"
  shown=$(at "$h" "$ROOT/bin/jg-backlog.sh" show "$r" --full)
  assert_contains "$shown" "Make part $s of it" "slice $s's row title must be its slice title"
  for sec in '## Captain' '## Ask' '## Why' '## Done when' '## Acceptance Criteria'; do assert_contains "$shown" "$sec" "slice $s's body must have $sec"; done
  assert_contains "$shown" "Build slice $s, Make part $s of it, as its work order says." "slice $s's Ask"
  [ -e "$h/state/dispatch-approved/$r" ] || fail "slice $s must have an approval record"
done
assert_contains "$(at "$M" "$ROOT/bin/jg-backlog.sh" show "$RD" --full)" "linked-to: jg-plan-word-d" "D's body must end with its word row link"
assert_contains "$(at "$L" "$ROOT/bin/jg-backlog.sh" show "$RF" --full)" "linked-to: jg-plan-word-f" "F's body must end with its word row link"
assert_not_contains "$(at "$M" "$ROOT/bin/jg-backlog.sh" show "$RA" --full)" "linked-to:" "A has no word row link"
for r in jg-plan-word-d jg-plan-word-f; do [ ! -e "$M/state/dispatch-approved/$r" ] || fail "a word row must have no approval record"; done
[ ! -e "$L/state/dispatch-approved/jg-plan-word-f" ] || fail "the lead's word row must have no approval record"
for s in a b d; do [ -s "$M/data/$(row $s | tr . -)/brief.md" ] || fail "Main's slice $s must have a brief at the task path"; done
assert_equals "on" "$(cat "$M/config/auto-dispatch")" "Main's dispatch switch must be on"
assert_equals "2" "$(wc -l < "$T/card.log")" "two cards must be posted"
assert_contains "$(sed -n 1p "$T/card.log")" "--must design-pick --raised-by jg-plan-word-d --route main" "D's card"
assert_contains "$(sed -n 2p "$T/card.log")" "--must design-pick --raised-by jg-plan-word-f --route lead1" "F's card"
# T4: each card carries every board field: --why, one --outcome per option, --recommend-reason and --default.
assert_contains "$(sed -n 1p "$T/card.log")" '--option a=blue --option b=green --recommend a --why The owner picks before the work starts. --outcome a=We build blue. --outcome b=We build green. --recommend-reason It fits the rest of the page. --default a' "D's card must carry the why, both outcomes, the recommend reason and the default"
assert_contains "$(sed -n 2p "$T/card.log")" '--outcome a=We build small. --outcome b=We build large.' "F's card must carry its own outcomes"
assert_not_contains "$(cat "$T/card.log")" "--decision-key" "no card may carry a decision key"
assert_equals "card-1 card-2" "$(jq -r '[.slices[] | select(.owner_word != null) | .card] | join(" ")' "$DP")" "the derived plan must hold each card"
assert_equals "jg-plan-word-d jg-plan-word-f" "$(jq -r '[.slices[] | select(.owner_word != null) | .word_row] | join(" ")' "$DP")" "the derived plan must hold each word row"
assert_equals "1" "$(wc -l < "$T/send.log")" "one message must go to the lead"
assert_contains "$(cat "$T/send.log")" "lead1 Swarm jg-plan is routed to you. Run: bin/jg-swarm-arm.sh $DP" "the message must name the arm command and the derived plan"
assert_equals "running" "$(jq -r '.state' "$DIR/swarm.json")" "the record must say running"
assert_equals "checked copied plan-rows routed approved cards armed:main sent:lead1" "$(jq -r '.steps | join(" ")' "$DIR/swarm.json")" "every step must be recorded"
assert_equals "$M $L" "$(jq -r '"\(.main_home) \(.owner_homes.lead1)"' "$DP")" "the derived plan must name the homes"
for s in a b d e f; do
  o=$DIR/orders/$s.md
  [ -s "$o" ] && [ ! -w "$o" ] || fail "the order copy $o must exist and be read-only"
  assert_equals "$o" "$(jq -r --arg s "$s" '.slices[] | select(.id == $s) | .order_path' "$DP")" "slice $s's order path"
  assert_equals "Build part $s of it." "$(jq -r --arg s "$s" '.slices[] | select(.id == $s) | .goal' "$DP")" "slice $s's goal"
done

# --- Case 3: the chain, with the real hold check --------------------------------------------------------------------------------
hold() { rc_of at "$M" "$ROOT/bin/jg-captain-hold.sh" blocking "$1"; }
assert_equals "1 1 0" "$(hold "$RA") $(hold "$RB") $(hold "$RD")" "the open word must stop D only"
cat > "$T/spawn" <<SH
#!/usr/bin/env bash
t=\$1
[ -s "$M/data/\$t/brief.md" ] || { echo "no brief for \$t" >&2; exit 1; }
printf 'kind=ship\nticket=%s\n' "\$t" > "$M/state/\$t.meta"; printf 'working [at=1]: started\n' > "$M/state/\$t.status"
echo "\$t" >> "$T/started.log"
SH
printf '#!/usr/bin/env bash\necho ok\n' > "$T/reserve"; chmod +x "$T/spawn" "$T/reserve"
printf '25\n' > "$M/config/lane-target"
beat() {
  touch "$M/state/.last-watcher-beat"
  at "$M" env JG_AUTO_DISPATCH_SPAWN="$T/spawn" JG_AUTO_DISPATCH_RESERVE="$T/reserve" bash "$ROOT/core/auto-dispatch/dispatch.sh" check "$M" >/dev/null
  sleep 2
  sort -u "$T/started.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}
TA=${RA//./-} TB=${RB//./-} TD=${RD//./-}
assert_equals "$TA" "$(beat)" "the first beat must start A only"
printf 'done [at=2]: landed\n' >> "$M/state/$TA.status"
at "$M" "$ROOT/bin/jg-backlog.sh" "done" "$RA" >/dev/null || fail "A was not closed"
assert_equals "$TA $TB" "$(beat)" "after A landed the next beat must start B and not D"
assert_equals "an open decision is linked to it" "$(awk -F'\t' -v r="$RD" '$2 == r { x = $4 } END { print x }' "$M/data/auto-dispatch/rows.tsv")" "D's newest dispatch reason"
at "$M" "$ROOT/bin/jg-captain-hold.sh" design-pick "$(jq -r '.slices[] | select(.id == "d") | .card' "$DP")" --words "a" >/dev/null || fail "design-pick failed"
assert_equals "$TA $TB $TD" "$(beat)" "after the pick the next beat must start D"

# --- Case 4: safe twice, and a resume -----------------------------------------------------------------------------------------
out=$(start "$M" "$W2/in/plan.json"); rc=$?
assert_equals 2 "$rc" "a second start must exit 2"
assert_contains "$out" "status" "the refusal must name status"
before="$(rows_in "$M") $(rows_in "$L")"
jq '.state = "starting" | .steps = ["checked", "copied", "plan-rows", "routed"]' "$DIR/swarm.json" > "$DIR/swarm.json.new" && mv "$DIR/swarm.json.new" "$DIR/swarm.json"
jq '.slices |= map(if .card then .card = null else . end)' "$DP" > "$DP.new" && mv "$DP.new" "$DP"
printf '2\n' > "$T/card.base"
: > "$T/card.log"
out=$(start "$M" "$W2/in/plan.json") || fail "resume: $out"
assert_equals "swarm jg-plan: 5 slices filed and approved in main, lead1; 2 wait for the owner" "$(tail -n 1 <<< "$out")" "the resumed start line"
assert_equals "$before" "$(rows_in "$M") $(rows_in "$L")" "a resume must file no row again"
assert_equals "0 0 0" "$(rc_of has_row "$M" jg-plan-word-d) $(rc_of has_row "$M" jg-plan-word-f) $(rc_of has_row "$L" jg-plan-word-f)" "the word rows must stay"
assert_equals "2" "$(wc -l < "$T/card.log")" "a resume must post each card once"
assert_equals "running" "$(jq -r '.state' "$DIR/swarm.json")" "a resumed record must say running"

# --- Case 5: the route dry run refuses after the plan rows ----------------------------------------------------------------------
W5=$T/w5
mkworld "$W5"; mkplan "$W5/in"
M=$W5/main L=$W5/lead
: > "$L/config/backlog-intake-loose"
jg_test_add "$L" jg-plan "[feature] The plan"
for _ in 1 2; do   # two rows of the plan with slice e's title and no plan_slice: which one is the slice? (a stop twice, or a hand filing)
  at "$L" env JG_ROW_OWNER=lead1 "$ROOT/bin/jg-backlog.sh" add --parent jg-plan "[feature] Make part e of it" --repo proj --priority 2 \
    --body "$(printf '## Captain\nx\n## Ask\nx\n## Why\nx\n## Done when\nx\n## Acceptance Criteria\nx\n')" >/dev/null || fail "the row was not filed ahead"
done
strict "$W5"
before_lead=$(row_ids "$L")
out=$(start "$M" "$W5/in/plan.json"); rc=$?
assert_equals 1 "$rc" "a dry run refusal must exit 1: $out"
assert_contains "$out" "which one is the slice" "the filer's refusal must be named"
assert_equals "starting|checked copied plan-rows" "$(jq -r '"\(.state)|\(.steps | join(" "))"' "$M/data/swarm/jg-plan/swarm.json")" "the record must stop at plan-rows"
assert_equals "jg-plan jg-plan-word-d jg-plan-word-f " "$(row_ids "$M")" "Main must hold the plan row and the word rows, no slice"
assert_equals "$(printf '%s' "$before_lead" | tr ' ' '\n' | sed '/^$/d' | { cat; echo jg-plan-word-f; } | sort | tr '\n' ' ')" "$(row_ids "$L")" "the lead must gain only its word row"

# --- the detached run -----------------------------------------------------------------------------------------------------------
# <plan dir>: the pid the run's lock records (the test started that run), once the lock is taken; empty after <s> seconds.
lock_pid() {
  local _ p
  for _ in $(seq 1 "${2:-100}"); do
    p=$(cat "$1/.run.lock/pid" 2>/dev/null) && [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    sleep 0.1
  done
  return 1
}
reap_on_exit() {  # <pid>: the suite's cleanup stops the run's process group, as it does for a trunk-landing job
  printf '%s %s\n' "$1" "$(jg_test_pid_identity "$1" 2>/dev/null)" >> "$JG_TEST_DETACHED_REGISTRY"
}
wait_state() {  # <plan dir> <state> <seconds>
  local _
  for _ in $(seq 1 "$3"); do
    [ "$(jq -r '.state' "$1/swarm.json" 2>/dev/null)" = "$2" ] && return 0
    sleep 1
  done
  return 1
}
# The row ids a finished start leaves in Main, once each: the plan row, the two word rows and Main's slice rows.
expect_ids() {  # <the derived plan.json>
  { printf '%s\n' jg-plan jg-plan-word-d jg-plan-word-f; jq -r '.slices[] | select(.owner_home == "main") | .row' "$1"; } | sort | tr '\n' ' '
}

# --- Case 6: the start returns at once and runs detached; a second start does nothing ------------------------------------------------
W6=$T/w6
mkworld "$W6"; strict "$W6"; mkplan "$W6/in"
M=$W6/main L=$W6/lead DIR=$W6/main/data/swarm/jg-plan
: > "$T/send.log"; : > "$T/card.log"; rm -f "$T/card.base"
t0=$(date +%s)
out=$(JG_SWARM_STEP_DELAY=3 bgstart "$M" "$W6/in/plan.json"); rc=$?
t1=$(date +%s)
assert_equals 0 "$rc" "a start with no --wait must exit 0: $out"
[ $((t1 - t0)) -lt 10 ] || fail "the start must return within 10 s, it took $((t1 - t0)) s"
assert_equals "swarm jg-plan: started in the background; follow it with bin/jg-swarm-check.sh status jg-plan" "$out" "the start line"
RUNPID=$(lock_pid "$DIR") || fail "the background run never took its lock"
reap_on_exit "$RUNPID"
[ "$(jq -r '.state // "none"' "$DIR/swarm.json" 2>/dev/null || echo none)" != running ] || fail "the swarm must not be running yet: the start did not wait for the run"
out=$(bgstart "$M" "$W6/in/plan.json"); rc=$?
assert_equals 0 "$rc" "a start while a run holds the lock must exit 0: $out"
assert_equals "swarm jg-plan: already running (log data/swarm/jg-plan/start.log)" "$out" "the second start must say it is already running"
out=$(start "$M" "$W6/in/plan.json"); rc=$?
assert_equals 0 "$rc" "a --wait start while a run holds the lock must exit 0: $out"
assert_contains "$out" "already running" "a --wait start must say it is already running"
wait_state "$DIR" running 120 || fail "the background run never reached running: $(cat "$DIR/start.log" 2>/dev/null)"
assert_equals "checked copied plan-rows routed approved cards armed:main sent:lead1" "$(jq -r '.steps | join(" ")' "$DIR/swarm.json")" "the background run must record every step"
assert_equals "$(expect_ids "$DIR/plan.json")" "$(row_ids "$M")" "Main must hold each row once after the start and the second start"
assert_equals "1" "$(wc -l < "$T/send.log")" "the second start must send nothing more: one message to the lead"
assert_equals "2" "$(wc -l < "$T/card.log")" "the second start must post no card more"
[ ! -e "$DIR/.run.lock" ] || fail "a finished run must release its lock"
out=$(bgstart "$M" "$W6/in/plan.json"); rc=$?
assert_equals 2 "$rc" "a start of a running swarm must exit 2"
assert_contains "$out" "status" "the refusal must name status"

# --- Case 7: a run stopped part way is resumed by the next start -----------------------------------------------------------------------
W7=$T/w7
mkworld "$W7"; strict "$W7"; mkplan "$W7/in"
M=$W7/main L=$W7/lead DIR=$W7/main/data/swarm/jg-plan
: > "$T/send.log"; : > "$T/card.log"; rm -f "$T/card.base"
out=$(bgstart "$M" "$W7/in/plan.json") || fail "start: $out"
RUNPID=$(lock_pid "$DIR") || fail "the background run never took its lock"
reap_on_exit "$RUNPID"
for _ in $(seq 1 600); do   # after the second slice of Main is filed: the plan row, two word rows, two slices
  [ "$(rows_in "$M")" -ge 5 ] && break
  kill -0 "$RUNPID" 2>/dev/null || break
done
kill -KILL -- "-$RUNPID" 2>/dev/null || kill -KILL "$RUNPID" 2>/dev/null
sleep 1
kill -0 "$RUNPID" 2>/dev/null && fail "the run must be stopped"
assert_equals "starting" "$(jq -r '.state' "$DIR/swarm.json")" "a stopped run must leave the record at starting"
case " $(jq -r '.steps | join(" ")' "$DIR/swarm.json") " in *" approved "*) fail "the stop came after the run ended; the test needs it part way" ;; esac
out=$(bgstart "$M" "$W7/in/plan.json"); rc=$?
assert_equals 0 "$rc" "the start after a stop must exit 0: $out"
assert_equals "swarm jg-plan: started in the background; follow it with bin/jg-swarm-check.sh status jg-plan" "$out" "the resume start line"
RUNPID=$(lock_pid "$DIR") && reap_on_exit "$RUNPID"
wait_state "$DIR" running 120 || fail "the resumed run never reached running: $(cat "$DIR/start.log" 2>/dev/null)"
assert_equals "$(expect_ids "$DIR/plan.json")" "$(row_ids "$M")" "every slice of Main must be filed once after the resume"
assert_equals "$({ printf '%s\n' jg-plan jg-plan-word-f; jq -r '.slices[] | select(.owner_home == "lead1") | .row' "$DIR/plan.json"; } | sort | tr '\n' ' ')" "$(row_ids "$L")" \
  "every slice of the lead must be filed once after the resume"
assert_equals "1" "$(wc -l < "$T/send.log")" "the lead must be told once"
assert_equals "2" "$(wc -l < "$T/card.log")" "each card must be posted once"

# --- Case 8: --order alone names the order; it wins over the plan's owner_order -------------------------------------------------------
W8=$T/w8
mkworld "$W8"; strict "$W8"; mkplan "$W8/in"
M=$W8/main L=$W8/lead
: > "$T/send.log"; : > "$T/card.log"; rm -f "$T/card.base"
at "$M" "$ROOT/bin/jg-backlog.sh" add jg-ask "[captain-ask] Run the swarm" --kind ship --repo proj --priority 0 \
  --body "$(printf '## Captain\nx\n\n## Ask\nx\n\n## Why\nx\n\n## Done when\nx\n\n## Acceptance Criteria\nx\n')" >/dev/null || fail "the [captain-ask] row was not filed"
out=$(start "$M" "$W8/in/plan.json" --order jg-ask) || fail "start with --order: $out"
assert_equals "jg-ask" "$(jq -r '.owner_order' "$M/data/swarm/jg-plan/plan.json")" "T4: --order must win over the plan's owner_order"
assert_contains "$(at "$M" "$ROOT/bin/jg-backlog.sh" show "$(jq -r '.slices[0].row' "$M/data/swarm/jg-plan/plan.json")" --full)" "Owner order: jg-ask." "the row must name the --order"

pass "swarm start: refusals write nothing; files, approves, briefs and arms; the chain starts each slice in its turn; safe twice and resumable; the dry run refuses after the plan rows; the start runs detached and a stopped run resumes"
