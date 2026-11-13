#!/usr/bin/env bash
# worker.sh - report-only observer of the worker machine (core/machines/tables/worker.tsv): one word per agent session of a lane.
#
# Usage: worker.sh <task-id>   print starting, working, waiting, done, lost or exited; print nothing when no record names the task
# Records read: state/<id>.meta (the session exists), state/<id>.status (the lane spoke) and the word of bin/jg-crew-state.sh,
# which owns the current state. This file holds none of its rules; it only places that word in the six states of the table:
#   no meta, a status log   exited   the session is over (teardown removed the meta; the log stays)
#   meta, no status line    starting the session is up and has not spoken
#   working                 working
#   parked, paused, blocked waiting  the agent waits for someone, and said who in its status line
#   done                    done
#   failed, unknown         lost     no sign of life, or a failed line: the plan gives both the health word lost
# The command only reads: it writes no record and runs no move.
set -u
id=${1:-}; [ -n "$id" ] || { echo "usage: worker.sh <task-id>" >&2; exit 2; }
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}
if [ ! -f "$STATE/$id.meta" ]; then [ -s "$STATE/$id.status" ] && echo exited; exit 0; fi
[ -s "$STATE/$id.status" ] || { echo starting; exit 0; }
word=$("$JG_HOME/bin/jg-crew-state.sh" "$id" 2>/dev/null | sed -n 's/^state: \([a-z]*\).*/\1/p')
case $word in
  working) echo working ;;
  parked|paused|blocked) echo waiting ;;
  "done") echo "done" ;;
  *) echo lost ;;
esac
