#!/usr/bin/env bash
# jg-captain-card-lib.sh - the one owner of what a captain-facing item is.
#
# TWO LAYERS, stated once and cross-referenced everywhere else:
#   record  The durable layer, and the only place full detail lives: the task,
#           hold, report or evidence record keeping the evidence, ids, paths and
#           complete reasoning. Nothing in it is shortened.
#   card    The captain-facing layer, and all he has to read: one line stating the
#           outcome first, one recommendation, at most two plain options, and a
#           deep link to the record. Built from the record, never replacing it.
# A board card (bin/jg-question-card.sh post, layer `card`) and a captain-facing
# chat message (the visible summary bin/jg-branch-outcome.sh appends, layer
# `message`) are the same two layers on two surfaces, so both read this file.
#
# The check is SHADOW-FIRST: it names the failing rule in one line appended to
# $STATE/captain-card-shadow.log, and it refuses nothing. It measures the layer
# and never gates the work, so it never writes to stdout or stderr either: its
# callers print a card key or an outcome sequence on those streams, and a
# measurement that shares them breaks what the caller captures. The banned words
# have one owner too, JG_ASK_JUNK_PATTERNS in bin/jg-ask-gate-lib.sh: the same
# internal terms AGENTS.md section 9 keeps out of captain chat.
#
# Rules, one line each, the first failing one printed:
#   1  no internal id, file path or jargon.
#   2  at most two plain options.
#   3  an outcome-first line: the first non-empty line, at most
#      JG_CAPTAIN_CARD_LINE_MAX characters, never a heading, bullet or lead-in.
#   4  a deep link to the record, an absolute http(s) URL: cards only, because a
#      chat message's record is its own task record.
JG_CAPTAIN_CARD_LINE_MAX=200
JG_CAPTAIN_CARD_MAX_OPTIONS=2
JG_CAPTAIN_CARD_SHADOW_LOG=captain-card-shadow.log

# shellcheck source=bin/jg-ask-gate-lib.sh
command -v jg_ask_card_junk >/dev/null 2>&1 \
  || . "${BASH_SOURCE[0]%/*}/jg-ask-gate-lib.sh"

# Print the first non-empty line of a text, trailing space trimmed.
jg_captain_card_first_line() {  # <text>
  printf '%s\n' "${1-}" | grep -v '^[[:space:]]*$' | head -n 1 | tr -d '\r' \
    | sed 's/[[:space:]]*$//'
}

# Print the first internal id, path or jargon hit in a text, or nothing. A URL is
# a public link, never junk, so links are masked before the banned list sees it.
jg_captain_card_junk() {  # <text>
  jg_ask_card_junk "$(printf '%s' "${1-}" | sed -E 's#https?://[^[:space:]]+#URL#g')"
}

# Print the one line naming the first failing rule and return 1, or return 0 when
# the item satisfies the card layer. <options> is how many plain options it offers.
jg_captain_card_refusal() {  # <layer> <text> <options>
  local layer=${1-} text=${2-} options=${3-} subject=card hit line why=''
  [ "$layer" = message ] && subject=message
  hit=$(jg_captain_card_junk "$text")
  if [ -n "$hit" ]; then
    hit=$(printf '%s' "$hit" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    printf 'refused: rule 1, no internal id, path or jargon on a %s, and this one says "%s"\n' "$subject" "$hit"
    return 1
  fi
  case "$options" in ''|*[!0-9]*) options=0 ;; esac
  if [ "$options" -gt "$JG_CAPTAIN_CARD_MAX_OPTIONS" ]; then
    printf 'refused: rule 2, at most %s plain options on a %s, and this one offers %s\n' \
      "$JG_CAPTAIN_CARD_MAX_OPTIONS" "$subject" "$options"
    return 1
  fi
  line=$(jg_captain_card_first_line "$text")
  case "$line" in
    '') why='no line at all' ;;
    '#'*|'-'*|'*'*|'>'*|'|'*|'+'*) why='a heading or a bullet, not a line of outcome' ;;
    [0-9].*|[0-9][0-9].*|[0-9][0-9][0-9].*) why='a numbered line, not a line of outcome' ;;
    *:) why='a lead-in that ends in a colon, not a line of outcome' ;;
    *) [ "${#line}" -le "$JG_CAPTAIN_CARD_LINE_MAX" ] || why="longer than $JG_CAPTAIN_CARD_LINE_MAX characters" ;;
  esac
  if [ -n "$why" ]; then
    printf 'refused: rule 3, an outcome-first line on a %s, and this one is %s\n' "$subject" "$why"
    return 1
  fi
  if [ "$layer" = card ] && ! printf '%s\n' "$text" | grep -qE 'https?://[^[:space:]]+'; then
    printf 'refused: rule 4, a deep link to the record on a card, and this one has none\n'
    return 1
  fi
  return 0
}

# Shadow-first: log what this item would be refused for, and return 0 whatever
# the verdict so no caller ever blocks on it. The log line is the whole
# delivery: a caller prints its own result on stdout (a card key) and its own
# problems on stderr, so a measurement notice on either stream would corrupt it.
jg_captain_card_shadow() {  # <layer> <text> <options>
  local layer=${1-} text=${2-} options=${3-} refusal state line
  refusal=$(jg_captain_card_refusal "$layer" "$text" "$options") || true
  [ -n "$refusal" ] || return 0
  state=${JG_STATE_OVERRIDE:-${STATE:-${JG_HOME:-}/state}}
  [ -n "$state" ] && [ -d "$state" ] || return 0
  line=$(printf '%s' "$text" | tr '\n\t' '  ' | cut -c1-160)
  printf '%s layer=%s %s text="%s"\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$layer" "$refusal" "$line" \
    >> "$state/$JG_CAPTAIN_CARD_SHADOW_LOG" 2>/dev/null || true
  return 0
}
