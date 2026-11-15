#!/usr/bin/env bash
# green-pin-stale watcher check: a trunk whose green pin has not moved for 60 minutes while landed commits wait above it raises ONE alert to
# Main for that stall, naming the cause. No model turn, and nothing is printed.
# Usage: stale.sh check <jg-home>
#
# For each project with a trunk tip record (state/trunk-tip-<project>) the stall is the shorter of two ages: the pin's (the mtime of
# state/trunk-green-<project>, which every move of the pin rewrites) and the oldest commit above the pin's (its landing row in
# data/trunk-landings.tsv, else its commit time), so a pin that was quiet on a quiet trunk is not a stall the moment a commit lands.
# At 60 minutes (config/green-pin-stale-minutes changes the 60) the check raises the `line-red` alert (bin/jg-alert.sh, rung 3 = Main) once
# for that pin: the subject is <project>-stale-pin-<pin>, so a second tick of the same stall finds the open record and raises nothing.
# A pin that moved, or a tip at the pin, ends the record. The cause is the word of the trunk machine's observer
# (core/machines/observers/trunk.sh), read and never written:
#   red            a verify failed on a commit above the pin
#   verify running a verify holds the verify slot now
#   over budget    no verify runs and a test shard above the pin ran past its wall-clock budget (data/trunk/load-<project>.tsv)
#   no verify      none of these: nothing holds the pin, and no verify has started
# Seams for tests: JG_GREEN_PIN_STALE_ALERT (jg-alert.sh), JG_GREEN_PIN_STALE_NOW (epoch).
set -u
export LC_ALL=C
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: stale.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
export JG_HOME=$FMH
STATE=$FMH/state DATA=$FMH/data
export JG_STATE_OVERRIDE=$STATE
ALERT=${JG_GREEN_PIN_STALE_ALERT:-$FMH/bin/jg-alert.sh}
OBSERVER=$FMH/core/machines/observers/trunk.sh
[ -f "$OBSERVER" ] || OBSERVER=$(cd "$(dirname "${BASH_SOURCE[0]}")/../machines/observers" 2>/dev/null && pwd -P)/trunk.sh
NOW=${JG_GREEN_PIN_STALE_NOW:-$(date +%s)}
MINUTES=$(cat "$FMH/config/green-pin-stale-minutes" 2>/dev/null | tr -dc 0-9); [ "${MINUTES:-0}" -gt 0 ] || MINUTES=60
umask 077

# The cause of a stall at <tip> above <green> in <project>.
cause() {  # <project> <repo> <green> <tip>
  local word
  word=$(bash "$OBSERVER" "$1" 2>/dev/null)
  case $word in
    red) echo "red: a verify failed on a commit above the pin"; return ;;
    verifying) echo "verify running: a verify is running on the commits above the pin"; return ;;
  esac
  if [ -f "$DATA/trunk/load-$1.tsv" ] \
     && git -C "$2" rev-list "$3..$4" 2>/dev/null | grep -qxFf <(cut -f2 "$DATA/trunk/load-$1.tsv"); then
    echo "over budget: the verify ran past its time budget"; return
  fi
  echo "no verify: none is running and none has finished on the tip"
}

live() { [ -r "$STATE/alerts/$1.rec" ] && [ "$("$ALERT" word "$1" 2>/dev/null)" != resolved ]; }

for tipfile in "$STATE"/trunk-tip-*; do
  [ -f "$tipfile" ] || continue
  p=${tipfile##*/trunk-tip-}
  repo=$FMH/projects/$p
  tip=$(cat "$tipfile" 2>/dev/null); green=$(cat "$STATE/trunk-green-$p" 2>/dev/null)
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
  [ -n "$tip" ] && [ -n "$green" ] || continue
  key="line-red--$p-stale-pin-${green:0:12}"

  # A pin that moved, or a tip at the pin, ends every earlier stall record of the project.
  for rec in "$STATE"/alerts/line-red--"$p"-stale-pin-*.rec; do
    [ -e "$rec" ] || continue
    k=$(basename "$rec" .rec)
    { [ "$tip" = "$green" ] || [ "$k" != "$key" ]; } && live "$k" && "$ALERT" resolve "$k" >/dev/null 2>&1
  done
  [ "$tip" != "$green" ] || continue

  first=$(git -C "$repo" rev-list --reverse "$green..$tip" 2>/dev/null | head -n 1)
  [ -n "$first" ] || continue
  landed=$(awk -F'\t' -v c="$first" '$3 == c { t = $4 } END { print t }' "$DATA/trunk-landings.tsv" 2>/dev/null)
  case $landed in ''|*[!0-9]*) landed=$(git -C "$repo" log -1 --format=%ct "$first") ;; esac
  pinned=$(stat -c %Y "$STATE/trunk-green-$p" 2>/dev/null) || continue
  age=$(( NOW - (pinned > landed ? pinned : landed) ))
  [ "$age" -ge $(( MINUTES * 60 )) ] || continue
  live "$key" && continue

  n=$(git -C "$repo" rev-list --count "$green..$tip")
  note="The green pin of $p has not moved for $(( age / 60 )) minutes: $n landed commit(s) wait above ${green:0:12}, the tip is ${tip:0:12}. Cause - $(cause "$p" "$repo" "$green" "$tip")."
  "$ALERT" raise line-red "$p-stale-pin-${green:0:12}" --project "$p" --rung 3 --note "$note" | "$ALERT" deliver >/dev/null 2>&1
done
exit 0
