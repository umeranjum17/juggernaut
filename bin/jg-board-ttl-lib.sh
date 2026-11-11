#!/usr/bin/env bash
# jg-board-ttl-lib.sh - when an open board ask stops being the captain's to answer.
#
# The captain (2026-11-11): the Decide page holds asks that are no longer
# relevant or were already acted on, and nothing ever clears them. This file is
# the one rule table for that. A card is withdrawn, never answered in his name:
# the caller dismisses it with one of sign-off-axi's own reasons and records why.
#
#   jg_board_ttl_secs <category>           the card's time to live; 0 = owner call, never expires
#   jg_board_ask_expiry <filed-epoch> <category>   the epoch the card expires at, or `never`
#   jg_board_ask_verdict <type> <category> <filed-epoch> <now> <ticket> <ask-ref> <answered-by>
#                                          prints `<sign-off reason>|<why>` and returns 0 to
#                                          withdraw, or returns 1 to keep the card
#
# The rules, first match wins (a transition table, one owner):
#   ticket closed          its raising ticket is done                  -> done-elsewhere
#   call settled           its ask-ref is a task that is done                  -> done-elsewhere
#   superseded             a later card on the same ask-ref was answered       -> replaced
#   past ttl               older than its category's time to live              -> not-relevant
# Owner calls (money, security, public-release, discard-unlanded, release-word)
# have no ttl: only the three rules above, which mean the call is already gone,
# can withdraw them. Time to live in days: config/board-ask-ttl-days, default 7,
# for plan-approval and design-pick. Sourced by bin/jg-board-gate.sh; needs
# SCRIPT_DIR, CONFIG, and the question and ask-gate libs. No side effects on source.

JG_BOARD_TTL_OWNER_CATEGORIES='money security public-release discard-unlanded release-word'

jg_board_ttl_secs() {  # <category>
  local days
  case " $JG_BOARD_TTL_OWNER_CATEGORIES " in *" ${1-} "*) printf '0\n'; return 0 ;; esac
  days=$(cat "${CONFIG:-/nonexistent}/board-ask-ttl-days" 2>/dev/null | tr -d '[:space:]')
  case "$days" in ''|0*|*[!0-9]*) days=7 ;; esac
  printf '%s\n' $((days * 86400))
}

jg_board_ask_expiry() {  # <filed-epoch> <category>
  local ttl
  ttl=$(jg_board_ttl_secs "${2-}")
  [ "$ttl" -gt 0 ] || { printf 'never\n'; return 0; }
  printf '%s\n' $(($1 + ttl))
}

# One read of every done ticket id, written to $1 for a whole pass: the store
# answers a list in one call, but a show per card costs seconds each. A read
# that fails leaves the file empty, and then no card is judged by its ticket.
jg_board_done_tickets() {  # <file>
  timeout 60 "${JG_BOARD_BACKLOG_BIN:-$SCRIPT_DIR/jg-backlog.sh}" list --state "done" 2>/dev/null \
    | sed -n 's/^[[:space:]]*\([A-Za-z0-9._-][A-Za-z0-9._-]*\),done,.*/\1/p' > "$1" 2>/dev/null || : > "$1"
}

# 0 when the ticket is in the pass's done set (JG_BOARD_DONE_FILE).
jg_board_ticket_done() {  # <ticket>
  case "${1-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -s "${JG_BOARD_DONE_FILE:-}" ] && grep -qxF -- "$1" "$JG_BOARD_DONE_FILE"
}

jg_board_ask_verdict() {  # <type> <category> <filed-epoch> <now> <ticket> <ask-ref> <answered-by>
  local cat=$2 filed=$3 now=$4 ticket=$5 ref=$6 answered=$7 ttl
  if [ -n "$ticket" ] && jg_board_ticket_done "$ticket"; then
    printf 'done-elsewhere|its ticket %s is done\n' "$ticket"; return 0
  fi
  if [ -n "$ref" ] && jg_board_ticket_done "$ref"; then
    printf 'done-elsewhere|the call %s is already settled\n' "$ref"; return 0
  fi
  if [ -n "$answered" ]; then
    printf 'replaced|a later card on the same call, %s, was answered\n' "$answered"; return 0
  fi
  ttl=$(jg_board_ttl_secs "$cat")
  if [ "$ttl" -gt 0 ] && [ $((now - filed)) -ge "$ttl" ]; then
    printf 'not-relevant|older than its %s days with no answer\n' $((ttl / 86400)); return 0
  fi
  return 1
}
