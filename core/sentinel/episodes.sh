#!/usr/bin/env bash
# episodes.sh - the blocked-fleet episodes of the last rung (report section 6.5, slice H17): what is open for the owner, and what
# has already been paged. It decides nothing about sending: bin/jg-away-reach.sh owns the one sender and the one budget.
#
# Usage: episodes.sh events <state-dir> <now>      print one line a change: open<TAB>key<TAB>since<TAB>text | close<TAB>key<TAB>seconds
#        episodes.sh mark-open|mark-close <state-dir> <key> <now>   record that the page for that change went out
#        episodes.sh open <state-dir>              print one text line per paged episode that is still open
# An episode is an alert record (state/alerts/<key>.rec, bin/jg-alert.sh) that is open at rung 4, the owner's rung: the ladder
# below it did not clear it. Its key is the alert key (`supervision-down--watcher-dead`), so one episode is one key for as long as
# the record stays open. A change is paged once: an episode that opens, and one that closes after it was paged. The ledger is
# <state-dir>/episodes.d/<key> holding the epoch it was paged open; it is written only by mark-*, so a push that failed is found
# again at the next call. Exit 0, 2 for usage.
set -u
export LC_ALL=C
cmd=${1:-}; S=${2:-}
[ -n "$S" ] && [ -d "$S" ] || { echo "usage: episodes.sh events|mark-open|mark-close|open <state-dir> ..." >&2; exit 2; }
L=$S/episodes.d
_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

case "$cmd" in
  events)
    now=${3:-$(date +%s)}
    for rec in "$S"/alerts/*.rec; do
      [ -r "$rec" ] || continue
      key=${rec##*/}; key=${key%.rec}
      [ "$(_get "$rec" state)" = open ] && [ "$(_get "$rec" rung)" = 4 ] || continue
      [ ! -e "$L/$key" ] || continue
      note=$(_get "$rec" note); [ -n "$note" ] || note=$(_get "$rec" subject)
      printf 'open\t%s\t%s\t%s\n' "$key" "$(_get "$rec" since)" "$note"
    done
    for led in "$L"/*; do
      [ -f "$led" ] || continue
      key=${led##*/}
      rec=$S/alerts/$key.rec
      if [ -r "$rec" ] && [ "$(_get "$rec" state)" = open ] && [ "$(_get "$rec" rung)" = 4 ]; then continue; fi
      printf 'close\t%s\t%s\n' "$key" "$(( now - $(cat "$led") ))"
    done ;;
  mark-open)  mkdir -p "$L" && printf '%s\n' "${4:?now}" > "$L/${3:?key}" ;;
  mark-close) rm -f -- "$L/${3:?key}" ;;
  open)
    for led in "$L"/*; do
      [ -f "$led" ] || continue
      key=${led##*/}; rec=$S/alerts/$key.rec
      [ "$(_get "$rec" state)" = open ] || continue
      printf '%s: %s\n' "$key" "$(_get "$rec" note)"
    done ;;
  *) echo "usage: episodes.sh events|mark-open|mark-close|open <state-dir> ..." >&2; exit 2 ;;
esac
