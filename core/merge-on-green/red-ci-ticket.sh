#!/usr/bin/env bash
# red-ci-ticket watcher check: a red CI run files one root-cause ticket, never a re-run. No model turn.
# Usage: red-ci-ticket.sh check <jg-home>
#
# For every project in <home>/data/projects.md whose clone (<home>/projects/<name>) has a github.com
# origin, this lists the newest completed run of each workflow on the default branch, on every release/*
# branch an open PR targets, and on the head of every open PR. A run that ended failure, timed_out or
# startup_failure and has no ticket yet files one backlog item through bin/jg-backlog.sh:
#   id    ci-red-run-<run id>      (the run id is the key, so a run files once)
#   title [blocker] CI red: <workflow> <failing job>: find the root cause
#   body  run id and URL, failing job, the first failing line of its log, "never re-run; fix the root cause"
# The ticket is ordinary ready work for the owning lead. bin/jg-ci-rerun.sh is the only re-run path
# and refuses a red run until that ticket carries a "root-cause:" note.
# Each filing prints one alert line. The run is remembered in <home>/data/jg-merge-on-green/red-ci-ticket/,
# so the next poll files and prints nothing; a failed add or a forge failure is silent and retried next
# sweep. A green run files nothing. merge-on-green.sh runs this after its own work and hands over its
# remaining time in JG_RED_CI_LIMIT. JG_RED_CI_GH names the gh-axi binary, JG_RED_CI_LOG_GH the gh binary that reads job logs (tests use recorded fixtures).
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: red-ci-ticket.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
GH=${JG_RED_CI_GH:-gh-axi}
LOGGH=${JG_RED_CI_LOG_GH:-${JG_RED_CI_GH:-gh}} # gh-axi and gh refuse a log with colour codes unless gh is told to allow them
MEM=$FMH/data/jg-merge-on-green/red-ci-ticket
umask 077
BUDGET=$(( ${JG_CHECK_TIMEOUT:-30} / 3 )); [ "$BUDGET" -ge 5 ] || BUDGET=5
LIMIT=${JG_RED_CI_LIMIT:-$(( $(date +%s) + ${JG_CHECK_TIMEOUT:-30} * 4 / 5 ))}
api() { timeout "$BUDGET" "$GH" api "$1" --jq "$2" 2>/dev/null; } # <path> <jq> -> jq text, nonzero on failure
RED='select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="startup_failure")'
# The newest completed run of each workflow, kept only when red: a fixed workflow's old red run is not ticketed.
NEWEST_RED=".workflow_runs|group_by(.workflow_id)|map(max_by(.created_at))|.[]|$RED|[.id,.name,.html_url,.head_sha,.conclusion]|@tsv"

# file <repo> <project> <run id> <workflow> <url> <sha> <conclusion>
file() {
  local repo=$1 proj=$2 id=$3 wf=$4 url=$5 sha=$6 concl=$7 job='' jid='' line='' item title body
  item=ci-red-run-$id
  [ ! -e "$MEM/${repo//\//__}.$id" ] || return 0
  job=$(api "repos/$repo/actions/runs/$id/jobs" '.jobs|map(select(.conclusion=="failure" or .conclusion=="timed_out"))|.[0]|[.id,.name]|@tsv' || :)
  jid=${job%%$'\t'*}; job=${job#*$'\t'}
  case $jid in ''|*[!0-9]*) jid=''; job='(job not readable)' ;; esac
  if [ -n "$jid" ]; then
    line=$(timeout "$BUDGET" "$LOGGH" api "repos/$repo/actions/jobs/$jid/logs" --allow-escape-sequences 2>/dev/null | head -c 4000000 \
      | sed 's/\x1b\[[0-9;]*m//g; s/^[0-9TZ:.-]* //' | grep -m1 -E '##\[error\]|(^|[^[:alnum:]])(not ok|FAIL|Error|error:)' | head -c 300 || :)
  fi
  [ -n "$line" ] || line='(no failing line found in the log; open the run)'
  title="[blocker] CI red: $wf $job: find the root cause"
  body="CI went red: $wf, run $id ($concl) at $sha in $repo (project $proj). Find the root cause.
Run: $id
URL: $url
Failing job: $job
First failing line: $line
Never re-run; fix the root cause. bin/jg-ci-rerun.sh refuses a re-run of this run until this ticket carries a 'root-cause:' note."
  if JG_HOME="$FMH" timeout "$BUDGET" "$FMH/bin/jg-backlog.sh" add "$item" "$title" --kind ship --body "$body" >/dev/null 2>&1 \
    || JG_HOME="$FMH" timeout "$BUDGET" "$FMH/bin/jg-backlog.sh" show "$item" >/dev/null 2>&1; then
    mkdir -p "$MEM" 2>/dev/null && printf '%s\n' "$url" > "$MEM/${repo//\//__}.$id" 2>/dev/null || :
    echo "red-ci-ticket: $url: $wf $job went red; filed $item ($proj); fix the root cause, never re-run"
  fi
}

projects=$(sed -n 's/^- \(.*\)$/\1/p' "$FMH/data/projects.md" 2>/dev/null | while IFS= read -r line; do
  name=${line%% \[*}; name=${name%% - *}
  url=$(git -C "$FMH/projects/$name" remote get-url origin 2>/dev/null) || continue
  repo=$(printf '%s\n' "$url" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)$#\2#p' | sed 's/\.git$//')
  [ -z "$repo" ] || printf '%s\t%s\n' "$repo" "$name"
done | sort -u)

while IFS=$'\t' read -r repo proj; do
  [ -n "$repo" ] || continue
  [ "$(date +%s)" -lt "$LIMIT" ] || break
  branches=$(api "repos/$repo" .default_branch) || continue
  prs=$(api "repos/$repo/pulls?state=open&per_page=100" '.[]|[.base.ref,.head.sha]|@tsv') || prs=
  branches="$branches $(printf '%s\n' "$prs" | awk -F'\t' '$1 ~ /^release\//{print $1}' | sort -u | tr '\n' ' ')"
  runs=''
  for b in $branches; do
    [ "$(date +%s)" -lt "$LIMIT" ] || break
    runs="$runs$(api "repos/$repo/actions/runs?branch=$b&status=completed&per_page=30" "$NEWEST_RED" || :)"$'\n'
  done
  for sha in $(printf '%s\n' "$prs" | cut -f2 | sort -u); do
    [ "$(date +%s)" -lt "$LIMIT" ] || break
    runs="$runs$(api "repos/$repo/actions/runs?head_sha=$sha&status=completed&per_page=30" "$NEWEST_RED" || :)"$'\n'
  done
  printf '%s\n' "$runs" | sort -u | while IFS=$'\t' read -r id wf url sha concl; do
    [ -n "$id" ] && [ "$(date +%s)" -lt "$LIMIT" ] && file "$repo" "$proj" "$id" "$wf" "$url" "$sha" "$concl"
  done
done <<< "$projects"
exit 0
