#!/usr/bin/env bash
# pool-reserve: the copies of a project follow the home's lane limit, and two copies stay free for a red fix.
# Usage: reserve.sh limit <jg-home>                         print the copy cap: the lane limit plus the two reserved copies ("-" when the home has no lane limit)
#        reserve.sh admit <jg-home> <project-dir> [--red-fix]   exit 0 when a new copy may be leased, 75 (with a "deferred:" line) when not
# An ordinary lane may lease a copy only while the leased copies are fewer than the lane limit, so the last two copies of the
# cap stay free. A red-fix lane (jg-spawn.sh --red-fix-of) may use them, up to the cap. A home with no lane limit
# (core/lane-scale/scale.sh target prints "-") is left to the pool's own max_trees. This script leases, ends and removes nothing.
# A status that cannot be read leaves the count unknown: that is a third answer, not zero. admit then exits 75 with a "deferred:"
# line that says the copies cannot be counted, and the start retries on its own (the same approval, the next beat).
# JG_POOL_RESERVE_STATUS names the command that prints `treehouse status` for a project (a test points it at a stand-in);
# JG_POOL_RESERVE_KEEP overrides the number of reserved copies (default 2).
set -u
RESERVE=${JG_POOL_RESERVE_KEEP:-2}
case "$RESERVE" in ''|*[!0-9]*) RESERVE=2 ;; esac
usage() { echo "usage: reserve.sh limit <jg-home> | admit <jg-home> <project-dir> [--red-fix]" >&2; exit 2; }
[ "$#" -ge 2 ] || usage
CMD=$1; HOME_DIR=$2
[ -d "$HOME_DIR" ] || usage
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
lane_limit() { "$HERE/../lane-scale/scale.sh" target "$HOME_DIR" 2>/dev/null | awk 'NF { print; exit }'; }

case "$CMD" in
  limit)
    [ "$#" -eq 2 ] || usage
    l=$(lane_limit)
    case "$l" in ''|*[!0-9]*) echo -; exit 0 ;; esac
    echo $((l + RESERVE)) ;;
  admit)
    [ "$#" -ge 3 ] && [ -d "$3" ] || usage
    PROJECT=$3; RED=0
    case "${4:-}" in '') ;; --red-fix) RED=1 ;; *) usage ;; esac
    [ "$#" -le 4 ] || usage
    l=$(lane_limit)
    case "$l" in ''|*[!0-9]*) exit 0 ;; esac
    cap=$((l + RESERVE))
    # An unread count is its own state, never zero: a status that fails leaves the copies unknown, and the start waits and retries.
    status_err=$(mktemp "${TMPDIR:-/tmp}/jg-pool-reserve.XXXXXX") || exit 1
    if [ -n "${JG_POOL_RESERVE_STATUS:-}" ]; then out=$("$JG_POOL_RESERVE_STATUS" "$PROJECT" 2>"$status_err")
    else out=$(cd "$PROJECT" && treehouse status 2>"$status_err"); fi && read_ok=1 || read_ok=0
    cause=$(grep -v '^[[:space:]]*$' "$status_err" | tail -n 1 | tr '\t\r' '  ' | cut -c1-160); rm -f -- "$status_err"
    if [ "$read_ok" -eq 0 ]; then
      echo "deferred: the copies of $(basename "$PROJECT") cannot be counted (treehouse status failed${cause:+: $cause}); the start retries" >&2
      exit 75
    fi
    leased=$(printf '%s\n' "$out" | grep -Ec '^[0-9]+[[:space:]]+leased([[:space:]]|$)')
    [ "$RED" -eq 1 ] && room=$cap || room=$l
    if [ "$leased" -ge "$room" ]; then
      if [ "$RED" -eq 1 ]; then why="the copy cap of $cap (lane limit $l plus $RESERVE reserved) is reached"
      else why="$RESERVE copies of the cap of $cap (lane limit $l plus $RESERVE reserved) stay free for a red fix"; fi
      echo "deferred: $leased copies of $(basename "$PROJECT") are leased and $why" >&2
      exit 75
    fi ;;
  *) usage ;;
esac
