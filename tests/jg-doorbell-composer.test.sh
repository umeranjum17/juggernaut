#!/usr/bin/env bash
# tests/jg-doorbell-composer.test.sh - a doorbell never sticks in a composer.
#
# The captain's message box held an unsubmitted doorbell line, so his own next
# sentence was submitted glued onto it and counted as one wrong message. #319
# fixed only the count. These tests pin the text itself, over the recorded
# composer frames in tests/captures/doorbell-composer and the real executables
# in a throwaway home:
#   1. A composer holding our OWN doorbell - the whole line, or a leading part of
#      it after an interrupted ring - is submitted, and cleared within the wait
#      when Enter cannot clear it. It is never left for a human to glue onto.
#   2. A composer holding a human's draft is never keyed.
#   3. The prompt-reading hook strips a leading doorbell line and counts the
#      words the captain submitted after it as his message, so a glue that
#      already happened is still counted as what he actually said.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/jg-send.sh"
KPI="$ROOT/bin/jg-overwatch-kpi.sh"
OPERATIONAL="$ROOT/bin/jg-operational-input.sh"
CAPTURES="$ROOT/tests/captures/doorbell-composer"
TMP_ROOT=$(jg_test_tmproot jg-doorbell-composer)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

jg_git_identity fmtest fmtest@example.invalid

# Stub tmux: renders the case's recorded composer frame with the real doorbell
# line substituted, logs every key it is sent, and reports the composer emptied
# once C-u lands. `sleep` is stubbed so the ten-second wait does not slow the
# suite; the wait itself is exercised by case 1's cleared frame.
make_stubs() { # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    key=; prev=
    for a in "$@"; do prev=$key; key=$a; done
    printf '%s\n' "$key" >> "$JG_SEND_KEYS"
    [ "$key" != C-u ] || : > "$JG_FAKE_CLEARED"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '3\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -e "$JG_FAKE_CLEARED" ]; then
      cat "$JG_FAKE_EMPTIED"
    else
      sed -e "s|@DOORBELL@|$JG_FAKE_DOORBELL|" \
          -e "s|@DOORBELL_PART@|${JG_FAKE_DOORBELL:0:40}|" "$JG_FAKE_CAPTURE"
    fi
    exit 0 ;;
  list-windows) printf 'jg-t1\n'; exit 0 ;;
esac
exit 0
SH
  cat >"$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/tmux" "$fb/sleep"
}

# One case directory: a home with a tmux-backed task, plus its stub and logs.
setup_case() { # <name> <frame-file> -> echoes the case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state/t1.inbox"
  make_stubs "$dir"
  jg_write_meta "$dir/home/state/t1.meta" "window=sess:jg-t1" "kind=ship" "harness=claude"
  printf '%s\n' "$dir"
}

# The exact doorbell line the ring will type for a case's first steer.
doorbell_line() { # <case-dir>
  bash -c '. "$1"; jg_task_inbox_doorbell_line "$2"' _ \
    "$ROOT/bin/jg-task-inbox-lib.sh" "$1/home/state/t1.inbox/001.msg"
}

# Ring the real doorbell at the case's recorded composer frame.
run_send() { # <case-dir> <frame-file>
  local dir=$1 frame=$2
  : >"$dir/keys"
  rm -f "$dir/cleared"
  env PATH="$dir/fakebin:$PATH" \
    JG_ROOT_OVERRIDE="$dir/home" JG_HOME="$dir/home" JG_SEND_SETTLE=0 \
    JG_SEND_KEYS="$dir/keys" JG_FAKE_CAPTURE="$CAPTURES/$frame" \
    JG_FAKE_EMPTIED="$CAPTURES/emptied.txt" JG_FAKE_CLEARED="$dir/cleared" \
    JG_FAKE_DOORBELL="$(doorbell_line "$dir")" \
    "$SEND" t1 "please rebase onto main" >/dev/null 2>"$dir/send.err"
}

test_a_stuck_doorbell_is_submitted_then_cleared() {
  local dir rc keys
  dir=$(setup_case stuck stuck.txt)
  run_send "$dir" stuck.txt; rc=$?
  expect_code 0 "$rc" "a stuck doorbell must not fail the send"
  keys=$(tr '\n' ' ' <"$dir/keys")
  assert_contains "$keys" "Enter" "the stuck doorbell was not submitted: $keys"
  assert_contains "$keys" "C-u" "the stuck doorbell was never cleared: $keys"
  [ -e "$dir/cleared" ] || fail "the composer still held the doorbell after the wait"
  case "$keys" in
  *Juggernaut*instruction*) fail "the ring retyped the doorbell onto the stuck one: $keys" ;;
  esac
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not durably recorded"
  pass "a stuck doorbell is submitted, then cleared within the wait, and is never left in the composer"
}

test_a_partial_doorbell_is_cleared() {
  local dir rc keys
  dir=$(setup_case partial partial.txt)
  run_send "$dir" partial.txt; rc=$?
  expect_code 0 "$rc" "a partial doorbell must not fail the send"
  keys=$(tr '\n' ' ' <"$dir/keys")
  assert_contains "$keys" "C-u" "an interrupted doorbell was never cleared: $keys"
  [ -e "$dir/cleared" ] || fail "the partial doorbell survived the wait"
  pass "a partly typed doorbell is recognised as ours, submitted, and cleared"
}

test_a_human_draft_is_never_keyed() {
  local dir rc
  dir=$(setup_case draft draft.txt)
  run_send "$dir" draft.txt; rc=$?
  expect_code 0 "$rc" "a skipped ring is still a sent steer"
  [ ! -s "$dir/keys" ] || fail "a human draft was keyed:"$'\n'"$(cat "$dir/keys")"
  [ ! -e "$dir/cleared" ] || fail "a human draft was deleted"
  grep -q 'pending text' "$dir/send.err" || fail "the skip did not name the draft: $(cat "$dir/send.err")"
  pass "a human draft in the composer is never keyed"
}

make_home() { # <dir>
  mkdir -p "$1/bin" "$1/state" "$1/config"
  git init -q -b main "$1"
  git -C "$1" remote add origin https://github.com/acme/juggernaut.git
  : >"$1/AGENTS.md"
}

in_home() { # <dir> <command...>
  local home=$1
  shift
  JG_ROOT_OVERRIDE="$home" JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" "$@"
}

submit() { # <dir> <prompt>
  jq -cn --arg p "$2" '{hook_event_name: "UserPromptSubmit", prompt_id: "p", prompt: $p}' \
    | in_home "$1" "$KPI" hook claude
}

test_glued_text_is_counted_as_the_captains_words() {
  local home doorbell glued pending
  home="$TMP_ROOT/glued"
  make_home "$home"
  doorbell=$(in_home "$home" "$OPERATIONAL" record turn-end-guard <<<'signal: demo.status') ||
    fail "the operational-input protocol produced no doorbell"
  glued=$(sed "s|@DOORBELL@|$doorbell|" "$CAPTURES/glued.txt")
  submit "$home" "$glued"
  pending=$(in_home "$home" "$KPI" pending)
  assert_equals "$(printf '1\twhy is the export PR still not open?')" "$pending" \
    "the words submitted after a stuck doorbell are not the captain's message: $pending"
  # A prompt that was nothing but doorbell records no message at all.
  submit "$home" "$doorbell"
  assert_equals "$(printf '1\twhy is the export PR still not open?')" "$(in_home "$home" "$KPI" pending)" \
    "a doorbell on its own was counted as a captain message"
  # Two stuck doorbells, then his words: still one message, still only his words.
  submit "$home" "$(printf '%s\n%s\n%s' "$doorbell" "$doorbell" "and the CSV column?")"
  assert_equals "$(printf '2\tand the CSV column?')" "$(in_home "$home" "$KPI" pending)" \
    "two stacked doorbells were not stripped before counting"
  # A reworded doorbell (shape only, no live record behind it) is stripped the
  # same way, so a reworded one cannot glue itself to his words either.
  submit "$home" "$(printf '%s\n%s' ": Juggernaut operational input waiting: read '/tmp/x/operational-inbox/1-aa.msg' now." "is the export PR open?")"
  assert_equals "$(printf '3\tis the export PR open?')" "$(in_home "$home" "$KPI" pending)" \
    "a reworded doorbell was counted as part of the captain's message"
  # A message that merely names Juggernaut is his own words and is kept whole.
  submit "$home" "ask Juggernaut why the export PR is still open"
  assert_equals "$(printf '4\task Juggernaut why the export PR is still open')" "$(in_home "$home" "$KPI" pending)" \
    "an ordinary message naming Juggernaut was altered"
  pass "the hook strips a leading doorbell line and counts the captain's words after it"
}

test_a_stuck_doorbell_is_submitted_then_cleared
test_a_partial_doorbell_is_cleared
test_a_human_draft_is_never_keyed
test_glued_text_is_counted_as_the_captains_words
