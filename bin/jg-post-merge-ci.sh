#!/usr/bin/env bash
# Watch the GitHub run of a head this home merged ahead of CI, and open exactly
# one fix-forward item if it goes red. This is an alarm, never a gate: the merge
# already happened, so nothing here can refuse or undo it.
#
# Nothing is ever reverted. A red main is fixed by a change that moves forward,
# because a revert costs the time it takes to land it plus the time it takes to
# land the fix again, and the follow-up this alarm files is that fix. Every other
# pull request keeps merging while that item is open: the alarm never blocks the
# merge path, it only names the owner of the failure.
#
# Usage: jg-post-merge-ci.sh <task-id> <PR URL> <merged head>
#        jg-post-merge-ci.sh --main [--restore <project-dir>] [<workflow name>]
#
# The second form is the same alarm for the heavy behaviour suite on main, which
# .github/workflows/behavior.yml runs nightly and after every push. It reads that
# workflow's latest completed run instead of polling one head, files exactly one
# item per red run id in data/jg-post-merge-ci/main-<run id>.filed, and names the
# run. The workflow name defaults to "Behavior suite"; pass another name to watch
# a different one. A run still in flight, or an unreadable run list, is reported
# and changes nothing.
#
# A red run is judged by the verify's one rule (core/trunk-ci/run-rule.py, which asks
# core/trunk-verify/reduce.py) against the last green run of the same workflow, from the two runs'
# own timing aggregates: no new proof runs. A script that failed in the red run and passed in the
# green one is a new failure; the item names the run and the commit that introduced it (the newest
# commit between the two heads that touched the script, else the range). A script an open item
# already names is the same failure: that item is updated with the run and nothing new is filed. A
# timeout, a skip or an unreadable aggregate is incomplete and still files one item, never a pass.
# With --restore <project-dir> a run that is red under the rule (counted failures beyond the grace,
# JG_POST_MERGE_CI_GRACE, default 2) also sends `jg-trunk.sh ci <project-dir> <head> red`, which pins
# the homes back to the last green commit; a carried or incomplete result never does, and without
# the flag nothing is ever restored.
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

RESTORE_DIR=
if [ "${1:-}" = --main ]; then
  MAIN_MODE=1
  shift
  if [ "${1:-}" = --restore ]; then
    [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "usage: jg-post-merge-ci.sh --main [--restore <project-dir>] [<workflow name>]" >&2; exit 2; }
    RESTORE_DIR=$2
    shift 2
  fi
  if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ -z "$1" ]; }; then
    echo "usage: jg-post-merge-ci.sh --main [--restore <project-dir>] [<workflow name>]" >&2
    exit 2
  fi
  set -- --main "$@"
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
# filed, and raises the line-red alert. A backlog that refuses the add is reported and
# changes nothing else.
file_red_item() {
  local item=$1 filed=$2 run_id=$3 workflow=$4 conclusion=$5 head=$6 body=$7 wake=$8
  if "$SCRIPT_DIR/jg-backlog.sh" add "$item" \
    "Post-merge CI went red" -l blocker \
    --kind ship --body "$body" >/dev/null 2>&1; then
    printf '%s %s\n' "$run_id" "$head" > "$filed"
    say "filed $item for red run $run_id ($workflow, $conclusion) at head $head"
    JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-alert.sh" raise line-red "post-merge-ci-$item" --note "$wake" 2>/dev/null \
      | JG_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/jg-alert.sh" deliver >/dev/null 2>&1 \
      || say "could not raise line-red for $item"
    return 0
  fi
  say "$workflow went red at head $head on run $run_id, but backlog item $item could not be added"
  return 1
}

# The ids of the open items this alarm filed for a script, as JSON: one marker file per script, written when the item is filed.
open_items_json() {
  local m script item st rows=
  for m in "$DIR"/script-*.item; do
    [ -f "$m" ] || continue
    read -r script item < "$m" || continue
    st=$("$SCRIPT_DIR/jg-backlog.sh" show "$item" 2>/dev/null | sed -n 's/^ *state: *//p' | head -n 1)
    rows="$rows$(jq -cn --arg s "$script" --arg i "$item" --arg t "${st:-open}" '{script: $s, item: $i, status: $t}'),"
  done
  printf '[%s]' "${rows%,}"
}

# Append one line to an item this alarm filed: its body is kept in item-<id>.body, because an update replaces the whole body.
note_item() {  # <item> <line>
  local body="$DIR/item-$1.body"
  [ -f "$body" ] || return 1
  printf '%s\n' "$2" >> "$body"
  "$SCRIPT_DIR/jg-backlog.sh" update "$1" --body "$(cat "$body")" >/dev/null 2>&1
}

# The red run on main, judged by the verify's one rule against the last green run (header). Reads the two runs' own timing aggregates,
# so no suite runs again. Sets nothing; files, matches and restores as the header says.
judge_main_run() {
  local tmp green gid ghead verdict n_file n_matched status item body list script matched_note slug restored=0 rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/jg-post-merge-ci.XXXXXX") || { say "no scratch directory, so run $run_id is not judged"; return 0; }
  mkdir -p "$tmp/red" "$tmp/green"
  gh run download "$run_id" -n jg-test-timing-aggregate -D "$tmp/red" >/dev/null 2>&1 || true
  green=$(gh run list --branch main --workflow "$WORKFLOW" --status success --limit 1 --json databaseId,headSha 2>/dev/null) || green=
  gid=$(printf '%s' "$green" | jq -r '.[0].databaseId // empty' 2>/dev/null) || gid=
  ghead=$(printf '%s' "$green" | jq -r '.[0].headSha // empty' 2>/dev/null) || ghead=
  [ -z "$gid" ] || gh run download "$gid" -n jg-test-timing-aggregate -D "$tmp/green" >/dev/null 2>&1 || true
  open_items_json > "$tmp/open.json"
  verdict=$(python3 "$JG_ROOT/core/trunk-ci/run-rule.py" judge --red "$tmp/red/jg-test-timing-aggregate.json" \
    --green "$tmp/green/jg-test-timing-aggregate.json" --open "$tmp/open.json" --repo "$JG_ROOT" --green-head "$ghead" \
    --red-head "$head" --grace "${JG_POST_MERGE_CI_GRACE:-2}" 2>/dev/null) || verdict=
  rm -rf -- "$tmp"
  if [ -z "$verdict" ]; then
    say "the rule could not judge run $run_id; it is filed as one red run"
    verdict='{"status":"incomplete","restore":false,"missing":["rule"],"file":[],"matched":[],"reasons":[]}'
  fi
  status=$(printf '%s' "$verdict" | jq -r '.status')
  n_file=$(printf '%s' "$verdict" | jq -r '.file | length')
  n_matched=$(printf '%s' "$verdict" | jq -r '.matched | length')
  matched_note="run $run_id ($WORKFLOW, $conclusion) at head $head failed the same script again: $(red_run_url "$repo" "$run_id")"
  # Failures an open item already owns: the item is updated, nothing new is filed or alerted for them.
  while IFS=$'\t' read -r script item; do
    [ -n "$script" ] || continue
    if note_item "$item" "$matched_note"; then say "matched $script to open item $item"; else say "matched $script to open item $item, but its note could not be added"; fi
  done < <(printf '%s' "$verdict" | jq -r '.matched[] | [.script, .item] | @tsv')
  if [ "$n_file" -gt 0 ] || [ "$n_matched" -eq 0 ]; then
    item="ci-red-main-$run_id"
    list=$(printf '%s' "$verdict" | jq -r '.file[] | "- \(.script): \(.class); introduced by \(.commit)"')
    body="$WORKFLOW went red on main at head $head: run $run_id ($conclusion).
$(red_run_url "$repo" "$run_id")
This run is the nightly and post-merge suite, so no pull request was blocked by it.
Judged against the last green run${ghead:+ (head $ghead)} by the verify's one rule: $status.
${list:+$list
}Fix the failing check on main before the next change builds on it."
    if file_red_item "$item" "$filed" "$run_id" "$WORKFLOW" "$conclusion" "$head" "$body" \
        "check: $WORKFLOW went red on main: run $run_id ($conclusion) failed at head $head; fix item $item opened"; then
      printf '%s\n' "$body" > "$DIR/item-$item.body"
      while IFS= read -r script; do
        [ -n "$script" ] || continue
        slug=$(printf '%s' "$script" | tr -c 'A-Za-z0-9._-' '_')
        printf '%s %s\n' "$script" "$item" > "$DIR/script-$slug.item"
      done < <(printf '%s' "$verdict" | jq -r '.file[].script')
    fi
  else
    printf 'matched %s\n' "$status" > "$filed"
    say "run $run_id failed only scripts that open items already own: no new item"
  fi
  if [ -n "$RESTORE_DIR" ] && [ "$(printf '%s' "$verdict" | jq -r '.restore')" = true ]; then
    restored=1
    "$SCRIPT_DIR/jg-trunk.sh" ci "$RESTORE_DIR" "$head" red >/dev/null 2>&1 && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then say "run $run_id is red under the rule: the homes went back to the last green commit"
    else say "run $run_id is red under the rule, but the restore of $head was refused (exit $rc); nothing moved"; fi
  fi
  [ "$restored" -eq 1 ] || say "run $run_id is $status under the rule: no restore"
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
  judge_main_run
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
