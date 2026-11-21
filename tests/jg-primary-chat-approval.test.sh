#!/usr/bin/env bash
# An order the captain types in the locked primary session signs its ticket (jg-7v6uw-s38).
# Real prompt hook (bin/jg-overwatch-kpi.sh hook claude, or hook agy fed agy's PreInvocation payload
# and transcript) -> real bin/jg-inbox.sh primary-chat ->
# the real build-approval reader (captain_ask_build_basis in bin/jg-captain-ask-lib.sh).
#
# T1 a message typed in the locked primary session files the handled note `[chat primary <session>:<seq>]`
#    with his whole words, and an order quoting them as owner-words: note:<id> is approved by it.
# T2 a session that is not the locked one, a home with no lock, and machine text file no note, and an
#    order quoting such words is not approved.
# T3 the note appends no wake: it is born handled, so the inbox has nothing pending.
# T5 a Pi primary locked through the real bin/jg-lock.sh files the same signed note when the tracked primary
#    extension's `input` handler forwards a typed (interactive) prompt: the Pi session is a file path, so the note is
#    named by a digest of it; an extension-injected prompt, a Pi process in another pane and a non-Pi process file none.
# T4 an agy primary locked through the real bin/jg-lock.sh files the same signed note from the PreInvocation
#    that opens a turn on a typed prompt; a background-task wake, a later invocation of the turn, another
#    conversation and a payload with no readable transcript file none, and the order is approved.
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

# agy's PreInvocation payload and the transcript steps that decide whether a typed prompt opened the turn
# (shapes captured live from agy 1.5.11, docs/verification/agy.md).
agy_transcript() {  # <file> <source:type>...  one step per argument, indexed from 0
  local f=$1 i=0 st
  shift
  : > "$f"
  for st in "$@"; do
    jq -cn --argjson i "$i" --arg s "${st%%:*}" --arg t "${st#*:}" '{step_index: $i, source: $s, type: $t}' >> "$f"
    i=$((i + 1))
  done
}

# Runs the command the tracked .agents/hooks.json registers for PreInvocation, the way agy does: sh -c from
# the directory holding hooks.json.
agy_submit() {  # <dir> <conversation> <invocationNum> <initialNumSteps> <transcript> <prompt>
  local cmd
  cmd=$(jq -r '[.[].PreInvocation // empty | .[].command] | first // empty' "$ROOT/.agents/hooks.json")
  [ -n "$cmd" ] || fail "the tracked .agents/hooks.json registers no PreInvocation command"
  jq -cn --arg c "$2" --argjson n "$3" --argjson s "$4" --arg t "$5" --arg p "$6" \
    '{hookEventName: "PreInvocation", conversationId: $c, invocationNum: $n, initialNumSteps: $s, transcriptPath: $t, lastUserInput: $p}' \
    | (cd "$ROOT/.agents" && JG_ROOT_OVERRIDE="$1" JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" sh -c "$cmd")
}

test_an_agy_primary_signs_an_order() {
  local home="$TMP_ROOT/agy" words="Build the retry policy now, with no second approval." tr="$TMP_ROOT/agy-transcript.jsonl" fb n id
  make_home "$home"
  fb="$TMP_ROOT/agy-bin"
  mkdir -p "$fb"
  ln -sf "$(command -v bash)" "$fb/agy"
  mkdir -p "$home/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u HERDR_PANE_ID ANTIGRAVITY_CONVERSATION_ID=conv-primary-1 JG_HOME="$home" \
    "$fb/agy" -c "$ROOT/bin/jg-lock.sh; exit \$?" >/dev/null 2>&1 || fail "the agy primary could not take the lock"
  assert_equals conv-primary-1 "$(head -n 1 "$home/state/.lock-session")" "the lock did not record the agy conversation"

  # Turn 1: the typed prompt is step 0, agy appends an SDK system note before the hook runs.
  agy_transcript "$tr" USER_EXPLICIT:USER_INPUT SYSTEM_SDK:SYSTEM_MESSAGE
  agy_submit "$home" conv-primary-1 0 1 "$tr" "$words"
  id="primary-conv-primary-1-1"
  [ -f "$home/state/inbox/handled/$id.note" ] || fail "no handled note $id: $(ls -R "$home/state" 2>&1)"
  assert_equals "[chat primary conv-primary-1:1] $words" "$(awk 'f{print} /^--$/{f=1}' "$home/state/inbox/handled/$id.note")" \
    "the note does not carry the signed tag and his whole words"
  approved "$home" "$id" "Build the retry policy now" || fail "the order quoting his agy words was not approved"
  approved "$home" "$id" "Build the cache now" && fail "words he did not type were approved"

  # The same turn's next model call, a finished background task waking the session (the newest step at
  # initialNumSteps - 1 is a model step, the wake message comes after it), and a Stop continuation
  # (invocationNum 1) carry the stale lastUserInput and must not count again.
  agy_transcript "$tr" USER_EXPLICIT:USER_INPUT SYSTEM_SDK:SYSTEM_MESSAGE MODEL:PLANNER_RESPONSE MODEL:GENERIC MODEL:PLANNER_RESPONSE SYSTEM:SYSTEM_MESSAGE
  agy_submit "$home" conv-primary-1 1 4 "$tr" "$words"
  agy_submit "$home" conv-primary-1 0 5 "$tr" "$words"
  # Another conversation's typed prompt and a payload whose transcript is unreadable file nothing either.
  agy_transcript "$tr" USER_EXPLICIT:USER_INPUT
  agy_submit "$home" conv-other-9 0 1 "$tr" "typed in another conversation"
  agy_submit "$home" conv-primary-1 0 1 "$TMP_ROOT/missing.jsonl" "no transcript"
  n=$(find "$home/state/inbox" -name '*.note' | wc -l | tr -d ' ')
  assert_equals 1 "$n" "a wake, a later invocation, another conversation or a missing transcript filed a chat note"
  # The KPI ledger counts every typed prompt (his words in another conversation too); only the note is session-gated.
  assert_equals 2 "$(wc -l < "$home/data/overwatch-kpi.jsonl" | tr -d ' ')" \
    "a wake, a later invocation or an unreadable transcript was counted as a captain message, or a typed prompt was not"

  # Turn 2: the next typed prompt, after the wake, is the next message.
  agy_transcript "$tr" USER_EXPLICIT:USER_INPUT SYSTEM_SDK:SYSTEM_MESSAGE MODEL:PLANNER_RESPONSE SYSTEM:SYSTEM_MESSAGE MODEL:PLANNER_RESPONSE USER_EXPLICIT:USER_INPUT
  agy_submit "$home" conv-primary-1 0 6 "$tr" "second order"
  [ -f "$home/state/inbox/handled/primary-conv-primary-1-3.note" ] || fail "the next typed prompt did not get its own note: $(ls "$home/state/inbox/handled")"
  pass "an agy primary's typed prompt files a handled, signed chat note that approves an order quoting it; a wake, a repeat call and a foreign conversation file none"
}

# Runs the real tracked Pi primary extension under a process named <runtime> (Pi runs it as `pi`) and
# delivers one `input` event to its handler.
pi_input() {  # <dir> <runtime-name> <pane> <source> <text>
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID HERDR_PANE_ID="$3" HERDR_BIN_PATH="$TMP_ROOT/pi-bin/herdr" HERDR_SESSION=default \
    JG_ROOT_OVERRIDE="$1" JG_HOME="$1" JG_STATE_OVERRIDE="$1/state" PLUGIN="$ROOT/.pi/extensions/jg-primary-turnend-guard.ts" \
    EVENT_SOURCE="$4" EVENT_TEXT="$5" "$TMP_ROOT/pi-bin/$2" --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = { on(event, handler) { handlers.set(event, handler); }, async sendUserMessage() {} };
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const result = await handlers.get("input")?.({ type: "input", source: process.env.EVENT_SOURCE, text: process.env.EVENT_TEXT }, {});
if (result?.action !== "continue") throw new Error("the capture changed what Pi does with the prompt");
await new Promise((resolve) => setTimeout(resolve, 1500));
EOF
}

test_a_pi_primary_signs_an_order() {
  local home="$TMP_ROOT/pi" words="Build the retry policy now, with no second approval." fb="$TMP_ROOT/pi-bin" node_bin n id key
  node_bin=$(node -p process.execPath) || fail "no node to run the Pi extension"
  make_home "$home"
  mkdir -p "$fb/lock" "$home/state"
  ln -sf "$node_bin" "$fb/pi"
  ln -sf "$node_bin" "$fb/node-in-pane"
  ln -sf "$(command -v bash)" "$fb/lock/pi"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"result":{"snapshot":{"agents":[
 {"pane_id":"p1","agent":"pi","agent_session":{"kind":"path","value":"/s/one.jsonl"}},
 {"pane_id":"p2","agent":"pi","agent_session":{"kind":"path","value":"/s/two.jsonl"}}]}}}
JSON
SH
  chmod +x "$fb/herdr"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID HERDR_PANE_ID=p2 HERDR_BIN_PATH="$fb/herdr" HERDR_SESSION=default JG_HOME="$home" \
    "$fb/lock/pi" -c "$ROOT/bin/jg-lock.sh; exit \$?" >/dev/null 2>&1 || fail "the Pi primary could not take the lock"
  assert_equals /s/two.jsonl "$(head -n 1 "$home/state/.lock-session")" "the lock did not record the Pi session"

  pi_input "$home" pi p2 interactive "$words"
  n=$(find "$home/state/inbox/handled" -name 'primary-*.note' | wc -l | tr -d ' ')
  assert_equals 1 "$n" "the typed Pi prompt did not file exactly one chat note: $(ls -R "$home/state" 2>&1)"
  id=$(basename "$(find "$home/state/inbox/handled" -name 'primary-*.note')" .note)
  case "$id" in primary-s[0-9]*-1) ;; *) fail "the Pi note id is not a digest-named first message: $id" ;; esac
  key=${id#primary-}
  assert_equals "[chat primary ${key%-1}:1] $words" "$(awk 'f{print} /^--$/{f=1}' "$home/state/inbox/handled/$id.note")" \
    "the note does not carry the signed tag and his whole words"
  approved "$home" "$id" "Build the retry policy now" || fail "the order quoting his Pi words was not approved"
  approved "$home" "$id" "Build the cache now" && fail "words he did not type were approved"

  # A prompt an extension injected (a wake), a Pi process in another pane, and a process that is not Pi sign nothing.
  pi_input "$home" pi p2 extension "a wake the extension injected"
  pi_input "$home" pi p1 interactive "typed in another pane"
  pi_input "$home" node-in-pane p2 interactive "typed under a process that is not Pi"
  n=$(find "$home/state/inbox/handled" -name 'primary-*.note' | wc -l | tr -d ' ')
  assert_equals 1 "$n" "an injected prompt, another pane or a non-Pi process filed a chat note"
  pass "a Pi primary's typed prompt files a handled, signed chat note that approves an order quoting it; an injected prompt, another pane and a non-Pi process file none"
}

test_the_locked_primary_session_signs_an_order
test_an_agy_primary_signs_an_order
test_a_pi_primary_signs_an_order
test_other_sessions_and_machine_text_sign_nothing
