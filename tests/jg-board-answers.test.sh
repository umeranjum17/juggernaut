#!/usr/bin/env bash
# tests/jg-board-answers.test.sh - a board answer reaches the lead that owns the card
# without Main (jg-board-answers.sh, jg-question-card --route), over the real jg-send.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-board-answers)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
BA="$ROOT/bin/jg-board-answers.sh"
CARD="$ROOT/bin/jg-question-card.sh"
KEY=put-the-key-into-muxr
AT=2026-10-29T17:19:09Z

setup() {  # <name> -> echoes the case dir; muxr is a squad_lead with an open decision
  local d=$TMP_ROOT/$1
  mkdir -p "$d/home/state" "$d/fakebin" "$d/so/.sign-off"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  printf '#!/usr/bin/env bash\nexit 0\n' | tee "$d/fakebin/tmux" > "$d/fakebin/sleep"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  answers) jq -s 'reduce .[] as $a ({}; .[$a.key] = ($a | del(.key)))' "${board%.json}.answers.jsonl" ;;
  dismiss) echo "dismiss $*" >> "$SIGNOFF_LOG" ;;
  list) jq -c '{decisions: [.items[] | {key}]}' "$board" ;;
  raise) k=$(printf '%s\n' "$*" | sed 's/.*--title \([^ ]*\).*/\1/')
    jq --arg k "$k" '.items += [{key: $k}]' "$board" > "$board.tmp" && mv "$board.tmp" "$board" ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  jg_write_squad_lead_meta "$d/home/state/muxr.meta" "$d/home" "sess:jg-muxr"
  printf 'needs-decision [key=%s]: use the key?\n' "$KEY" > "$d/home/state/muxr.status"
  : > "$d/so/.sign-off/decisions.answers.jsonl"
  printf '%s\n' "$d"
}

run() {  # <case-dir> <script> args...
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" SIGN_OFF_HOME="$d/so" \
    SIGNOFF_LOG="$d/signoff.log" JG_SEND_SETTLE=0 "$@" 2>&1
}

answer() {  # <case-dir> <key> <value> [at]
  printf '{"key":"%s","answer":"%s","label":"%s","close":"done","at":"%s"}\n' "$2" "$3" "$3" "${4:-$AT}" \
    >> "$1/so/.sign-off/decisions.answers.jsonl"
}

# `post` prints the card key alone on stdout and its own diagnostics, including
# the card-rule measurement, on stderr, so a key read from the merged streams is
# a diagnostic line the moment the measurement has anything to say.
run_key() {  # <case-dir> <command...> -> the command's stdout alone
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" SIGN_OFF_HOME="$d/so" \
    SIGNOFF_LOG="$d/signoff.log" JG_SEND_SETTLE=0 "$@" 2>/dev/null
}

test_routed_answer_reaches_the_lead_and_closes_its_decision() {
  local d out rec
  d=$(setup routed)
  run "$d" "$BA" route "$KEY" muxr
  answer "$d" "$KEY" yes
  out=$(run "$d" "$BA" check)
  rec=$d/home/state/muxr.inbox/001.msg
  [ -f "$rec" ] || fail "the answer never reached the lead's inbox: $out"
  assert_contains "$(cat "$rec")" "board-answer [key=$KEY at=$AT]: the captain answered \"yes\"" "the marked answer line is wrong"
  assert_grep "resolved [key=$KEY]" "$d/home/state/muxr.status" "the lead decision key stayed open"
  assert_equals "info: board answer \"yes\" on $KEY went to muxr; nothing for Main to do" "$out" "Main did not get exactly one info line"
  out=$(run "$d" "$BA" check)
  [ -z "$out" ] || fail "a second pass repeated the delivery: $out"
  [ ! -f "$d/home/state/muxr.inbox/002.msg" ] || fail "a second pass wrote a second record"
  pass "a routed answer lands in the lead's inbox, closes its decision key, and tells Main only by info"
}

test_card_archives_after_the_lead_acknowledges() {
  local d
  d=$(setup archive)
  run "$d" "$BA" route "$KEY" muxr
  answer "$d" "$KEY" yes
  run "$d" "$BA" check > /dev/null
  run "$d" "$BA" check > /dev/null
  [ ! -s "$d/signoff.log" ] || fail "the card was archived before the lead acknowledged"
  mkdir -p "$d/home/state/muxr.inbox/handled"
  mv "$d/home/state/muxr.inbox/001.msg" "$d/home/state/muxr.inbox/handled/"
  run "$d" "$BA" check > /dev/null
  run "$d" "$BA" check > /dev/null
  assert_equals "dismiss $KEY $d/so/.sign-off/decisions.json --reason done-elsewhere" "$(cat "$d/signoff.log")" \
    "the acknowledged card was not archived exactly once"
  pass "the card archives once the lead moves the record to handled/"
}

test_unrouted_answer_wakes_main_with_the_answer_first() {
  local d out
  d=$(setup unrouted)
  answer "$d" old-card no 2026-10-01T00:00:00Z
  out=$(run "$d" "$BA" check)
  [ -z "$out" ] || fail "an answer already on the board at the first pass was reported: $out"
  answer "$d" free-card "ship it"
  out=$(run "$d" "$BA" check)
  case "$out" in
    "ship it ("*") | board answer on free-card at $AT, not routed to a lead"*) : ;;
    *) fail "the unrouted wake line does not lead with the answer: $out" ;;
  esac
  out=$(run "$d" "$BA" check)
  [ -z "$out" ] || fail "an unrouted answer was reported twice: $out"
  pass "an unrouted answer wakes Main once, answer text first; old answers stay quiet"
}

test_failed_delivery_is_retried_and_reported_once() {
  local d out
  d=$(setup retry)
  run "$d" "$BA" route "$KEY" muxr
  run "$d" "$BA" check > /dev/null
  mv "$d/home/state/muxr.meta" "$d/muxr.meta"
  answer "$d" "$KEY" yes
  out=$(run "$d" "$BA" check)
  assert_contains "$out" "could not reach muxr" "a failed delivery was not reported"
  out=$(run "$d" "$BA" check)
  [ -z "$out" ] || fail "a failed delivery was reported twice: $out"
  mv "$d/muxr.meta" "$d/home/state/muxr.meta"
  out=$(run "$d" "$BA" check)
  assert_contains "$out" "went to muxr" "the retry did not deliver"
  pass "a failed delivery is reported once and retried until it lands"
}

test_question_card_route_records_the_owner() {
  local d out
  d=$(setup card)
  out=$(run_key "$d" "$CARD" post --route muxr --decision-key use-key --title "Q for muxr?" --ask-ref m1 --must design-pick \
    --outcome yes="It is." --outcome no="It is not.")
  assert_equals $'lead=muxr\ndecision=use-key' "$(cat "$d/home/state/board-routes/$out")" "the route was not recorded under the printed card key"
  out=$(run "$d" "$CARD" post --route ghost --title "Q2?" --ask-ref m1 --must design-pick \
    --outcome yes="It is." --outcome no="It is not.") && fail "a route to an unknown lead was accepted"
  [ "$(jq '.items | length' "$d/so/.sign-off/decisions.json")" = 1 ] || fail "a refused route still posted a card"
  run "$d" "$CARD" post --decision-key x --title "Q3?" --ask-ref m1 --must design-pick --outcome yes="It is." --outcome no="It is not." > /dev/null && fail "--decision-key without --route was accepted"
  pass "jg-question-card post --route records the owning lead and refuses an unknown one before posting"
}

test_arm_registers_a_check_the_watcher_trusts() {
  local d
  d=$(setup arm)
  run "$d" "$BA" arm > /dev/null || fail "arm failed"
  [ -x "$d/home/state/board-answers.check.sh" ] && [ -f "$d/home/state/board-answers.check-trust" ] || fail "arm left no registered check"
  bash -c '. "$1/bin/jg-pr-lib.sh"; . "$1/bin/jg-check-lib.sh"; jg_custom_check_registered "$2" board-answers' _ "$ROOT" "$d/home/state" \
    || fail "the watcher would reject the armed check"
  run "$d" "$BA" disarm > /dev/null; [ ! -e "$d/home/state/board-answers.check.sh" ] || fail "disarm left the shim"
  pass "arm writes a check the watcher accepts; disarm removes it"
}

test_routed_answer_reaches_the_lead_and_closes_its_decision
test_card_archives_after_the_lead_acknowledges
test_unrouted_answer_wakes_main_with_the_answer_first
test_failed_delivery_is_retried_and_reported_once
test_question_card_route_records_the_owner
test_arm_registers_a_check_the_watcher_trusts
