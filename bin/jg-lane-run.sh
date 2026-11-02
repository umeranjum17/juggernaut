#!/usr/bin/env bash
# jg-lane-run.sh - run a replay or measurement harness so it dies with its lane.
# Usage: jg-lane-run.sh <task-id> -- <command> [args...]
# The harness runs in its own process group and carries a per-run token in its
# environment (JG_LANE_TOKEN), which every descendant inherits. The token is
# recorded in state/<id>.lane-groups BEFORE the harness starts. When the harness
# ends, or this wrapper is signalled, the whole group is stopped, so a loop the
# harness backgrounded does not outlive it. If this wrapper is itself killed
# (no trap runs), bin/jg-teardown.sh stops every process still carrying a
# recorded token, including ones that left the group - the record decides, never
# a name or pattern. Exit status is the harness's. Needs bash job control, so it
# works with or without setsid(1).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"

id=${1:-}
case $id in '' | *[!A-Za-z0-9._-]* | .*) echo "usage: jg-lane-run.sh <task-id> -- <command> [args...]" >&2; exit 2 ;; esac
shift
[ "${1:-}" != -- ] || shift
[ "$#" -gt 0 ] || { echo "jg-lane-run: no command given" >&2; exit 2; }

token=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null) || token=
[ -n "$token" ] || { echo "jg-lane-run: cannot make a run token (no /proc uuid or uuidgen); nothing was started" >&2; exit 1; }
if ! { mkdir -p "$STATE" && printf '%s\n' "$token" >>"$STATE/$id.lane-groups"; }; then
  echo "jg-lane-run: cannot record the run token in $STATE/$id.lane-groups; nothing was started" >&2
  exit 1
fi

set -m
JG_LANE_TOKEN=$token "$@" </dev/null &
pgid=$!
set +m

stop_group() { # TERM, then KILL what is left, of the harness group only
  kill -TERM -- "-$pgid" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$pgid" 2>/dev/null || return 0; sleep 0.1; done
  kill -KILL -- "-$pgid" 2>/dev/null || true
}
trap 'stop_group; exit 143' TERM INT HUP
wait "$pgid"
rc=$?
stop_group
exit "$rc"
