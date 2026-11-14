#!/usr/bin/env bash
# An order the captain types in the locked primary session signs its ticket (jg-7v6uw-s38).
# Real prompt hook (bin/jg-overwatch-kpi.sh hook claude) -> real bin/jg-inbox.sh primary-chat ->
# the real build-approval reader (captain_ask_build_basis in bin/jg-captain-ask-lib.sh).
#
# T1 a message typed in the locked primary session files the handled note `[chat primary <session>:<seq>]`
#    with his whole words, and an order quoting them as owner-words: note:<id> is approved by it.
# T2 a session that is not the locked one, a home with no lock, and machine text file no note, and an
#    order quoting such words is not approved.
# T3 the note appends no wake: it is born handled, so the inbox has nothing pending.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KPI="$ROOT/bin/jg-overwatch-kpi.sh"
TMP_ROOT=$(jg_test_tmproot jg-primary-chat-approval)
jg_git_identity fmtest fmtest@example.invalid

make_home() {  # <dir>
  mkdir -p "$1/bin" "$1/state" "$1/config"
  git init -q -b main "$1"
  : > "$1/AGENTS.md"
}

submit() {  # <dir> <session> <prompt>
  jq -cn --arg s "$2" --arg p "$3" '{hook_event_name: "UserPromptSubmit", session_id: $s, prompt: $p}' \
    | JG_ROOT_OVERRIDE="$1" JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" "$KPI" hook claude
}

# Whether the order's words are approved by a chat note, asked through the real reader.
approved() {  # <dir> <note-id> <words>
  local show
  show=$(printf '  body: "owner-words: note:%s \\"%s\\""\n' "$2" "$3")
  (
    # shellcheck disable=SC2034 # read by the sourced library
    STATE="$1/state"
    # shellcheck disable=SC2329 # called by the sourced library
    fail() { echo "$*" >&2; exit 2; }
    # shellcheck source=bin/jg-captain-ask-lib.sh
    . "$ROOT/bin/jg-captain-ask-lib.sh"
    captain_ask_build_basis jg-demo "$show" >/dev/null
  )
}

test_the_locked_primary_session_signs_an_order() {
  local home="$TMP_ROOT/signs" words="Build the retry policy now, with no second approval." id
  make_home "$home"
  printf 'sess-primary\n' > "$home/state/.lock-session"
  submit "$home" sess-primary "$words"
  id="primary-sess-primary-1"
  [ -f "$home/state/inbox/handled/$id.note" ] || fail "no handled note $id: $(ls -R "$home/state" 2>&1)"
  assert_equals "[chat primary sess-primary:1] $words" "$(awk 'f{print} /^--$/{f=1}' "$home/state/inbox/handled/$id.note")" \
    "the note does not carry the signed tag and his whole words"
  approved "$home" "$id" "Build the retry policy now" || fail "the order quoting his words was not approved"
  approved "$home" "$id" "Build the cache now" && fail "words he did not type were approved"
  ls "$home/state/inbox"/*.note >/dev/null 2>&1 && fail "the note was left pending and would wake the primary"
  submit "$home" sess-primary "second order"
  [ -f "$home/state/inbox/handled/primary-sess-primary-2.note" ] || fail "the next message did not get its own note"
  pass "a message typed in the locked primary session files a handled, signed chat note that approves an order quoting it"
}

test_other_sessions_and_machine_text_sign_nothing() {
  local home="$TMP_ROOT/refuses" nolock="$TMP_ROOT/nolock" n err rc
  make_home "$home"
  printf 'sess-primary\n' > "$home/state/.lock-session"
  submit "$home" sess-other "Build the retry policy now"
  submit "$home" sess-primary '<task-notification>rewake</task-notification>'
  submit "$home" sess-primary "$(printf '\342\201\243JUGGERNAUT_OP: v1 watcher: signal: demo.status')"
  n=$(find "$home/state/inbox" -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
  assert_equals 0 "$n" "another session or machine text filed a chat note"
  approved "$home" primary-sess-other-1 "Build the retry policy now" && fail "an order resting on another session's words was approved"
  make_home "$nolock"
  submit "$nolock" sess-primary "Build it"
  n=$(find "$nolock/state/inbox" -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
  assert_equals 0 "$n" "a home with no locked session filed a chat note"
  err=$(JG_HOME="$home" JG_STATE_OVERRIDE="$home/state" "$ROOT/bin/jg-inbox.sh" primary-chat sess-other 9 "typed by a machine" 2>&1); rc=$?
  assert_equals 1 "$rc" "primary-chat accepted a session that is not the locked one"
  assert_contains "$err" "not the locked primary session" "primary-chat gave no clear refusal"
  pass "another session, a home with no lock, and machine text file no signed note"
}

test_the_locked_primary_session_signs_an_order
test_other_sessions_and_machine_text_sign_nothing
