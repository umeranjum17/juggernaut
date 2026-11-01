#!/usr/bin/env bash
# jg-ask-gate-lib.sh - which board asks may reach the captain, and the refusal.
#
# The captain's leash (2026-10-30): on "When it matters" his board carries only
# asks that are a must; every other ask is refused here and becomes an Overwatch
# decision record (bin/jg-board-gate.sh route) that Main answers. sign-off-axi
# owns the board and the leash setting (`leash:` in the config.yaml beside the
# board: ask, matters its default, or act), so this file only reads it. Sourced
# by bin/jg-question-card.sh and bin/jg-captain-hold.sh.
#
# What a must is (2026-10-31): "When it matters" means money, security, a public
# release, discarding unseen work, or a product call only he can make. Anything
# else is ours and never becomes a card, so the list below is exactly those five.

JG_ASK_MUST_CATEGORIES='money security public-release discard-unlanded design-pick'

# The card rules (2026-10-31), applied by jg_ask_card_refusal to every card any
# path raises. His board is his decisions alone:
#   1. A hold his own stop order created is his instruction, not a question back.
#   2. A stuck worker is Main's to unblock, never a card for the captain.
#   3. A card is one plain question about the product or about money, with two
#      clear options, and no internal name: no Main number, no task, lane, hook,
#      file or card name, no path.
#   4. A card that breaks one of these is refused with one line naming the rule.
JG_ASK_CAPTAIN_STOP_MARK='captain stop order'
# The words that make a hold the captain's own instruction rather than a question
# back to him: a stop order, and a branch we preserved instead of landing. Matched
# case-insensitively against the whole text, so a hold reason carrying them never
# becomes a card on any path that shares this test.
JG_ASK_OWN_INSTRUCTION_PATTERNS="$JG_ASK_CAPTAIN_STOP_MARK
(^|[^a-z0-9])stop[ -]order([^a-z0-9]|$)
branch[^a-z0-9]+preserved
preserved[^a-z0-9]+(branch|unmerged|unlanded)
(branch|unmerged|unlanded)[^a-z0-9]+preserved"
# Our own vocabulary, which never reaches his eyes: the fleet's own words for
# its work, and every kind of identifier we file a task, lane, card or merge under.
JG_ASK_JUNK_PATTERNS='(jg|fm|ask|merge)-[a-z0-9][a-z0-9._-]+
waiting-(timer-)?[a-z0-9]+
(^|[^a-z0-9])(pr|pull request)[[:space:]#]?[0-9]+
(^|[^a-z0-9_-])(worktrees?|checkouts?|lanes?|hooks?|daemons?|pipelines?|watchers?|wakes?|teardowns?|branch(es)?|harness(es)?|backends?|briefs?|squad leads?|overwatch|no-mistakes|sign-off|task ids?|status lines?)([^a-z0-9_-]|$)
(^|[[:space:](=])(\./|\.\./|~/|/[a-z])
[a-z0-9_-]+\.(sh|md|json|jsonl|ya?ml|html)'

# shellcheck source=bin/jg-question-lib.sh
command -v jg_question_board >/dev/null 2>&1 \
  || . "${BASH_SOURCE[0]%/*}/jg-question-lib.sh"

jg_ask_categories_words() {
  printf '%s\n' "$JG_ASK_MUST_CATEGORIES" | sed 's/ /, /g'
}

jg_ask_category_ok() {  # <category>
  [ -n "${1-}" ] || return 1
  case " $JG_ASK_MUST_CATEGORIES " in *" $1 "*) return 0 ;; esac
  return 1
}

# The leash as sign-off-axi applies it: ask, matters or act.
jg_ask_leash() {  # [<board file>]
  local board=${1-} cfg='' v=''
  [ -n "$board" ] || board=$(jg_question_board)
  [ -z "$board" ] || cfg=${board%/*}/config.yaml
  [ -z "$cfg" ] || [ ! -f "$cfg" ] \
    || v=$(sed -n 's/^leash:[[:space:]]*//p' "$cfg" 2>/dev/null | tail -1 | tr -d "\"'[:space:]")
  case "$v" in ask|matters|act) printf '%s\n' "$v" ;; *) printf 'matters\n' ;; esac
}

# The must category a card carries in its detail field, or nothing.
jg_ask_card_category() {  # <detail text>
  local d=${1-}
  case "$d" in *must:*) d=${d##*must:} ;; *) return 0 ;; esac
  d=${d# }; d=${d%% *}
  jg_ask_category_ok "$d" && printf '%s\n' "$d"
  return 0
}

# Rule 1's test, owned here so the hold path and every card path agree: the text
# says the captain already gave this instruction, so nothing asks him again.
jg_ask_own_instruction() {  # <text>
  local t line
  t=$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$t" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$t" | grep -Eq "$line" && return 0
  done <<EOF
$JG_ASK_OWN_INSTRUCTION_PATTERNS
EOF
  return 1
}

# Print the first internal name in a card's text, or nothing. Main's own name
# and number are matched before the text is lowercased, so the ordinary English
# word it shares its spelling with ("the main page") stays a plain word.
jg_ask_card_junk() {  # <text>
  local t line hit
  t=${1-}
  hit=$(printf '%s' "$t" | grep -oE -m1 '(^|[^A-Za-z])Main([[:space:]]?-?[0-9]+|[^A-Za-z0-9]|$)') \
    && [ -n "$hit" ] || hit=''
  if [ -n "$hit" ]; then
    printf '%s\n' "$hit"
    return 0
  fi
  t=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
  [ -n "$t" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    hit=$(printf '%s' "$t" | grep -oE -m1 "$line" | head -1) && [ -n "$hit" ] || continue
    printf '%s\n' "$hit"
    return 0
  done <<EOF
$JG_ASK_JUNK_PATTERNS
EOF
  return 0
}

# Print why this card cannot reach the captain and return 1, or return 0 to post
# it. <options> is how many --outcome/--option pairs the card carries; the rest is
# its title and every word of body text that will be on it.
jg_ask_card_refusal() {  # <ask-ref> <options> <title> [<body>...]
  local ref=${1-} options=${2-} title=${3-} text hit
  shift 2 || true
  shift || true
  text="$title ${*:-}"
  if jg_ask_own_instruction "$text"; then
    printf 'refused: rule 1, your own stop order is your instruction and never a card back to you\n'
    return 1
  fi
  case "$ref" in
    waiting-*)
      printf "refused: rule 2, a stuck worker is Main's to unblock and never a card for you\n"
      return 1 ;;
  esac
  hit=$(jg_ask_card_junk "$text")
  if [ -n "$hit" ]; then
    hit=$(printf '%s' "$hit" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    printf 'refused: rule 3, a card names no internal thing and this one says "%s"\n' "$hit"
    return 1
  fi
  case "${title% }" in
    *'?') ;;
    *)
      printf 'refused: rule 3, a card is one plain question and its title is not one\n'
      return 1 ;;
  esac
  case "$options" in
    ''|*[!0-9]*) options=0 ;;
  esac
  if [ "$options" -lt 2 ]; then
    printf 'refused: rule 3, a card is one plain question with two clear options and this one offers %s\n' "$options"
    return 1
  fi
  return 0
}

# Print why this ask cannot go on the board and return 1, or return 0 to post it.
# A named but unknown category is always refused, so the count stays honest.
jg_ask_gate_refusal() {  # <category-or-empty> [<board file>]
  local cat=${1-}
  if [ -n "$cat" ]; then
    jg_ask_category_ok "$cat" && return 0
    printf 'refused: %s is not a must category; a must is one of: %s\n' "$cat" "$(jg_ask_categories_words)"
    return 1
  fi
  [ "$(jg_ask_leash "${2-}")" = matters ] || return 0
  printf 'refused: the board leash is when it matters, so a board ask needs a must category: %s\n' "$(jg_ask_categories_words)"
  printf 'not a must? Decide it yourself and record "Main decided" with bin/jg-board-gate.sh decided; it never reaches his board.\n'
  return 1
}
