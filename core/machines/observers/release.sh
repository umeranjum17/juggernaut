#!/usr/bin/env bash
# release.sh - report-only observer of the release machine (core/machines/tables/release.tsv): the state of the release
# pull request that carries one lane's commit. It reads the lander's records and the pull request; a lane in no release, a
# reverted lane and a pull request that cannot be read print nothing. It only reads.
#
# Usage:
#   release.sh <lane>          print the release word: open, checking, red, ready, merged or abandoned
#   release.sh detail <lane>   print key<TAB>value lines: state, release (the pull request), joining (the ticket's sub-state)
#
# The records: the lane's last row in data/trunk-landings.tsv names commit C in project P (a later revert-<lane> row ends the
# read). The first data/trunk-releases.tsv row of P whose commit holds C names the pull request. It is merged when
# state/trunk-rolled-P is that pull request or a data/trunk-versions.tsv base of P holds C; else one read of the pull
# request (gh pr view) gives merged, abandoned (closed unmerged), or on its head a failed check (red), a check still running
# (checking), every check passed (ready), none or a cancelled one (open).
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}
mode=word; [ "${1:-}" != detail ] || { mode=detail; shift; }
ID=${1:?usage: release.sh [detail] <lane>}

holds() { git -C "$REPO" merge-base --is-ancestor "$1" "$2" 2>/dev/null; }
# A trunk version was cut from a main-branch commit that holds C (data/trunk-versions.tsv: project, version, branch, base).
cut_after() {
  local base
  while read -r base; do holds "$C" "$base" && return 0; done < <(awk -F'\t' -v p="$P" '$1 == p { print $4 }' "$DATA/trunk-versions.tsv" 2>/dev/null)
  return 1
}

row=$(awk -F'\t' -v i="$ID" '$1 == i { r = $2 "\t" $3; v = 0 } $1 == "revert-" i && r != "" { v = 1 } END { if (r != "" && !v) print r }' "$DATA/trunk-landings.tsv" 2>/dev/null)
[ -n "$row" ] || exit 0
IFS=$'\t' read -r P C <<< "$row"
REPO=$JG_HOME/projects/$P; git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || REPO=$JG_HOME
REL=
while IFS=$'\t' read -r sha url; do holds "$C" "$sha" && { REL=$url; break; }; done < <(awk -F'\t' -v p="$P" '$1 == p && $6 ~ /^https:\/\// { print $3 "\t" $6 }' "$DATA/trunk-releases.tsv" 2>/dev/null)
[ -n "$REL" ] || exit 0
if [ "$(cat "$STATE/trunk-rolled-$P" 2>/dev/null)" = "$REL" ] || cut_after; then w=merged
else
  json=$(gh pr view "$REL" --json state,statusCheckRollup 2>/dev/null) || { echo "release.sh: gh pr view $REL failed" >&2; exit 0; }
  w=$(jq -r '[.statusCheckRollup[]? | (.conclusion // .state // "") as $c | (.status // "COMPLETED") as $s
      | if ($c | test("^(FAILURE|ERROR|TIMED_OUT|STARTUP_FAILURE|ACTION_REQUIRED)$")) then "red"
        elif $s != "COMPLETED" or ($c | test("^(PENDING|EXPECTED|)$")) then "running"
        elif $c == "CANCELLED" then "open" else "green" end] as $k
    | if .state == "MERGED" then "merged" elif .state != "OPEN" then "abandoned"
      elif ($k | index("red")) then "red" elif ($k | index("running")) then "checking"
      elif ($k | index("open")) or ($k | length) == 0 then "open" else "ready" end' <<< "$json" 2>/dev/null)
  [ -n "$w" ] || exit 0
fi
if [ "$mode" = word ]; then printf '%s\n' "$w"; exit 0; fi
# A merged or abandoned release no longer holds the ticket: the sub-state `joining` is for a release still under way.
j=joining; case $w in merged|abandoned) j=- ;; esac
printf 'state\t%s\nrelease\t%s\njoining\t%s\n' "$w" "$REL" "$j"
