#!/usr/bin/env bash
# lane-scale quota: the ledger of the quota reader, and the word that the reader is blind.
# Usage: quota.sh record <jg-home> <provider>   the reader calls it after each run: one ledger line for each account's reading,
#                                               and one `reset` line (the unused share of the window) when a window's reset time moved
#        quota.sh blind <jg-home>               exit 0 and raise the capacity alert `quota-blind` once when no account has been read
#                                               in `quota_blind` seconds (default 1800); exit 1 when the reader sees. No ledger: exit 1
#        quota.sh full <jg-home>                exit 0 and print the stop share when EVERY account's weekly window is used past it
# Config  config/lane-scale: quota_blind (1800), quota_stop (95, percent of the weekly window used).
# Ledger  state/quota-ledger.tsv, tab separated:
#           <epoch> reading <provider> <account> <5h left %> <7d left %> <ok|stale|error>
#           <epoch> reset   <provider> <account> <window> <left % at the last reading before the reset> <new reset time>
#         state/quota-windows.tsv holds the last seen reset time and left share of each window, so a reset is found by comparison.
# JG_QUOTA_ALERT names the alert command (a test points it at a stand-in); JG_LANE_SCALE_NOW is the clock.
set -u
case "${1:-}" in record|blind|full) ;; *) echo "usage: quota.sh record|blind|full <jg-home> [provider]" >&2; exit 2 ;; esac
[ "$#" -ge 2 ] && [ -d "$2" ] || { echo "usage: quota.sh record|blind|full <jg-home> [provider]" >&2; exit 2; }
CMD=$1
FMH=$(cd "$2" && pwd -P)
STATE=${JG_STATE_OVERRIDE:-$FMH/state}
CONFIG=${JG_CONFIG_OVERRIDE:-$FMH/config}
LEDGER=$STATE/quota-ledger.tsv
WINDOWS=$STATE/quota-windows.tsv
ALERT=${JG_QUOTA_ALERT:-$FMH/bin/jg-alert.sh}
now() { echo "${JG_LANE_SCALE_NOW:-$(date +%s)}"; }
conf() { local v; v=$(sed -n "s/^$1=//p" "$CONFIG/lane-scale" 2>/dev/null | tail -n 1); case "$v" in ''|*[!0-9]*) echo "$2" ;; *) echo "$v" ;; esac; }
umask 077

case "$CMD" in
record)
  provider=${3:?provider}
  src=$STATE/$provider-accounts.json
  [ -r "$src" ] || { echo "quota.sh: no reading file $src" >&2; exit 1; }
  mkdir -p "$STATE" && touch "$WINDOWS" || exit 1
  t=$(now)
  # One row for each account: id, the two left shares and reset times, and the reading's word.
  rows=$(jq -r '.accounts[]? | [.id, (.five_hour.left // "-"), (.five_hour.resets_at // "-"), (.seven_day.left // "-"), (.seven_day.resets_at // "-"),
      (if .problem == null then "ok" elif .stale then "stale" else "error" end)] | @tsv' "$src") || { echo "quota.sh: cannot read $src" >&2; exit 1; }
  while IFS=$'\t' read -r id hl hr dl dr word; do
    [ -n "$id" ] || continue
    printf '%s\treading\t%s\t%s\t%s\t%s\t%s\n' "$t" "$provider" "$id" "$hl" "$dl" "$word" >> "$LEDGER"
    # A stale or failed reading carries old windows: only a fresh one can show a reset.
    [ "$word" = ok ] || continue
    for w in five_hour:"$hl":"$hr" seven_day:"$dl":"$dr"; do
      IFS=: read -r name left rst <<<"$w"
      [ "$rst" != - ] || continue
      # The key is the account and window; the stored value is the last reset time and left share.
      prev=$(awk -F'\t' -v k="$provider/$id/$name" '$1==k {print $2 "\t" $3}' "$WINDOWS")
      if [ -n "$prev" ]; then
        prev_rst=${prev%%$'\t'*}; prev_left=${prev##*$'\t'}
        [ "$prev_rst" = "$rst" ] || printf '%s\treset\t%s\t%s\t%s\t%s\t%s\n' "$t" "$provider" "$id" "$name" "$prev_left" "$rst" >> "$LEDGER"
      fi
      { awk -F'\t' -v k="$provider/$id/$name" '$1!=k' "$WINDOWS"; printf '%s\t%s\t%s\n' "$provider/$id/$name" "$rst" "$left"; } > "$WINDOWS.tmp" && mv -f "$WINDOWS.tmp" "$WINDOWS"
    done
  done <<< "$rows"
  ;;
blind)
  [ -s "$LEDGER" ] || exit 1
  limit=$(conf quota_blind 1800)
  last=$(awk -F'\t' '$2=="reading" && $7=="ok" {e=$1} END {print e+0}' "$LEDGER")
  flag=$STATE/quota-blind
  if [ $(( $(now) - last )) -le "$limit" ]; then rm -f "$flag"; exit 1; fi
  if [ ! -e "$flag" ]; then
    # The alert raises once for each blind spell; the flag is gone when a reading works again.
    "$ALERT" capacity quota-blind "the quota reader has no good reading for $(( ($(now) - last) / 60 )) minutes; the lane limit holds" --deliver >/dev/null 2>&1
    printf '%s\n' "$(now)" > "$flag"
  fi
  exit 0
  ;;
full)
  [ -s "$LEDGER" ] || exit 1
  stop=$(conf quota_stop 95)
  # The latest reading of each account; an account with no weekly window read counts as not full.
  awk -F'\t' -v stop="$stop" '$2=="reading" {seen[$4]=$6} END {n=0; f=0; for (a in seen) {n++; if (seen[a] ~ /^[0-9.]+$/ && 100 - seen[a] >= stop) f++} exit !(n > 0 && f == n)}' "$LEDGER" && { echo "$stop"; exit 0; }
  exit 1
  ;;
esac
