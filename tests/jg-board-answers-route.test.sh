#!/usr/bin/env bash
# tests/jg-board-answers-route.test.sh - an answer to a card nobody routed still reaches the task
# that asked, found from the card's name (jg-board-answers.sh), and a post always writes its route
# (jg-question-card.sh). Replay of card fable-why-no-landing-wave1, 10 Nov: no route file, so the
# answer reached no task and cost 1 hour 40 minutes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-board-answers-route)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
BA="$ROOT/bin/jg-board-answers.sh"
CARD="$ROOT/bin/jg-question-card.sh"
OWNER=fable-why-no-landing
KEY=fable-why-no-landing-wave1
AT=2026-11-10T08:31:00Z

setup() {  # <name> -> the case dir: a home with the owning task, a lookalike task and a fake board
  local d=$TMP_ROOT/$1 t
  mkdir -p "$d/home/state" "$d/fakebin" "$d/so/.sign-off"
  printf '{"schema":2,"items":[]}\n' > "$d/so/.sign-off/decisions.json"
  : > "$d/so/.sign-off/decisions.answers.jsonl"
  printf '#!/usr/bin/env bash\nexit 0\n' | tee "$d/fakebin/tmux" > "$d/fakebin/sleep"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
case "$cmd" in
  answers) jq -s 'reduce .[] as $a ({}; .[$a.key] = ($a | del(.key)))' "${board%.json}.answers.jsonl" ;;
  list) jq -c '{decisions: [.items[] | {key}]}' "$board" ;;
  raise) k=$(printf '%s\n' "$*" | sed 's/.*--title \([^ ]*\).*/\1/' | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '-')
    jq --arg k "jg-${k%-}" '.items += [{key: $k}]' "$board" > "$board.tmp" && mv "$board.tmp" "$board" ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  for t in "$OWNER" "$OWNER-critic52"; do
    jg_write_meta "$d/home/state/$t.meta" "window=sess:jg-$t" "endpoint_task_id=$t" "worktree=$d/home"
  done
  printf '%s\n' "$d"
}

run() {  # <case-dir> <command...>
  local d=$1
  shift
  env PATH="$d/fakebin:$PATH" JG_HOME="$d/home" JG_ROOT_OVERRIDE="$d/home" SIGN_OFF_HOME="$d/so" JG_SEND_SETTLE=0 "$@" 2>&1
}

answer() {  # <case-dir> <key> <value>
  printf '{"key":"%s","answer":"%s","label":"%s","close":"done","at":"%s"}\n' "$2" "$3" "$3" "$AT" >> "$1/so/.sign-off/decisions.answers.jsonl"
}

test_unrouted_answer_reaches_the_task_its_card_names() {
  local d out
  d=$(setup unrouted)
  answer "$d" old-card no   # on the board at the first pass: recorded, never sent
  run "$d" "$BA" check > /dev/null
  answer "$d" "$KEY" yes
  out=$(run "$d" "$BA" check)
  assert_contains "$(cat "$d/home/state/$OWNER.inbox/001.msg" 2>/dev/null)" "board-answer [key=$KEY at=$AT]: the captain answered \"yes\"" \
    "the answer did not reach the owning task: $out"
  [ ! -e "$d/home/state/$OWNER-critic52.inbox" ] || fail "the lookalike task got the answer"
  [ ! -s "$d/home/state/.wake-queue" ] || fail "Main was woken for an answer that had an owner: $(cat "$d/home/state/.wake-queue")"
  assert_equals "info: board answer \"yes\" on $KEY went to $OWNER; nothing for Main to do" "$out" "Main did not get exactly one info line"
  assert_equals $'lead='"$OWNER"$'\ndecision='"$KEY" "$(sed -n '1,2p' "$d/home/state/board-routes/$KEY")" "the found owner was not recorded as the card's route"
  pass "an answer with no route file lands in the inbox of the task named by the longest id prefix of its card, and Main gets nothing"
}

test_a_card_no_task_names_still_wakes_main() {
  local d
  d=$(setup nobody)
  run "$d" "$BA" check > /dev/null
  answer "$d" unrelated-card yes
  run "$d" "$BA" check > /dev/null
  grep -q "board-answer-unmapped-unrelated-card-$AT" "$d/home/state/.wake-queue" || fail "an answer with no owning task did not wake Main"
  pass "an answer whose card names no task still wakes Main"
}

test_a_post_always_writes_its_route() {
  local d out
  d=$(setup post)
  out=$(run "$d" "$CARD" post --route main --title "Wave one for the owner?" --ask-ref jg-m1 --must plan-approval \
    --outcome yes="It is." --outcome no="It is not." 2>/dev/null)
  out=$(jq -r '.items[0].key' "$d/so/.sign-off/decisions.json")
  assert_equals owner=main "$(cat "$d/home/state/board-routes/$out" 2>/dev/null)" "a post with --route main wrote no route file"
  out=$(run "$d" "$CARD" post --title "Q for the task?" --ask-ref "$OWNER" --must plan-approval \
    --outcome yes="It is." --outcome no="It is not." 2>/dev/null)
  assert_equals "$OWNER" "$(sed -n 's/^lead=//p' "$d/home/state/board-routes/$(jq -r '.items[1].key' "$d/so/.sign-off/decisions.json")")" "a post that found its task wrote no route file"
  pass "a card posted with jg-question-card.sh always writes its route file, for a task and for Main"
}

test_unrouted_answer_reaches_the_task_its_card_names
test_a_card_no_task_names_still_wakes_main
test_a_post_always_writes_its_route
