#!/usr/bin/env bash
# trunk-pulse.sh <home> <since-epoch> [<now-epoch>] - one home's trunk landings for the fleet pulse.
#
# A local-trunk home merges no feature pull request: a lane's commit lands on the trunk and the
# home moves to a go-live by bin/jg-trunk.sh live, so a merged-PR count reads 0 there however fast it lands.
# This reads the records bin/jg-trunk.sh writes instead:
#   data/trunk-landings.tsv  task, project, commit, epoch, gate
#   data/trunk-in-use.tsv      project, commit, epoch, status (live... when the home moved to a go-live; landed-not-live,
#                            hook-failed and rolled-back... when it did not)
#   data/trunk-releases.tsv  project, trunk, tip, count, epoch, url
#
# Prints one TSV row: landed in_homes ready_min
#   landed     landing rows at or after <since-epoch>
#   in_homes   go-live rows (status live..., the homes moved; In use needs the delivery machine) at or after <since-epoch>
#   ready_min  whole minutes the oldest landed commit has waited to reach the homes, or - when none waits.
#              A landing stops waiting when its project's newest live row names it or a later
#              landing of that project (the trunk only moves forward, so a live commit carries
#              every landing before it; a pin-back to an older commit makes the later ones wait
#              again), or when a release of that project followed it.
# Exits 1 printing nothing when the home has neither landing nor live records: that is a merged-PR
# home, whose pulse keeps counting merged pull requests. Exits 2 on a usage error.
set -euo pipefail

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo 'usage: trunk-pulse.sh <home> <since-epoch> [<now-epoch>]' >&2; exit 2; }
home=$1 since=$2 now=${3:-$(date +%s)}
case "$since$now" in *[!0-9]*) echo "trunk-pulse: since and now must be epoch seconds (got '$since' '$now')" >&2; exit 2 ;; esac
data=$home/data
[ -f "$data/trunk-landings.tsv" ] || [ -f "$data/trunk-in-use.tsv" ] || exit 1

# Tag each record with its file so awk reads all three in one pass; a missing file adds no rows.
for f in L:trunk-landings.tsv V:trunk-in-use.tsv R:trunk-releases.tsv; do
  [ ! -f "$data/${f#*:}" ] || awk -v t="${f%%:*}" '{ print t "\t" $0 }' "$data/${f#*:}"
done | awk -F'\t' -v since="$since" -v now="$now" '
  $1 == "L" && $5 ~ /^[0-9]+$/ { n++; proj[n] = $3; sha[n] = $4; at[n] = $5; if ($5 >= since) landed++; next }
  $1 == "V" && $4 ~ /^[0-9]+$/ && $5 ~ /^live/ { if ($4 >= since) live++; at_live[$2] = $3; next }
  $1 == "R" && $6 ~ /^[0-9]+$/ { if ($6 > released[$2]) released[$2] = $6; next }
  END {
    for (i = 1; i <= n; i++) if ((proj[i] in at_live) && sha[i] == at_live[proj[i]]) covered[proj[i]] = i
    oldest = ""
    for (i = 1; i <= n; i++) {
      if (i <= covered[proj[i]] + 0 || at[i] <= released[proj[i]] + 0) continue
      if (oldest == "" || at[i] < oldest) oldest = at[i]
    }
    wait = "-"
    if (oldest != "") { wait = int((now - oldest) / 60); if (wait < 0) wait = 0 }
    printf "%d\t%d\t%s\n", landed, live, wait
  }'
