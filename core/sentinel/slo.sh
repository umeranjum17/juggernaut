#!/usr/bin/env bash
# slo.sh - the fleet error budget (report section 6.5, slice H36): landings against ready work. It decides nothing about sending:
# bin/jg-away-reach.sh owns the one sender and the one budget, and pages each change this prints.
#
# Usage: slo.sh events <state-dir> <now>   print one line a change, in the format of episodes.sh:
#                                          open<TAB>slo--landings<TAB>since<TAB>text | close<TAB>slo--landings<TAB>seconds
#        slo.sh mark-open|mark-close <state-dir> <key> <now>   record that the page for that change went out
# Ready work is a `done [at=<epoch>]` line in state/*.status inside the window; a landing is a row of data/trunk-landings.tsv
# (task, project, commit, epoch, kind) inside the window. The budget burns when landings are under half of ready work and at
# least JG_SLO_MIN_READY (default 2) lanes were ready; the window is JG_SLO_WINDOW seconds (default 1800). One burn is one
# page: the ledger <state-dir>/slo.d/<key> holds the epoch it was paged and stays while the burn lasts, so a burn that goes on
# is not paged again. The burn closes when landings reach half of ready work; a later burn opens a new page. The ledger is
# written only by mark-*, so a push that failed is found again at the next call. Data dir: JG_DATA_OVERRIDE, else <state-dir>/../data.
# Exit 0, 2 for usage.
set -u
export LC_ALL=C
cmd=${1:-}; S=${2:-}
[ -n "$S" ] && [ -d "$S" ] || { echo "usage: slo.sh events|mark-open|mark-close <state-dir> ..." >&2; exit 2; }
L=$S/slo.d
KEY=slo--landings
D=${JG_DATA_OVERRIDE:-$S/../data}
W=${JG_SLO_WINDOW:-1800};   case "$W" in ''|*[!0-9]*|0) W=1800 ;; esac
MIN=${JG_SLO_MIN_READY:-2}; case "$MIN" in ''|*[!0-9]*) MIN=2 ;; esac

case "$cmd" in
  events)
    now=${3:-$(date +%s)}
    ready=$(cat "$S"/*.status 2>/dev/null | awk -v n="$now" -v w="$W" '
      /^done / && match($0, /\[at=[0-9]+\]/) { t = substr($0, RSTART + 4, RLENGTH - 5); if (n - t < w && t <= n) c++ } END { print c + 0 }')
    landed=$(awk -F '\t' -v n="$now" -v w="$W" '$4 ~ /^[0-9]+$/ && n - $4 < w && $4 <= n { c++ } END { print c + 0 }' "$D/trunk-landings.tsv" 2>/dev/null)
    burning=0; [ "$ready" -ge "$MIN" ] && [ $((landed * 2)) -lt "$ready" ] && burning=1
    if [ "$burning" = 1 ] && [ ! -e "$L/$KEY" ]; then
      printf 'open\t%s\t%s\t%s\n' "$KEY" "$now" "Landings are under half of ready work: $landed landed, $ready ready in the last $((W / 60)) minutes"
    elif [ "$burning" = 0 ] && [ -f "$L/$KEY" ]; then
      printf 'close\t%s\t%s\n' "$KEY" "$(( now - $(cat "$L/$KEY") ))"
    fi ;;
  mark-open)  mkdir -p "$L" && printf '%s\n' "${4:?now}" > "$L/${3:?key}" ;;
  mark-close) rm -f -- "$L/${3:?key}" ;;
  *) echo "usage: slo.sh events|mark-open|mark-close <state-dir> ..." >&2; exit 2 ;;
esac
