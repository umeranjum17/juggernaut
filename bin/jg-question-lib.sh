#!/usr/bin/env bash
# Shared question-rule helpers: does a captain-facing reply end in a question,
# and is that question already a board card? Sourced, no side effects.
#
# The question rule is the owner's, 2026-10-25: "if you ask questions as well
# make sure they are posted, posting questions will be stricter way of working".
# A chat-only question to him is a violation, so a reply that ends in one must
# cite the card it was asked on. bin/jg-question-card.sh posts that card and
# prints the key; bin/jg-turnend-guard.sh calls the predicate at the turn
# boundary; the reply and status writers that already run flag it in place.
#
# The board is read through sign-off-axi's own `list --json`, never a private
# copy of it, so this file stays a reader and posts nothing itself.

# Print the board file to read, or nothing to let sign-off-axi walk its default.
# An explicit SIGN_OFF_HOME is authoritative: a home that names a board must
# never fall through to the machine's shared board.
jg_question_board() {
  local dir
  if [ -n "${SIGN_OFF_HOME:-}" ]; then
    # A named home is authoritative; sign-off-axi keeps its board in .sign-off/.
    for dir in "$SIGN_OFF_HOME/.sign-off/decisions.json" "$SIGN_OFF_HOME/decisions.json"; do
      [ -f "$dir" ] && printf '%s\n' "$dir" && return 0
    done
    return 0
  fi
  dir="$HOME/.sign-off/decisions.json"
  [ -f "$dir" ] && printf '%s\n' "$dir"
  return 0
}

jg_question_signoff_available() { command -v sign-off-axi >/dev/null 2>&1; }

# The board key a hold's card carries, and the one owner of its shape:
# `jg-<tag>-<task-id>-<stamp>`. <tag> is a stable digest of JG_HOME, so the one
# board every home on this machine shares never hands a home another home's
# answer; <stamp> is that hold occurrence's identity in alphanumerics only, so a
# newly held task gets a card of its own. bin/jg-captain-hold.sh builds the key
# with these helpers and bin/jg-procevent-signoff.sh parses answers back with the
# same two, so the builder and the reader cannot drift apart.
jg_question_key_prefix() {
  printf 'jg-%s-' "$(printf '%s' "${JG_HOME:-}" | cksum | awk '{printf "%08x", $1}')"
}

jg_question_key_stamp() {  # <hold identity>
  printf '%s' "${1%%#*}" | tr -cd 'A-Za-z0-9'
}

jg_question_hold_card_key() {  # <task-id> <hold identity>
  printf '%s%s-%s' "$(jg_question_key_prefix)" "$1" "$(jg_question_key_stamp "$2")"
}

# Print the key of every card still open on the board.
jg_question_open_keys() {
  local board
  jg_question_signoff_available || return 0
  board=$(jg_question_board)
  if [ -n "$board" ]; then
    sign-off-axi list "$board" --json 2>/dev/null
  elif [ -n "${SIGN_OFF_HOME:-}" ]; then
    return 0
  else
    sign-off-axi list --json 2>/dev/null
  fi | jq -r '(.decisions // [])[]?.key // empty' 2>/dev/null
  return 0
}

# Print the last non-empty line of a reply, trailing markup trimmed.
jg_question_tail() {
  printf '%s\n' "$1" \
    | grep -v '^[[:space:]]*$' \
    | tail -1 \
    | tr -d '\r' \
    | sed -e 's/[[:space:]]*$//' -e 's/[][<"'"'"'*_`)>:]*$//' -e 's/[[:space:]]*$//'
}

# Return 0 when this reply ends in a question the owner has to answer.
# A guard-generated continuation (the U+2063 marker) is never his question.
jg_question_asks() {
  local tail_line
  [ -n "${1-}" ] || return 1
  [ "${1:0:1}" = "$(printf '\u2063')" ] && return 1
  tail_line=$(jg_question_tail "$1")
  case "$tail_line" in
    *\?) return 0 ;;
  esac
  return 1
}

# Return 0 when the reply cites a card that is still open on the board, so the
# question is already filed. An absent sign-off tool or an unreadable board
# confirms no card, which is not the same as confirming one; callers decide what
# that means for them.
jg_question_filed() {
  local key
  [ -n "${1-}" ] || return 1
  jg_question_signoff_available || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$1" in
      *"$key"*) return 0 ;;
    esac
  done < <(jg_question_open_keys)
  return 1
}

# Nag each distinct trailing question once: 0 the first time it is seen, 1 once
# this home has already flagged it, so no harness can be wedged in a loop.
jg_question_first_sighting() {  # <state-dir> <reply-text> [<record file name>]
  local state=$1 stamp rec=${3:-.question-flagged}
  [ -n "$state" ] || return 0
  stamp=$(jg_question_tail "${2-}" | cksum | awk '{print $1 "-" $2}')
  if [ -f "$state/$rec" ] && [ "$(head -1 "$state/$rec" 2>/dev/null)" = "$stamp" ]; then
    return 1
  fi
  mkdir -p "$state" 2>/dev/null || return 0
  printf '%s\n' "$stamp" > "$state/$rec" 2>/dev/null || true
  return 0
}

# Print the last assistant text of a turn-end payload's transcript, if it has one.
jg_question_reply_text() {  # <turn-end payload json>
  local path
  command -v jq >/dev/null 2>&1 || return 0
  path=$(printf '%s' "$1" | jq -r '.transcript_path // empty' 2>/dev/null) || return 0
  [ -n "$path" ] && [ -f "$path" ] && [ -r "$path" ] || return 0
  tail -n 400 "$path" 2>/dev/null | jq -Rrs '
    split("\n")
    | map(fromjson? // empty)
    | map(
        if ((.message.content? | type) == "array") then
          (.message.content[]? | if type == "object" and (.type == "text") then .text else empty end)
        elif ((.message.content? | type) == "string") then .message.content
        elif ((.payload.content? | type) == "array") then
          (.payload.content[]? | if type == "object" and (.type == "output_text" or .type == "text") then .text else empty end)
        else empty end)
    | map(select(. != null and . != "")) | last // empty' 2>/dev/null
  return 0
}

# Print the append-only answers log beside a board file (sign-off-axi's own
# `<board>.answers.jsonl`), or nothing when no board file is known.
jg_question_answers_log() {  # <board file>
  [ -n "${1-}" ] || return 0
  printf '%s\n' "${1%.json}.answers.jsonl"
}

# Print, one per line, the open board cards the captain just answered in chat:
# the cards cited by the assistant text that came right before the transcript's
# last human message, when they are still open now. The opposite case of
# jg_question_filed: the question was posted, the answer came in chat, and the
# card still waits. A guard-generated continuation (U+2063) is not a human message.
jg_question_chat_answered_keys() {  # <turn-end payload json>
  local path pair prior human key
  command -v jq >/dev/null 2>&1 || return 0
  path=$(printf '%s' "$1" | jq -r '.transcript_path // empty' 2>/dev/null) || return 0
  [ -n "$path" ] && [ -f "$path" ] && [ -r "$path" ] || return 0
  pair=$(tail -n 400 "$path" 2>/dev/null | jq -Rrs '
    def texts: if (.message.content? | type) == "string" then [.message.content]
      elif (.message.content? | type) == "array" then [.message.content[]? | select(type == "object" and .type == "text") | .text]
      else [] end;
    def human: [.message.content? | if type == "array" then .[]? else empty end | select(type == "object" and .type == "tool_result")] | length == 0;
    split("\n") | map(fromjson? // empty) | map(select(type == "object")) as $l
    | ($l | map(.type // .message.role // "") ) as $roles
    | [range(0; $l | length) | select($roles[.] == "user" and ($l[.] | human) and (($l[.] | texts | join("\n")) != "")
        and (($l[.] | texts | join("\n"))[0:1] != "\u2063"))] as $us
    | if ($us | length) == 0 then empty else
        $us[-1] as $u
        | [range(0; $u) | select($roles[.] == "assistant" and (($l[.] | texts | join("\n")) != ""))] as $as
        | if ($as | length) == 0 then empty else
            {prior: ($l[$as[-1]] | texts | join("\n")), human: ($l[$u] | texts | join("\n"))} | @base64 end
      end' 2>/dev/null) || return 0
  [ -n "$pair" ] || return 0
  pair=$(printf '%s' "$pair" | base64 -d 2>/dev/null) || return 0
  prior=$(printf '%s' "$pair" | jq -r '.prior' 2>/dev/null)
  human=$(printf '%s' "$pair" | jq -r '.human' 2>/dev/null)
  [ -n "$human" ] || return 0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$prior" in *"$key"*) printf '%s\n' "$key" ;; esac
  done < <(jg_question_open_keys)
  return 0
}

# Print the chat answer's words (the last human message), for the banner.
jg_question_chat_words() {  # <turn-end payload json>
  local path
  path=$(printf '%s' "$1" | jq -r '.transcript_path // empty' 2>/dev/null) || return 0
  [ -f "$path" ] || return 0
  tail -n 400 "$path" 2>/dev/null | jq -Rrs '
    split("\n") | map(fromjson? // empty) | map(select(type == "object" and (.type // .message.role) == "user"))
    | map(if (.message.content? | type) == "string" then .message.content
        elif (.message.content? | type) == "array" then ([.message.content[]? | select(type == "object" and .type == "text") | .text] | join("\n"))
        else "" end)
    | map(select(. != "" and .[0:1] != "\u2063")) | last // empty' 2>/dev/null
  return 0
}

# Flag a captain-facing text that ends in a question no open card covers.
# This is a flag, not a gate: it returns 0 whether or not it printed, so a
# writer that already ran keeps its own contract and only gains the line.
jg_question_flag_reply() {
  local text=${1-}
  jg_question_asks "$text" || return 0
  jg_question_filed "$text" && return 0
  printf 'flag: this text ends in a question that no open board card covers; post it with %s/jg-question-card.sh post and cite the key in the text\n' \
    "$(dirname "${BASH_SOURCE[0]}")" >&2
  return 0
}

# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
