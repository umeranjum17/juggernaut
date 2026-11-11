#!/usr/bin/env bash
# release.sh - report-only observer of the release machine (core/machines/tables/release.tsv): the state of the release
# pull request that carries one lane's commit, read from lane-delivery.sh. A lane the older reader finds in no release
# prints nothing. It only reads.
#
# Usage:
#   release.sh <lane>          print the release word: open, checking, red, ready, merged or abandoned
#   release.sh detail <lane>   print key<TAB>value lines: state, release (the pull request), joining (the ticket's sub-state)
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
mode=word; [ "${1:-}" != detail ] || { mode=detail; shift; }
id=${1:?usage: release.sh [detail] <lane>}
d=$("$here/lane-delivery.sh" detail "$id" 2>/dev/null) || exit 0
word=$(printf '%s\n' "$d" | sed -n 's/^state\t//p')
case $word in
  release-open) w=open ;; release-ci-running) w=checking ;; release-red) w=red ;; release-green) w=ready ;;
  merged|rolled) w=merged ;; release-closed) w=abandoned ;;
  *) exit 0 ;;
esac
if [ "$mode" = word ]; then printf '%s\n' "$w"; exit 0; fi
# A merged or abandoned release no longer holds the ticket: the sub-state `joining` is for a release still under way.
j=joining; case $w in merged|abandoned) j=- ;; esac
printf 'state\t%s\nrelease\t%s\njoining\t%s\n' "$w" "$(printf '%s\n' "$d" | sed -n 's/^release\t//p')" "$j"
