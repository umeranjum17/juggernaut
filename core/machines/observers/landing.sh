#!/usr/bin/env bash
# landing.sh - report-only observer of the landing machine (core/machines/tables/landing.tsv): one word per landing run of a lane.
#
# Usage: landing.sh <task>.<head>[.<ctx>]   print queued, rebasing, resolving, retesting, checking, retrying, landed, returned or withdrawn
# Records read, never written (the command only reads: it writes no record and runs no move):
#   data/jg-trunk-landing/<id>.state   the lander's line: running <epoch> [<pid>], wait, retry, env-wait, final or landed
#   data/trunk-resolving.tsv           the conflict run of bin/jg-trunk.sh (resolving, resolved, returned), by task and lane commit
#   data/trunk-landing-phases.tsv      the phase rows of bin/jg-trunk.sh lane_admit (retesting, returned, checking), the same columns
#   data/jg-trunk-landing/retired/     a final the check put aside, and state/<task>.meta with the lane's branch (the head the lane has now)
# The word of each record line:
#   landed                      landed
#   final                       returned (a retired final of an old head too; of the head the lane has now: queued, it is judged again)
#   retry, env-wait             retrying   the runner or the environment failed, which says nothing about the commit
#   wait, no line               queued     (withdrawn when the lane has a newer head, since nothing started on this one)
#   running <epoch> [<pid>]     the newest phase row of the run: resolving, resolved (retesting), checking or returned; with none, rebasing
# A running line with no epoch above 0, an epoch over 6 hours old, or a pid that is not a number prints running-no-epoch, running-expired or
# running-bad-pid: those are no state of the table, and `jg-machine.sh show` reports them as a finding.
set -u
export LC_ALL=C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P); root=$(cd "$here/../../.." && pwd -P)
JG_HOME=${JG_HOME:-${JG_ROOT_OVERRIDE:-$root}}
STATE=${JG_STATE_OVERRIDE:-$JG_HOME/state}; DATA=${JG_DATA_OVERRIDE:-$JG_HOME/data}; MEM=$DATA/jg-trunk-landing
id=${1:-}; [ -n "$id" ] || { echo "usage: landing.sh <task>.<head>[.<ctx>]" >&2; exit 2; }
[[ $id =~ ^(.+)\.([0-9a-f]{40,64})(\..*)?$ ]] || { echo queued; exit 0; }
task=${BASH_REMATCH[1]}; head=${BASH_REMATCH[2]}

# The head the lane has now (its branch in the project of state/<task>.meta); empty when the lane has no record or no branch.
lane_head() {
  local meta=$STATE/$task.meta proj br
  [ -f "$meta" ] || return 0
  proj=$(sed -n 's/^project=//p' "$meta" | tail -n 1); br=$(sed -n 's/^branch=//p' "$meta" | tail -n 1)
  git -C "${proj:-/nonexistent}" rev-parse --verify --quiet "refs/heads/${br:-fm/$task}^{commit}" 2>/dev/null || true
}
newer_head() { local now; now=$(lane_head); [ -n "$now" ] && [ "$now" != "$head" ]; }

# The newest phase row of this run: the state of the last row (by epoch, the later line on a tie) of both files, for this task and lane commit.
phase() {
  local f=
  for n in trunk-resolving.tsv trunk-landing-phases.tsv; do [ ! -f "$DATA/$n" ] || f="$f $DATA/$n"; done
  [ -n "$f" ] || return 0
  # shellcheck disable=SC2086 # the two file names hold no space
  awk -F'\t' -v t="$task" -v h="$head" '$1 == t && $4 == h && $6 + 0 >= best { best = $6 + 0; w = $5 } END { print w }' $f
}

st=$MEM/$id.state
if [ ! -f "$st" ]; then
  if [ -f "$MEM/retired/$id.state" ]; then [ "$(lane_head)" = "$head" ] && echo queued || echo returned; exit 0; fi
  newer_head && echo withdrawn || echo queued; exit 0
fi
read -r word a b < "$st"
case $word in
  landed) echo landed ;;
  final) echo returned ;;
  retry|env-wait) echo retrying ;;
  wait) newer_head && echo withdrawn || echo queued ;;
  running)
    case $a in ''|*[!0-9]*) echo running-no-epoch; exit 0 ;; esac
    a=$((10#$a)); [ "$a" -gt 0 ] || { echo running-no-epoch; exit 0; }
    [ $(( $(date +%s) - a )) -le 21600 ] || { echo running-expired; exit 0; }
    case ${b:-0} in *[!0-9]*) echo running-bad-pid; exit 0 ;; esac
    case $(phase) in resolving) echo resolving ;; resolved|retesting) echo retesting ;; checking) echo checking ;; returned) echo returned ;; *) echo rebasing ;; esac ;;
  *) echo "$word" ;;
esac
