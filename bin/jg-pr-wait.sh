#!/usr/bin/env bash
# Say on an open pull request what it is waiting for, or clear that wait.
#
# The question this answers is the captain's: a pull request sat waiting and
# nobody could tell what for until someone asked. The answer is a GitHub commit
# status, context juggernaut/waiting-for, carrying ONE short plain line, so the
# wait is on the pull request page itself instead of only in a status record
# somewhere else.
#
# The status is a property of the head commit, so a new push drops it and the
# next set call publishes the current wait at the new head.
#
# Usage:
#   jg-pr-wait.sh <pr-url> set <line>      a wait is in progress (state pending)
#   jg-pr-wait.sh <pr-url> clear [<line>]  no wait (state success)
#
# "clear" is state success rather than a deleted status, because a pending
# status is an unfinished check: bin/jg-pr-merge.sh's rollup read refuses a
# check that is not green, and a repository that requires all checks would
# refuse the merge itself. bin/jg-pr-merge.sh therefore publishes success
# immediately before it merges, and again once the merge is proven.
#
# <line> is collapsed to one line and capped at GitHub's 140-character
# description limit. A GitHub pull request is the only provider with commit
# statuses, so any other forge URL is accepted and left untouched rather than
# refused: a caller never has to know which forge it is holding.
#
# Exit status is 0 when the status is published (or the URL is not GitHub) and
# the wait cleared, 1 when the forge call failed, and 2 on a usage error. A
# caller that must not fail, such as a merge path, treats a nonzero exit as a
# warning rather than a reason to stop.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo 'usage: jg-pr-wait.sh <pr-url> set <line> | clear [<line>]' >&2
  exit 2
fi
URL=$1
VERB=$2
shift 2

case "$VERB" in
  set)
    LINE=${1-}
    [ -n "$LINE" ] || { echo 'error: set needs the wait line' >&2; exit 2; }
    STATE=pending
    ;;
  clear)
    LINE=${1:-no wait}
    STATE=success
    ;;
  *)
    echo "error: unknown verb '$VERB' (expected set or clear)" >&2
    exit 2
    ;;
esac

jg_pr_url_parse "$URL" || { echo "error: '$URL' is not a supported pull request URL" >&2; exit 2; }
if ! jg_pr_wait_status "$URL" "$STATE" "$LINE"; then
  echo "error: could not publish the wait status on $URL" >&2
  exit 1
fi
printf '%s: %s\n' "$URL" "$LINE"
