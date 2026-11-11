#!/usr/bin/env bash
# release-stamp.sh - the lander's release step records the moment a release opened on each ticket it carries.
#
# Usage: release-stamp.sh <project-dir> <base> <release-commit>
#
# Each commit in base..release-commit names its ticket by the `Ticket` trailer. The ticket gets the metadata moment
# `release_opened_at` (RFC3339, UTC), which the ticket machine reads as the sub-state delivering.joining. A moment already
# on the row is kept, so a second push into the same open release does not move it. A ticket the store refuses is named
# on stderr and never stops the release; data/trunk-releases.tsv stays the lander's own record.
# JG_BACKLOG overrides the backlog script (tests).
set -u
dir=${1:?usage: release-stamp.sh <project-dir> <base> <release-commit>}; base=${2:?base}; rel=${3:?release commit}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
backlog=${JG_BACKLOG:-$here/../../bin/jg-backlog.sh}
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
git -C "$dir" log --format='%(trailers:key=Ticket,valueonly,separator=%x0A)' "$base..$rel" 2>/dev/null | awk 'NF && !seen[$1]++ { print $1 }' |
while read -r id; do
  if "$backlog" show "$id" 2>/dev/null | grep -q 'release_opened_at'; then continue; fi
  "$backlog" update "$id" --set-metadata "release_opened_at=$now" >/dev/null 2>&1 \
    && echo "release_opened_at $now on $id" || echo "release-stamp: could not record release_opened_at on $id" >&2
done
exit 0
