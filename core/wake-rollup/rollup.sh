#!/usr/bin/env bash
# wake-rollup: Main gets one digest per home per 10 minutes; only the P0 classes ring at once (H35).
# Usage: rollup.sh hold  <jg-home> <kind> <key> <payload>   exit 0: the event is held for its home's digest; exit 1: it rings
#        rollup.sh check <jg-home>                          the watcher check: one digest line per home whose window closed
#        rollup.sh board <jg-home>                          write data/wake-rollup/wakes-per-day.tsv from the wake ledger
#
# A Squad Lead's home reports into Main as the status stream state/<id>.status (state/<id>.meta kind=squad_lead). `hold` is asked by
# bin/jg-wake-lib.sh's jg_wake_append_locked for every event that would reach the queue. An event of a lead stream that is not P0 is
# appended to data/wake-rollup/<id>.rows and never rings; `check` prints, per home, one line with the counts once the oldest held row
# is JG_WAKE_ROLLUP_MIN minutes old (default 10), which the watcher turns into one check wake, and clears that home's rows. So a home
# costs Main at most one digest per window, and a quiet home costs none. Nothing is dropped: the digest names every class with a count.
# P0 (rings at once, never held): a status word of needs-decision, failed or blocked; a payload naming security; every stale and
# heartbeat event; every key that is not a lead stream. JG_WAKE_ROLLUP_P0 (space-separated words) replaces the status words.
# Off switch: a file config/wake-rollup-off restores today's wakes (hold always exits 1).
# `board` is Main's wakes a day on the board: day, rang, held (rolled up) and digests, counted from data/wake-ledger.tsv (a held
# event is ledgered as `rollup`) and data/wake-rollup/digests.tsv; `check` refreshes it at most every ten minutes.
# JG_WAKE_ROLLUP_NOW is the clock (tests).
set -u
cmd=${1:-}; FMH=${2:-}
case "$cmd" in hold) [ "$#" -eq 5 ] ;; check|board) [ "$#" -eq 2 ] ;; *) false ;; esac && [ -d "$FMH/state" ] \
  || { echo "usage: rollup.sh hold <jg-home> <kind> <key> <payload> | check <jg-home> | board <jg-home>" >&2; exit 2; }
STATE=${JG_STATE_OVERRIDE:-$FMH/state}; DATA=${JG_DATA_OVERRIDE:-$FMH/data}; CONFIG=${JG_CONFIG_OVERRIDE:-$FMH/config}
DIR=$DATA/wake-rollup
NOW=${JG_WAKE_ROLLUP_NOW:-$(date +%s)}
WINDOW=$(( ${JG_WAKE_ROLLUP_MIN:-10} * 60 ))
P0_WORDS=${JG_WAKE_ROLLUP_P0:-needs-decision failed blocked}

status_word() { local l; l=$(tail -n 1 -- "$STATE/$1.status" 2>/dev/null) || return 0; l=${l%%[ :[]*}; printf '%s' "$l"; }

hold() {
  local kind=$1 key=$2 payload=$3 id word p
  [ ! -e "$CONFIG/wake-rollup-off" ] || return 1
  case "$kind" in signal|check) ;; *) return 1 ;; esac
  case "$key" in *.status) id=${key%.status} ;; *) return 1 ;; esac
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  grep -q '^kind=squad_lead$' "$STATE/$id.meta" 2>/dev/null || return 1
  case "$payload" in *[Ss]ecurity*) return 1 ;; esac
  word=$(status_word "$id")
  [ -n "$word" ] || { word=${payload%%[ :[]*}; }
  for p in $P0_WORDS; do [ "$word" != "$p" ] || return 1; done
  mkdir -p "$DIR" && printf '%s\t%s\t%s\n' "$NOW" "$kind" "${word:-event}" >> "$DIR/$id.rows" || return 1
}

check() {
  local f id oldest n counts
  for f in "$DIR"/*.rows; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .rows)
    oldest=$(head -n 1 "$f" | cut -f1)
    case "$oldest" in ''|*[!0-9]*) rm -f -- "$f"; continue ;; esac
    [ $((NOW - oldest)) -ge "$WINDOW" ] || continue
    mv -- "$f" "$f.sent" || continue
    n=$(wc -l < "$f.sent" | tr -d ' ')
    counts=$(cut -f3 "$f.sent" | LC_ALL=C sort | uniq -c | awk '{printf "%s%s %s", (NR>1?", ":""), $2, $1}')
    printf '%s\t%s\t%s\n' "$NOW" "$id" "$n" >> "$DIR/digests.tsv"
    rm -f -- "$f.sent"
    printf 'wake-rollup: %s: %s events in %s min (%s)\n' "$id" "$n" "$((WINDOW / 60))" "$counts"
  done
  if [ ! -f "$DIR/wakes-per-day.tsv" ] || [ $((NOW - $(stat -c %Y "$DIR/wakes-per-day.tsv" 2>/dev/null || echo 0))) -ge 600 ]; then board; fi
}

board() {
  local ledger=$DATA/wake-ledger.tsv out=$DIR/wakes-per-day.tsv d
  mkdir -p "$DIR" || return 1
  {
    printf 'day\trang\theld\tdigests\n'
    { [ ! -f "$ledger" ] || sed 's/^/L\t/' "$ledger"; [ ! -f "$DIR/digests.tsv" ] || sed 's/^/D\t/' "$DIR/digests.tsv"; } \
      | awk -F'\t' '$1=="L"{day=int($2/86400); if($6=="rollup")h[day]++; else r[day]++; seen[day]=1}
                    $1=="D"{day=int($2/86400); g[day]++; seen[day]=1}
                    END{for(day in seen) printf "%d\t%d\t%d\t%d\n", day, r[day], h[day], g[day]}' | LC_ALL=C sort -n \
      | while IFS=$'\t' read -r d rang held dig; do printf '%s\t%s\t%s\t%s\n' "$(date -u -d "@$((d * 86400))" +%F)" "$rang" "$held" "$dig"; done
  } > "$out.tmp" && mv -f -- "$out.tmp" "$out"
}

case "$cmd" in hold) hold "$3" "$4" "$5" ;; check) check ;; board) board ;; esac
