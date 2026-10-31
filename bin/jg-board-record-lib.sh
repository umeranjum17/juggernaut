#!/usr/bin/env bash
# jg-board-record-lib.sh - the two records a board card keeps beside the board.
#
# A card's fields are not all in the board file's item.
# sign-off-axi appends every dismissal and undo to <board>.dismissed.jsonl, so a
# dismissal is a record, not an absence: a rebuild that posts the same key again
# has not un-dismissed it, and a reader that only looks at the items cannot tell.
# This file reads that record, and keeps the matching record for a card's detail
# field, which is where its must category lives, so a rebuild that drops the
# field cannot drop the category with it.
#
#   jg_board_sidecar <board> <name>       the record path beside the board
#   jg_board_dismissed <board> <key>      0 when the record says dismissed now
#   jg_board_detail_record <board> <key> <detail>   append a detail record
#   jg_board_detail_of <board> <key>      the last recorded detail, or nothing
#
# A record this file cannot read answers "no record", never a guess: a reader
# that would act on an unreadable line must keep its card instead (the rule
# bin/jg-decisions-reconcile.sh states for its own evidence classes).
# Sourced by bin/jg-board-gate.sh, bin/jg-board-asks.sh, bin/jg-question-card.sh
# and bin/jg-procevent-signoff.sh. No side effects on source.

jg_board_sidecar() {  # <board> <name>
  local board=${1-} name=${2-}
  [ -n "$board" ] && [ -n "$name" ] || return 1
  case "$board" in
    *.json) printf '%s.%s\n' "${board%.json}" "$name" ;;
    *) printf '%s.%s\n' "$board" "$name" ;;
  esac
}

# 0 when the last dismissal record for this key says it is dismissed.
# A later undo line (sign-off-axi writes dismissed:false) reopens the card, so
# only the last line for the key answers.
jg_board_dismissed() {  # <board> <key>
  local file
  [ -n "${1-}" ] && [ -n "${2-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  file=$(jg_board_sidecar "$1" dismissed.jsonl) || return 1
  [ -f "$file" ] || return 1
  jq -s --arg k "$2" 'map(select(.key == $k)) | last | (.dismissed // false)' "$file" 2>/dev/null \
    | grep -qx true
}

# Append one line recording the detail field a card was posted with.
# Best effort by design: the card is already on the board with its category, and
# a card a caller cannot record is still a card. The caller says so on stderr.
jg_board_detail_record() {  # <board> <key> <detail>
  local file dir
  [ -n "${1-}" ] && [ -n "${2-}" ] && [ -n "${3-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  file=$(jg_board_sidecar "$1" card-detail.jsonl) || return 1
  dir=${file%/*}
  mkdir -p -- "$dir" 2>/dev/null || return 1
  jq -cn --arg k "$2" --arg d "$3" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{key: $k, detail: $d, at: $at}' >> "$file" 2>/dev/null
}

# The last detail field recorded for this key, or nothing.
jg_board_detail_of() {  # <board> <key>
  local file
  [ -n "${1-}" ] && [ -n "${2-}" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  file=$(jg_board_sidecar "$1" card-detail.jsonl) || return 0
  [ -f "$file" ] || return 0
  jq -sr --arg k "$2" 'map(select(.key == $k)) | last | .detail // empty' "$file" 2>/dev/null
}
