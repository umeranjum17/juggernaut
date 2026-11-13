#!/usr/bin/env bash
# runners ledger: the minutes a paid runner (a cloud machine, cost_per_hour above 0) has run, and the daily cap on them (H30c).
# Usage: ledger.sh record <jg-home> <runner-id> <minutes>   append one row to data/runner-ledger.tsv
#        ledger.sh spent <jg-home>                          print the paid minutes recorded today (UTC)
#        ledger.sh allow <jg-home>                          exit 0 when paid placement may go on: the cap is above 0 and not yet spent
# Row   data/runner-ledger.tsv, tab separated: <epoch> <runner id> <minutes>
# Cap   config/fleet-scale key paid_minutes_day (default 0): with 0 no paid runner gets any work.
set -u
usage() { echo "usage: ledger.sh record <jg-home> <runner-id> <minutes> | spent|allow <jg-home>" >&2; exit 2; }
case "${1:-}" in record) [ "$#" -eq 4 ] ;; spent|allow) [ "$#" -eq 2 ] ;; *) false ;; esac || usage
[ -d "$2" ] || { echo "ledger.sh: no home $2" >&2; exit 2; }
HOME_DIR=$(cd "$2" && pwd -P)
CONFIG=${JG_CONFIG_OVERRIDE:-$HOME_DIR/config}
DATA=${JG_DATA_OVERRIDE:-$HOME_DIR/data}
FILE=$DATA/runner-ledger.tsv

now_epoch() { echo "${JG_LEDGER_NOW_EPOCH:-$(date +%s)}"; }
spent_today() {  # the minutes of rows from the start of today (UTC) on
  local now start; now=$(now_epoch); start=$(( now - now % 86400 ))
  [ -f "$FILE" ] || { echo 0; return; }
  awk -F'\t' -v start="$start" '$1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $1 >= start { s += $3 } END { print s + 0 }' "$FILE"
}
cap() {
  local v; v=$(sed -n 's/^paid_minutes_day=//p' "$CONFIG/fleet-scale" 2>/dev/null | tail -n 1)
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

case "$1" in
  record)
    case "$3" in ''|*[!A-Za-z0-9._-]*) echo "ledger.sh: bad runner id '$3'" >&2; exit 2 ;; esac
    case "$4" in ''|*[!0-9]*) echo "ledger.sh: minutes must be a whole number, got '$4'" >&2; exit 2 ;; esac
    mkdir -p "$DATA" || exit 1
    printf '%s\t%s\t%s\n' "$(now_epoch)" "$3" "$4" >> "$FILE" ;;
  spent) spent_today ;;
  allow) [ "$(cap)" -gt 0 ] && [ "$(spent_today)" -lt "$(cap)" ] ;;
esac
