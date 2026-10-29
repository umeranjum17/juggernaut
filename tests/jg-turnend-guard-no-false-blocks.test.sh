#!/usr/bin/env bash
# tests/jg-turnend-guard-no-false-blocks.test.sh - the turn-end guard must stay
# silent on the two shapes that used to print a false block at every turn end:
# a reply that ends in a question, and a captain chat answer whose card waits.
# No model call.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/jg-question-lib.sh"

TMP_ROOT=$(jg_test_tmproot jg-turnend-guard-no-false-blocks)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
jg_git_identity fmtest fmtest@example.invalid
KEY=use-the-repo-card
WORDS="yes, go ahead and use the repo card"

setup() {  # <name> -> case dir: an in-scope primary home holding one open card
  local d=$TMP_ROOT/$1
  mkdir -p "$d/state" "$d/fakebin" "$d/so/.sign-off" "$d/bin" "$d/docs"
  printf '{"schema":2,"items":[{"key":"%s","close":"done"}]}\n' "$KEY" > "$d/so/.sign-off/decisions.json"
  : > "$d/so/.sign-off/decisions.answers.jsonl"
  cat > "$d/fakebin/sign-off-axi" <<'SH'
#!/usr/bin/env bash
cmd=$1; shift
board=$SIGN_OFF_HOME/.sign-off/decisions.json
log=${board%.json}.answers.jsonl
case "$cmd" in
  answers) jq -s 'reduce .[] as $a ({}; .[$a.key] = ($a | del(.key)))' "$log" ;;
  list) jq -c --slurpfile a <(jq -s 'map(.key)' "$log") '{decisions: [.items[] | select(.key as $k | ($a[0] | index($k)) | not) | {key}]}' "$board" ;;
esac
SH
  chmod +x "$d/fakebin/sign-off-axi"
  git init -q "$d"
  git -C "$d" commit -q --allow-empty -m init
  : > "$d/AGENTS.md"
  cp "$ROOT"/bin/*.sh "$d/bin/"
  cp -R "$ROOT/docs/supervision-protocols" "$d/docs/supervision-protocols"
  printf '%s\n' "$d"
}

run_guard() {  # <case-dir> <transcript> -> guard output, exit status in $status
  local d=$1
  printf '{"stop_hook_active":false,"transcript_path":"%s"}' "$2" \
    | env PATH="$d/fakebin:$PATH" CLAUDECODE=1 JG_HOME="$d" SIGN_OFF_HOME="$d/so" bash "$d/bin/jg-turnend-guard.sh" 2>&1
}

test_reply_ending_in_a_question_prints_no_block() {
  local d t out status
  d=$(setup question)
  t=$d/transcript.jsonl
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The card is fine. Use the repo card?"}]}}\n' > "$t"
  # Non-vacuity: the transcript really is one the old question rule fired on.
  local text
  text=$(jg_question_reply_text "$(printf '{"transcript_path":"%s"}' "$t")")
  jg_question_asks "$text" || fail "the test transcript is not a trailing question: $text"
  out=$(run_guard "$d" "$t"); status=$?
  expect_code 0 "$status" "the guard still blocks a reply that ends in a question: $out"
  assert_not_contains "$out" "REPLY ENDS IN A QUESTION" "the question banner is still printed"
  pass "jg-turnend-guard: a reply that ends in a question prints no block"
}

test_chat_answer_over_an_open_card_prints_no_block() {
  local d t out status
  d=$(setup chat-answer)
  t=$d/transcript.jsonl
  export SIGN_OFF_HOME=$d/so PATH=$d/fakebin:$PATH
  {
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Use the repo card? Card: %s"}]}}\n' "$KEY"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$WORDS"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done, moving on."}]}}\n'
  } > "$t"
  # Non-vacuity: the transcript really is one the old chat-answer rule fired on.
  local keys
  keys=$(jg_question_chat_answered_keys "$(printf '{"transcript_path":"%s"}' "$t")")
  assert_contains "$keys" "$KEY" "the test transcript does not answer the open card"
  out=$(run_guard "$d" "$t"); status=$?
  expect_code 0 "$status" "the guard still blocks on a chat answer: $out"
  assert_not_contains "$out" "HE ANSWERED IN CHAT" "the chat-answer banner is still printed"
  pass "jg-turnend-guard: a chat answer over an open card prints no block"
}

test_reply_text_is_the_last_assistant_text() {
  local d t text
  d=$(setup reply-text)
  t=$d/transcript.jsonl
  # The captain's own last message ends in a question; the assistant's reply is not
  # a question, so the last text of this transcript must be the assistant's sentence.
  printf '%s\n' \
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done. The fix is merged."}]}}' \
    '{"type":"user","message":{"role":"user","content":"armored juggernaut shooting maybe?"}}' > "$t"
  text=$(jg_question_reply_text "$(printf '{"transcript_path":"%s"}' "$t")")
  [ "$text" = "Done. The fix is merged." ] || fail "helper quoted the user turn: $text"
  jg_question_asks "$text" && fail "the assistant reply is not a question: $text"
  # The assistant's own final reply ending in a question is still the reply text.
  printf '%s\n' \
    '{"type":"user","message":{"role":"user","content":"ok"}}' \
    '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Should I merge it?"}]}}' > "$t"
  text=$(jg_question_reply_text "$(printf '{"transcript_path":"%s"}' "$t")")
  [ "$text" = "Should I merge it?" ] || fail "helper lost the assistant question: $text"
  jg_question_asks "$text" || fail "the assistant question was not read as one: $text"
  pass "jg-question-lib: the reply text is the last assistant text, never a user turn"
}

test_reply_ending_in_a_question_prints_no_block
test_chat_answer_over_an_open_card_prints_no_block
test_reply_text_is_the_last_assistant_text
