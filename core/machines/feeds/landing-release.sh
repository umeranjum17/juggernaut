#!/usr/bin/env bash
# landing-release.sh - feed the one move log from the records the landing and the release already write.
#
# Usage: landing-release.sh [--dry-run]
#
# Reads data/trunk-latency.tsv, data/trunk-landing-phases.tsv, data/trunk-resolving.tsv, data/trunk-landings.tsv,
# data/trunk-in-use.tsv, data/trunk-releases.tsv and data/trunk-versions.tsv, and turns each row into the move it recorded,
# with the row's own time, as a line of data/machine-moves.log (`<epoch> TAB <machine> TAB <id> TAB <from> TAB <event> TAB
# <to> TAB <writer>`, the writer being `feed:landing-release`). It changes no record and no writer: the lander is not touched.
#   landing        <task>.<head>  enqueue (ready), start (launch), conflict, conflict-resolved, give-back, rebase-ok or
#                                 retest-ok (a phase row), check-ok (landed)
#   lane-delivery  <task>         t3-start (launch), t4-land (landed), t7-live (the first project live row whose commit holds it)
#   release        <task>         open (the first release pull request row whose commit holds the landing), merge (the first
#                                 trunk version cut from a main commit that holds it; the cut is the nearest record of the
#                                 merge, and `from` is `ready`, the table's only way into merged, since no record names the
#                                 checking or ready times)
# A move whose machine, id and event are already in the log is not written again, so a run twice adds nothing, and a move the
# lander or a writer already logged stays as it is. --dry-run prints the lines it would add and writes nothing.
# Env: JG_HOME, JG_DATA_OVERRIDE as in bin/jg-move.sh.
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
MOVES=$DATA/machine-moves.log
W=feed:landing-release
dry=0
case "${1:-}" in --dry-run) dry=1 ;; '') ;; *) sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;; esac

tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp" "$tmp.new"' EXIT
emit() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$W" >>"$tmp"; }  # epoch machine id from event to
isep() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; [ "$1" -gt 0 ]; }
ishead() { [[ $1 =~ ^[0-9a-f]{40,64}$ ]]; }

# landing: one run per row of trunk-latency.tsv that names its lane head
if [ -r "$DATA/trunk-latency.tsv" ]; then
  # awk gives each column a value (0 when empty): a tab read would swallow an empty column and shift the rest
  while read -r task head ready launch landed; do
    ishead "$head" || continue
    id=$task.$head
    isep "$ready" && emit "$ready" landing "$id" '(none)' enqueue queued
    isep "$launch" && emit "$launch" landing "$id" queued start rebasing
    resolved=0
    while IFS=$'\t' read -r st at; do
      isep "$at" || continue
      case $st in
        resolving) emit "$at" landing "$id" rebasing conflict resolving ;;
        resolved) emit "$at" landing "$id" resolving conflict-resolved retesting; resolved=1 ;;
        returned) emit "$at" landing "$id" resolving give-back returned ;;
        checking) if [ "$resolved" -eq 1 ]; then emit "$at" landing "$id" retesting retest-ok checking
                  else emit "$at" landing "$id" rebasing rebase-ok checking; fi ;;
      esac
    done < <(cat "$DATA/trunk-resolving.tsv" "$DATA/trunk-landing-phases.tsv" 2>/dev/null |
             awk -F'\t' -v t="$task" -v h="$head" '$1 == t && $4 == h { print $6 + 0, $5 }' | sort -n -s | awk '{ print $2 "\t" $1 }')
    isep "$landed" && emit "$landed" landing "$id" checking check-ok landed
  done < <(awk -F'\t' 'NR > 1 && $1 != "" { print $1, $2 == "" ? "-" : $2, $5 + 0, $7 + 0, $8 + 0 }' "$DATA/trunk-latency.tsv")
fi

# lane-delivery, release: one lane per row of trunk-landings.tsv (the last row of a lane, a revert-<lane> row ends it)
if [ -r "$DATA/trunk-landings.tsv" ]; then
  launch_of() { awk -F'\t' -v t="$1" -v c="$2" '$1 == t && $3 == c && $7 + 0 > 0 { l = $7 } END { print l }' "$DATA/trunk-latency.tsv" 2>/dev/null; }
  while IFS=$'\t' read -r task proj commit at _rest; do
    [ -n "$task" ] && ishead "$commit" && isep "$at" || continue
    case $task in revert-*) continue ;; esac
    repo=$JG_HOME/projects/$proj; git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || repo=$JG_HOME
    holds() { git -C "$repo" merge-base --is-ancestor "$commit" "$1" 2>/dev/null; }
    ln=$(launch_of "$task" "$commit"); isep "$ln" && emit "$ln" lane-delivery "$task" admitted t3-start landing
    emit "$at" lane-delivery "$task" landing t4-land landed
    while IFS=$'\t' read -r sha lat; do
      holds "$sha" && { emit "$lat" lane-delivery "$task" landed t7-live live; break; }
    done < <(awk -F'\t' -v p="$proj" '$1 == p && $4 ~ /^live/ && $3 + 0 > 0 { print $2 "\t" $3 }' "$DATA/trunk-in-use.tsv" 2>/dev/null | sort -t$'\t' -k2,2n -s)
    while IFS=$'\t' read -r sha rat; do
      holds "$sha" && { emit "$rat" release "$task" '(none)' open open; break; }
    done < <(awk -F'\t' -v p="$proj" '$1 == p && $6 ~ /^https:\/\// && $5 + 0 > 0 { print $3 "\t" $5 }' "$DATA/trunk-releases.tsv" 2>/dev/null | sort -t$'\t' -k2,2n -s)
    while IFS=$'\t' read -r base vat; do
      holds "$base" && { emit "$vat" release "$task" ready merge merged; break; }
    done < <(awk -F'\t' -v p="$proj" '$1 == p && $5 + 0 > 0 { print $4 "\t" $5 }' "$DATA/trunk-versions.tsv" 2>/dev/null | sort -t$'\t' -k2,2n -s)
  done < <(awk -F'\t' '{ if ($1 ~ /^revert-/) dead[substr($1, 8)] = 1; else last[$1] = $0 } END { for (k in last) if (!(k in dead)) print last[k] }' "$DATA/trunk-landings.tsv")
fi

# a move already in the log (same machine, id and event) is kept as it is; the rest are added oldest first
touch "$MOVES" 2>/dev/null || [ "$dry" -eq 1 ] || { echo "landing-release: cannot write $MOVES" >&2; exit 1; }
awk -F'\t' 'NR == FNR { seen[$2 "\t" $3 "\t" $5] = 1; next } !(($2 "\t" $3 "\t" $5) in seen) && !(($2 "\t" $3 "\t" $5) in mine) { mine[$2 "\t" $3 "\t" $5] = 1; print }' \
  "$MOVES" "$tmp" 2>/dev/null | sort -n -s >"$tmp.new"
n=$(wc -l <"$tmp.new" | tr -d ' ')
if [ "$dry" -eq 1 ]; then cat "$tmp.new"; else cat "$tmp.new" >>"$MOVES" || exit 1; fi
echo "landing-release: $n move(s) $([ "$dry" -eq 1 ] && echo "would be ")added" >&2
exit 0
