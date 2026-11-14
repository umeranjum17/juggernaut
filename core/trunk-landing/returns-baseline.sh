#!/usr/bin/env bash
# returns-baseline.sh - how often the landing check returned a lane, split by cause, and how many returns each source head cost.
# Usage: returns-baseline.sh [<jg-home>] [--heads]      (the home defaults to $JG_HOME)
#
# It reads only the attempt records the landing check already keeps: <home>/data/jg-trunk-landing/<task>.<source head>.attempt-*/landing.log.
# One attempt is one run of `jg-trunk.sh land` for one source head (the head the worker reported done). The first REFUSED line of its
# log is the attempt's return; an attempt with none landed the lane or was cut off, and is not a return. Each return has one cause:
#   conflict      the rebase onto the trunk tip conflicted ("<branch> conflicts with <trunk> (<tip>) in: <paths>")
#   trunk-moved   the trunk moved under the lane: the old refusal "trunk moved: rebase <branch> onto <trunk> ... and prove it again",
#                 and its present forms "the trunk kept moving while <id> was gated" and "<trunk> changed while landing <id>"
#   gate-failure  a landing gate ran red for the lane ("gate '<lint|full>' failed", "this lane is the red in its batch")
#   other         any other refusal (a red trunk, a second commit, a missing proof, the environment)
# Output: one line per cause with its returns, the source heads it returned, the most returns one head had, and how many heads were
# returned once, twice and three or more times. `--heads` adds one line per returned source head: its returns by cause and its retries
# (attempts after the first). Read-only; it never writes to the home.
set -u
home=${JG_HOME:-}; heads=0
for a in "$@"; do case $a in --heads) heads=1 ;; -h|--help) sed -n '2,17p' "$0"; exit 0 ;; *) home=$a ;; esac; done
[ -n "$home" ] && [ -d "$home/data" ] || { echo "returns-baseline: give a jg home with a data directory (argument or JG_HOME)" >&2; exit 2; }
mem=$home/data/jg-trunk-landing
[ -d "$mem" ] || { echo "returns-baseline: $mem does not exist; no landing attempt was recorded in this home" >&2; exit 2; }

# <source head key> <cause> per attempt, in the order the records sort. `landed` marks an attempt with no return.
classify() {
  local d key line cause
  for d in "$mem"/*.attempt-*/; do
    [ -f "$d/landing.log" ] || continue
    d=${d%/}; key=${d##*/}; key=${key%.attempt-*}
    line=$(grep -m1 '^REFUSED' "$d/landing.log" 2>/dev/null) || line=
    case $line in
      '') cause=landed ;;
      *' conflicts with '*' in: '*) cause=conflict ;;
      *'trunk moved:'*|*'the trunk kept moving'*|*' changed while landing '*) cause=trunk-moved ;;
      *"gate '"*"' failed"*|*'is the red in its batch'*) cause=gate-failure ;;
      *) cause=other ;;
    esac
    printf '%s %s\n' "$key" "$cause"
  done
}

classify | awk -v heads="$heads" '
  { att[$1]++; if ($2 != "landed") { n[$2 SUBSEP $1]++; ret[$2]++; seen[$2 SUBSEP $1] = 1; allret[$1]++ } }
  END {
    split("conflict trunk-moved gate-failure other", causes, " ")
    printf "%-13s %8s %12s %9s  %s\n", "cause", "returns", "source heads", "most/head", "heads returned 1x / 2x / 3x+"
    for (i = 1; i <= 4; i++) {
      c = causes[i]; h = 0; mx = 0; b1 = b2 = b3 = 0
      for (k in seen) { split(k, p, SUBSEP); if (p[1] != c) continue; v = n[k]; h++; if (v > mx) mx = v; if (v == 1) b1++; else if (v == 2) b2++; else b3++ }
      printf "%-13s %8d %12d %9d  %d / %d / %d\n", c, ret[c] + 0, h, mx, b1, b2, b3
      total += ret[c] + 0
    }
    nh = 0; for (k in allret) nh++
    printf "%-13s %8d %12d\n", "all returns", total, nh
    if (heads) {
      printf "\n%-62s %8s %8s  %s\n", "source head (task.head)", "attempts", "retries", "returns by cause"
      for (k in att) {
        if (!(k in allret)) continue
        s = ""; for (i = 1; i <= 4; i++) if (n[causes[i] SUBSEP k]) s = s causes[i] "=" n[causes[i] SUBSEP k] " "
        line = sprintf("%-62s %8d %8d  %s", substr(k, 1, 62), att[k], att[k] - 1, s)
        print line | "sort"
      }
    }
  }'
