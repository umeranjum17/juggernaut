#!/usr/bin/env bash
# tests/jg-answer-route.test.sh - an answered card's options become work, or one named other end.
#
# Journeys through the real commands only: bin/jg-answer-route.sh, the real bin/jg-backlog.sh
# (add, task, approve-dispatch), the real bin/jg-brief.sh, the real bin/jg-captain-hold.sh and
# the real core/auto-dispatch/dispatch.sh check. Only the board tool (sign-off-axi) is a
# stand-in, because the board file and its answers journal are the fixture.
#
# T1 a worker option: one ticket, one filled brief, one approval, one route row, and the
#    dispatch check reads the ticket as "would start".
# T2 an option with no executor field: one supervisor step, no ticket.
# T3 an option whose text discards work, with the card saying worker: one supervisor step
#    carrying the owner's answer, no ticket.
# T4 a dated deferral: one owner ticket filed and held to the date it names, no approval.
# T5 a status-quo option: recorded as a no-op, nothing filed.
# T6 the same answer again: a quiet duplicate, no second ticket and no second row.
# T7 an answer that names no option: exit 3, one supervisor line, the answer never guessed at.
# T8 answer time: the real board-answer check routes the answer it reads, with no model turn.
# T9 the executor field: jg-question-card.sh post records it beside the board, and refuses one
#    that names no option of the card.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-answer-route)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
ROUTE="$ROOT/bin/jg-answer-route.sh"
CHECK="$ROOT/core/auto-dispatch/dispatch.sh"
CARD="$ROOT/bin/jg-question-card.sh"
ANSWERS="$ROOT/bin/jg-board-answers.sh"
AT=2026-11-16T09:00:00Z
ATE=1794819600   # AT in epoch seconds

# The board tool: `list` reads the fixture board, `answers` reads its answers journal, `raise`
# appends the card a post names, and the rest is a logged no-op.
fake_signoff() {  # <case dir>
  cat > "$1/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=${SIGN_OFF_HOME:?}/.sign-off/decisions.json
case "$cmd" in
  list) jq -c '{decisions: (.items // [])}' "$board" ;;
  answers)
    [ -f "${board%.json}.answers.jsonl" ] || { echo '{}'; exit 0; }
    jq -s 'reduce .[] as $a ({}; .[$a.key] = ($a | del(.key)))' "${board%.json}.answers.jsonl" ;;
  raise)
    key=$(printf '%s\n' "$*" | sed -n 's/.*--key \([^ ]*\).*/\1/p')
    [ -n "$key" ] || key=jg-posted-$$-$(date +%s%N)
    opts=$(printf '%s\n' "$*" | sed -n 's/.*--option \([^ ]*\).*/\1/p')
    detail=$(printf '%s\n' "$*" | sed -n 's/.*--detail \(.*\)/\1/p')
    jq -c --arg k "$key" --arg d "$detail" '.items += [{key: $k, detail: $d, title: "fixture card"}]' "$board" > "$board.tmp" \
      && mv "$board.tmp" "$board"
    printf '%s\n' "$key" ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$1/fakebin/sign-off-axi"
}

# setup <name>: a home with a real store, one registered project and a fixture board.
setup() {  # <name> -> echoes the case dir
  local d=$TMP_ROOT/$1 proj
  mkdir -p "$d/home/data" "$d/home/state" "$d/home/config" "$d/home/projects" "$d/fakebin" "$d/so/.sign-off"
  d=$(cd "$d" && pwd)
  proj=$d/home/projects/demo
  mkdir -p "$proj"
  printf 'v1\n' > "$proj/README.md"
  git -C "$proj" init -q 2>/dev/null
  git -C "$proj" add -A >/dev/null 2>&1
  git -C "$proj" -c user.email=t@example.com -c user.name=t commit -qm v1 >/dev/null 2>&1
  printf -- '- demo [local-trunk +yolo] - the one project (added 2026-11-01)\n' > "$d/home/data/projects.md"
  printf '%s\n' '{"rules": [{"when": "Execute an approved ordinary implementation plan with a clear path.", "use": {"harness": "codex", "model": "gpt-5.2-codex"}}], "default": {}}' \
    > "$d/home/config/crew-dispatch.json"
  printf '2\n' > "$d/home/config/lane-target"
  printf '{"schema": 2, "items": []}\n' > "$d/so/.sign-off/decisions.json"
  : > "$d/so/.sign-off/decisions.answers.jsonl"
  jg_test_beads_home "$d/home" >/dev/null 2>&1 || true
  fake_signoff "$d"
  printf '%s\n' "$d"
}

# A card on the fixture board: <dir> <key> <detail> <option value=outcome>...
card() {  # <dir> <key> <detail> <option>...
  local d=$1 key=$2 detail=$3
  shift 3
  python3 - "$d/so/.sign-off/decisions.json" "$key" "$detail" "$@" <<'PY'
import json, sys
board, key, detail, options = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
data = json.load(open(board))
data.setdefault("items", []).append({
    "key": key, "title": "fixture card " + key, "detail": detail,
    "ask_ref": "call-" + key,
    "options": [{"value": o.split("=", 1)[0], "label": o.split("=", 1)[0].upper(),
                 "outcome": o.split("=", 1)[1]} for o in options],
})
json.dump(data, open(board, "w"))
PY
  jg_test_add "$d/home" "call-$key" "[feature] the call the card answers" --repo demo
}

run() {  # <dir> <command...>
  # The dispatch check reads its own commands from the home, and a fixture home has no bin/:
  # every command it calls is named here, as tests/jg-auto-dispatch.test.sh names them.
  local d=$1
  shift
  env -u JG_TASK_ID PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" \
    SIGN_OFF_HOME="$d/so" \
    JG_AUTO_DISPATCH_BACKLOG="$ROOT/bin/jg-backlog.sh" JG_AUTO_DISPATCH_HOLD="$ROOT/bin/jg-captain-hold.sh" \
    JG_AUTO_DISPATCH_SPAWN="$ROOT/bin/jg-spawn.sh" JG_AUTO_DISPATCH_PROJECT_MODE="$ROOT/bin/jg-project-mode.sh" \
    JG_AUTO_DISPATCH_ALERT="$ROOT/bin/jg-alert.sh" JG_AUTO_DISPATCH_RESERVE="$ROOT/core/pool-reserve/reserve.sh" \
    JG_AUTO_DISPATCH_SCALE="$ROOT/core/lane-scale/scale.sh" \
    "$@" 2>&1
}

route() {  # <dir> <key> <answer> [extra args...]
  local d=$1 key=$2 answer=$3
  shift 3
  run "$d" "$ROUTE" route "$key" --answer "$answer" --at "$AT" "$@"
}

rows() {  # <dir> <key>
  cat "$1/home/data/answer-route/$2.tsv" 2>/dev/null
}

tickets() {  # <dir> -> the ids in this home's store
  (cd "$1/home" && JG_HOME="$1/home" JG_CONFIG_OVERRIDE="$1/home/config" "$ROOT/bin/jg-backlog.sh" list 2>/dev/null \
    | sed -n 's/^ *\([a-z0-9._-]*\),.*/\1/p')
}

t1_worker_option_files_a_ticket_brief_and_approval() {
  local d out id
  d=$(setup t1)
  card "$d" card-worker "" "a=Build the connectors slice now" "b=Leave the connectors for later"
  # The executor field is what makes an option a worker's; it is written by the card's own post
  # path, and this fixture writes the same text that path records.
  python3 - "$d/so/.sign-off/decisions.json" <<'PY'
import json, sys
p = sys.argv[1]; data = json.load(open(p))
data["items"][0]["detail"] = "executor a=worker"
json.dump(data, open(p, "w"))
PY
  out=$(route "$d" card-worker a)
  case "$out" in *"start card-worker [a]"*) ;; *) fail "T1 the answer did not start: $out" ;; esac
  id=card-worker-a
  tickets "$d" | grep -qx -- "$id" || fail "T1 no ticket $id was filed: $(tickets "$d")"
  [ -s "$d/home/data/$id/brief.md" ] || fail "T1 no brief was written at data/$id/brief.md"
  grep -qF 'Build the connectors slice now' "$d/home/data/$id/brief.md" || fail "T1 the brief does not carry the option's own text"
  grep -qF '{TASK}' "$d/home/data/$id/brief.md" && fail "T1 the brief still holds its scaffold placeholder"
  grep -q '^Delivery contract: mode=local-trunk' "$d/home/data/$id/brief.md" || fail "T1 the brief carries no delivery contract"
  grep -q '^harness=codex$' "$d/home/state/dispatch-approved/$id" || fail "T1 no approval record names the home's route"
  rows "$d" card-worker | grep -qF "$ATE" || fail "T1 no route row was written"
  # The real starter reads that approval and that brief: watch only, it starts nothing.
  out=$(run "$d" "$CHECK" check "$d/home")
  grep -qF "	$id	would start	" "$d/home/data/auto-dispatch/rows.tsv" 2>/dev/null \
    || fail "T1 the dispatch check does not read the ticket as startable: $(cat "$d/home/data/auto-dispatch/rows.tsv" 2>/dev/null); $out"
  pass "T1 a worker option files one ticket, writes its brief and approves the start the dispatch check reads"
}

t2_no_executor_field_is_a_supervisor_step() {
  local d out before after
  d=$(setup t2)
  card "$d" card-noexec "" "a=Build the connectors slice now" "b=Leave the connectors for later"
  before=$(tickets "$d")
  out=$(route "$d" card-noexec a)
  case "$out" in *"supervisor card-noexec [a]"*"names no executor"*) ;; *) fail "T2 a card with no executor is not a supervisor step: $out" ;; esac
  after=$(tickets "$d")
  [ "$before" = "$after" ] || fail "T2 a supervisor step filed a ticket: $after"
  [ ! -e "$d/home/state/dispatch-approved/card-noexec-a" ] || fail "T2 a supervisor step approved a start"
  pass "T2 a card with no executor field is one supervisor step and starts nothing"
}

t3_a_destructive_option_never_starts() {
  local d out
  d=$(setup t3)
  card "$d" card-clean "executor b=worker" \
    "a=Keep the branch" "b=Force-discard the 42 stale items now, losing their unlanded work"
  out=$(route "$d" card-clean b)
  case "$out" in *"supervisor card-clean [b]"*) ;; *) fail "T3 a destructive option is not a supervisor step: $out" ;; esac
  case "$out" in *'Force-discard the 42 stale items now'*) ;; *) fail "T3 the supervisor step does not carry the option's text: $out" ;; esac
  [ ! -e "$d/home/state/dispatch-approved/card-clean-b" ] || fail "T3 a destructive option approved a start"
  pass "T3 an option that discards work goes to the supervisor whatever the card says"
}

t4_a_dated_deferral_becomes_a_held_owner_ticket() {
  local d out id
  d=$(setup t4)
  card "$d" card-defer "executor a=worker" \
    "a=Rely on the resolver for one week, then decide from the M4 forecast data"
  out=$(route "$d" card-defer a)
  case "$out" in *"owner-ticket card-defer [a]"*) ;; *) fail "T4 the deferral was not filed as an owner ticket: $out" ;; esac
  id=card-defer-a-defer
  tickets "$d" | grep -qx -- "$id" || fail "T4 no owner ticket $id was filed: $(tickets "$d")"
  (cd "$d/home" && JG_HOME="$d/home" JG_CONFIG_OVERRIDE="$d/home/config" "$ROOT/bin/jg-backlog.sh" show "$id" 2>/dev/null) \
    | grep -q 'held: yes' || fail "T4 the owner ticket is not held"
  (cd "$d/home" && JG_HOME="$d/home" JG_CONFIG_OVERRIDE="$d/home/config" "$ROOT/bin/jg-backlog.sh" show "$id" 2>/dev/null) \
    | grep -q 'hold_until: 2026-11-23' || fail "T4 the owner ticket is not held to the date the option names"
  [ ! -e "$d/home/state/dispatch-approved/$id" ] || fail "T4 a dated deferral approved a start"
  pass "T4 a dated deferral is one owner ticket held to its date, never a start"
}

t5_a_status_quo_option_is_recorded_only() {
  local d out before after
  d=$(setup t5)
  card "$d" card-noop "executor a=worker" "a=Keep the one-commit replay" "b=Allow merge commits again"
  before=$(tickets "$d")
  out=$(route "$d" card-noop a)
  case "$out" in *"no-op card-noop [a]"*) ;; *) fail "T5 a status-quo option is not a recorded no-op: $out" ;; esac
  after=$(tickets "$d")
  [ "$before" = "$after" ] || fail "T5 a no-op filed a ticket: $after"
  pass "T5 a status-quo option is recorded as a no-op and files nothing"
}

t6_the_same_answer_is_a_quiet_duplicate() {
  local d out first second
  d=$(setup t6)
  card "$d" card-dup "executor a=worker" "a=Build the connectors slice now" "b=Leave the connectors for later"
  route "$d" card-dup a >/dev/null
  first=$(rows "$d" card-dup | wc -l)
  out=$(route "$d" card-dup a)
  second=$(rows "$d" card-dup | wc -l)
  [ -z "$out" ] || fail "T6 a repeat of the same answer is not quiet: $out"
  [ "$first" = "$second" ] || fail "T6 the repeat wrote another route row: $first -> $second"
  [ "$(tickets "$d" | grep -c '^card-dup')" = 1 ] || fail "T6 the repeat filed a second ticket"
  pass "T6 the same answer routes once: a repeat is a quiet duplicate"
}

t7_an_unreadable_answer_reaches_the_lead() {
  local d out code
  d=$(setup t7)
  card "$d" card-odd "executor a=worker" "a=Build the connectors slice now" "b=Leave the connectors for later"
  out=$(route "$d" card-odd "maybe later I think")
  code=$?
  [ "$code" = 3 ] || fail "T7 an answer that names no option should exit 3, got $code: $out"
  case "$out" in *"supervisor card-odd"*"names no option"*) ;; *) fail "T7 the unreadable answer is not reported: $out" ;; esac
  rows "$d" card-odd | grep -q 'unreadable' || fail "T7 no route row records the unreadable answer"
  [ ! -e "$d/home/state/dispatch-approved/card-odd-a" ] || fail "T7 an unreadable answer approved a start"
  pass "T7 an answer that names no option is reported to the lead, never guessed at"
}

t8_the_board_answer_check_routes_the_answer_it_reads() {
  local d out
  d=$(setup t8)
  card "$d" card-live "executor a=worker" "a=Build the connectors slice now" "b=Leave the connectors for later"
  printf '{"key":"card-live","answer":"a","label":"A","close":"done","at":"%s"}\n' "$AT" \
    >> "$d/so/.sign-off/decisions.answers.jsonl"
  out=$(run "$d" "$ANSWERS" check)
  [ -s "$d/home/data/card-live-a/brief.md" ] || fail "T8 the answer-time check did not start the option: $out"
  case "$out" in *"answer-route start card-live [a]"*) ;; *) fail "T8 the check did not report the route it took: $out" ;; esac
  pass "T8 the real board-answer check routes an answer at answer time, with no model turn"
}

t9_the_card_post_records_the_executor_beside_the_board() {
  local d out record refusal
  d=$(setup t9)
  # A card posted on this board must carry its must category (the when-it-matters leash), and
  # the executor field rides beside it in the same detail field.
  out=$(run "$d" "$CARD" post --route main --ask-ref jg-t9 --title "Which slice should go next?" \
    --must plan-approval --option a="Build it now" --option b="Leave it parked" --executor a=worker 2>&1)
  case "$out" in jg-*|*'jg-'*) ;; *) fail "T9 the card post printed no key: $out" ;; esac
  record="$d/so/.sign-off/decisions.card-detail.jsonl"
  [ -f "$record" ] || fail "T9 the post recorded no detail beside the board"
  grep -q 'executor a=worker' "$record" || fail "T9 the executor field is not recorded beside the board: $(cat "$record")"
  refusal=$(run "$d" "$CARD" post --route main --ask-ref jg-t9 --title "Which other slice should go next?" \
    --must plan-approval --option a="Build it now" --option b="Leave it parked" --executor c=worker 2>&1)
  case "$refusal" in *"names no --option of this card"*) ;; *) fail "T9 an executor naming no option was not refused: $refusal" ;; esac
  pass "T9 the card post records each option's executor beside the board and refuses an unknown option"
}

# One store template for every case: a case copies it, so no two cases initialise it at once.
jg_test_beads_home "$TMP_ROOT/warm/home"

jg_test_run_cases \
  t1_worker_option_files_a_ticket_brief_and_approval \
  t2_no_executor_field_is_a_supervisor_step \
  t3_a_destructive_option_never_starts \
  t4_a_dated_deferral_becomes_a_held_owner_ticket \
  t5_a_status_quo_option_is_recorded_only \
  t6_the_same_answer_is_a_quiet_duplicate \
  t7_an_unreadable_answer_reaches_the_lead \
  t8_the_board_answer_check_routes_the_answer_it_reads \
  t9_the_card_post_records_the_executor_beside_the_board
