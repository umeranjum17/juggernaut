#!/usr/bin/env bash
# jg-voice-lib.sh - the shell send points' one call into the captain voice file.
#
# The rules (banned terms, plain replacements, the mode per send point) live in the markdown
# voice file that bin/jg-voice.py reads at run time; its header owns the contract. This
# library only runs that checker over a message before the message leaves, so the shell send
# points share one call: the chat reply in bin/jg-inbox.sh and the parent-channel append in
# bin/jg-parent-channel-lib.sh. The Telegram send in core/bus calls the same checker.
#
# jg_voice_apply <channel> <text> [--line]
#   Sets JG_VOICE_OUT to the text to send. Returns 0 to send it; returns 1 when the text breaks a
#   rule and the voice file's mode for <channel> is `block`, or the model rewrite failed or did
#   not come out plain (findings and a re-draft instruction on stderr), in which case
#   JG_VOICE_OUT is the original text. A missing checker or python3 passes the
#   text through unchanged, because a style layer must never stop a captain-facing message.
#
# Sourced by the send points and tests. No side effects on source.

_JG_VOICE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"

# shellcheck disable=SC2034  # JG_VOICE_OUT is the result the caller reads.
jg_voice_apply() {  # <channel> <text> [--line]
  local channel=$1 text=$2 out rc
  shift 2
  JG_VOICE_OUT=$text
  command -v python3 >/dev/null 2>&1 && [ -r "$_JG_VOICE_LIB_DIR/jg-voice.py" ] || return 0
  # The marker keeps trailing newlines, which command substitution would drop.
  out=$(printf '%s' "$text" | python3 "$_JG_VOICE_LIB_DIR/jg-voice.py" apply --channel "$channel" "$@"; printf '.%s' "$?")
  rc=${out##*.}
  out=${out%.*}
  case $rc in
    0) JG_VOICE_OUT=$out ;;
    1) return 1 ;;
  esac
  return 0
}
