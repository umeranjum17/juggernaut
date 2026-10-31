#!/usr/bin/env bash
# Watch the GitHub run of a head this home merged ahead of CI, and open exactly
# one fix item if it goes red. This is an alarm, never a gate: the merge already
# happened, so nothing here can refuse or undo it.
#
# Usage: jg-post-merge-ci.sh <task-id> <PR URL> <merged head>
#        jg-post-merge-ci.sh --main [<workflow name>]
#
# The second form is the same alarm for the heavy behaviour suite on main, which
# .github/workflows/behavior.yml runs nightly and after every push. It reads that
# workflow's latest completed run instead of polling one head, files exactly one
# item per red run id in data/jg-post-merge-ci/main-<run id>.filed, and names the
# run. The workflow name defaults to "Behavior suite"; pass another name to watch
# a different one. A run still in flight, or an unreadable run list, is reported
# and changes nothing.
#
# bin/jg-local-suite-lib.sh's jg_local_suite_arm_ci_alarm starts this detached
# right after a merge proven by the local suite, so the merge returns at once.
# It polls the runs filed against that exact commit until every run finishes or
# JG_POST_MERGE_CI_DEADLINE seconds pass (default 2700, polled every
# JG_POST_MERGE_CI_INTERVAL seconds, default 30). A run that ends in failure,
# timed_out, startup_failure or action_required is red.
#
# One item per task and head: data/jg-post-merge-ci/<task>.filed records that an
# item was opened, so a re-run cannot file a second one. The item names the run
# id, so a reader opens the failing run directly. A wake line is queued too, so
# the red result reaches the lead instead of sitting in a log.
# A deadline that passes with runs still going, an unreadable run list, or a
# backlog that refuses the add are all reported in the log and change nothing
# else, because an alarm that cannot report itself must not pretend it did.
# Run it by hand any time: its exit status is 0 once it reached a verdict or its
# deadline, and 2 for a malformed request.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"

if [ "${1:-}" = --main ]; then
  MAIN_MODE=1
  if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ -z "$2" ]; }; then
    echo "usage: jg-post-merge-ci.sh --main [<workflow name>]" >&2
    exit 2
  fi
else
  MAIN_MODE=0
  if [ "$#" -ne 3 ] || [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "usage: jg-post-merge-ci.sh <task-id> <PR URL> <merged head>" >&2
    exit 2
  fi
fi
ID=${1:-}
URL=${2:-}
HEAD=${3:-}
DEADLINE_SECS=${JG_POST_MERGE_CI_DEADLINE:-2700}
INTERVAL=${JG_POST_MERGE_CI_INTERVAL:-30}
case "$DEADLINE_SECS" in ''|*[!0-9]*) DEADLINE_SECS=2700 ;; esac
case "$INTERVAL" in ''|0*|*[!0-9]*) INTERVAL=30 ;; esac

DIR="$DATA/jg-post-merge-ci"
FILED="$DIR/$ID.filed"
mkdir -p "$DIR" || exit 0
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# red_run_url <run id>: the run's own page, so a reader opens the failure.
red_run_url() {  # <repo> <run id>
  printf 'https://github.com/%s/actions/runs/%s\n' "$1" "$2"
}

# file_red_item <item id> <filed path> <run id> <workflow> <conclusion> <head> <body> <wake text>
# The one filing path for both modes: it adds the backlog item, records that it
# filed, and queues the wake. A backlog that refuses the add is reported and
# changes nothing else.
file_red_item() {
  local item=$1 filed=$2 run_id=$3 workflow=$4 conclusion=$5 head=$6 body=$7 wake=$8
  if "$SCRIPT_DIR/jg-tasks-axi.sh" add "$item" \
    "[blocker] $workflow went red at $head (run $run_id)" \
    --kind ship --body "$body" >/dev/null 2>&1; then
    printf '%s %s\n' "$run_id" "$head" > "$filed"
    say "filed $item for red run $run_id ($workflow, $conclusion) at head $head"
    # shellcheck source=bin/jg-wake-lib.sh
    if . "$SCRIPT_DIR/jg-wake-lib.sh" 2>/dev/null; then
      jg_wake_append check "post-merge-ci-$item" "$wake" >/dev/null 2>&1 \
        || say "could not queue the red-CI wake for $item"
    fi
    return 0
  fi
  say "$workflow went red at head $head on run $run_id, but backlog item $item could not be added"
  return 1
}

if [ "$MAIN_MODE" -eq 1 ]; then
  # The heavy suite on main: one verdict per run id, never a gate.
  WORKFLOW=${2:-Behavior suite}
  latest=$(gh run list --branch main --workflow "$WORKFLOW" --limit 1 \
    --json databaseId,status,conclusion,headSha 2>/dev/null) || latest=
  if [ -z "$latest" ]; then
    say "could not read the latest $WORKFLOW run on main, so there is no verdict"
    exit 0
  fi
  run_id=$(printf '%s' "$latest" | jq -r '.[0].databaseId // empty' 2>/dev/null) || run_id=
  status=$(printf '%s' "$latest" | jq -r '.[0].status // empty' 2>/dev/null) || status=
  conclusion=$(printf '%s' "$latest" | jq -r '.[0].conclusion // empty' 2>/dev/null) || conclusion=
  head=$(printf '%s' "$latest" | jq -r '.[0].headSha // empty' 2>/dev/null) || head=
  if [ -z "$run_id" ]; then
    say "no $WORKFLOW run on main has been recorded yet, so there is no verdict"
    exit 0
  fi
  if [ "$status" != completed ]; then
    say "the latest $WORKFLOW run on main ($run_id) is $status, not finished; no verdict yet"
    exit 0
  fi
  case $conclusion in
    failure|timed_out|startup_failure|action_required) ;;
    *) say "the latest $WORKFLOW run on main ($run_id) ended $conclusion"; exit 0 ;;
  esac
  filed="$DIR/main-$run_id.filed"
  if [ -e "$filed" ]; then
    say "already filed for red run $run_id ($(cat "$filed" 2>/dev/null))"
    exit 0
  fi
  repo=$(git -C "$JG_ROOT" remote get-url origin 2>/dev/null | sed -n 's#.*github\.com[:/]\([^/]*/[^/.]*\)\(\.git\)\{0,1\}$#\1#p') || repo=
  [ -n "$repo" ] || repo=unknown/unknown
  item="ci-red-main-$run_id"
  body="$WORKFLOW went red on main at head $head: run $run_id ($conclusion).
$(red_run_url "$repo" "$run_id")
This run is the nightly and post-merge suite, so no pull request was blocked by it.
Fix the failing check on main before the next change builds on it."
  file_red_item "$item" "$filed" "$run_id" "$WORKFLOW" "$conclusion" "$head" "$body" \
    "check: $WORKFLOW went red on main: run $run_id ($conclusion) failed at head $head; fix item $item opened"
  exit 0
fi

if [ -e "$FILED" ]; then
  say "already filed for $ID at head $HEAD ($(cat "$FILED" 2>/dev/null))"
  exit 0
fi

deadline=$(( $(date +%s) + DEADLINE_SECS ))
while :; do
  runs=$(gh run list --commit "$HEAD" --limit 50 \
    --json databaseId,status,conclusion,workflowName 2>/dev/null) || runs=
  if [ -n "$runs" ]; then
    pending=$(printf '%s' "$runs" | jq -r '[.[] | select(.status != "completed")] | length' 2>/dev/null) || pending=''
    red=$(printf '%s' "$runs" | jq -r '
      [ .[] | select(.status == "completed")
        | select(.conclusion == "failure" or .conclusion == "timed_out"
                 or .conclusion == "startup_failure" or .conclusion == "action_required") ]
      | .[0] // empty | "\(.databaseId) \(.workflowName) \(.conclusion)"' 2>/dev/null) || red=''
    if [ -n "$red" ]; then
      run_id=${red%% *}
      rest=${red#* }
      workflow=${rest% *}
      conclusion=${rest##* }
      item="ci-red-$ID"
      repo=$(printf '%s' "$URL" | sed -n 's#^https://github.com/\([^/]*/[^/]*\)/pull/.*#\1#p')
      body="The merge of $URL landed on the proof of its local suite receipt.
Its GitHub run at head $HEAD then went red: run $run_id ($workflow, $conclusion).
$(red_run_url "$repo" "$run_id")
Fix the failing check on main before the next change builds on it."
      file_red_item "$item" "$FILED" "$run_id" "$workflow" "$conclusion" "$HEAD" "$body" \
        "check: CI went red after merging $URL: run $run_id ($workflow) failed at head $HEAD; fix item $item opened" \
        || true
      exit 0
    fi
    if [ "$pending" = 0 ]; then
      say "every run for head $HEAD finished green"
      exit 0
    fi
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    say "no verdict for head $HEAD within ${DEADLINE_SECS}s; the GitHub run is still going or unreadable"
    exit 0
  fi
  sleep "$INTERVAL"
done
