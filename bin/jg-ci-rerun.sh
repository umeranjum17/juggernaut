#!/usr/bin/env bash
# jg-ci-rerun.sh - the one way to re-run a CI run. A red run is refused until its root-cause ticket carries a note.
# Usage: JG_HOME=<home> jg-ci-rerun.sh <run id> [--repo <owner/repo>] [--failed]
# The repository is --repo, else GH_REPO, else this clone's origin. A run that ended failure, timed_out or
# startup_failure is red: the watcher check (core/merge-on-green/red-ci-ticket.sh) files ticket ci-red-run-<run id>
# for it, and this script re-runs it only after that ticket's body holds a line that starts "root-cause:" followed
# by the cause. With no ticket yet, or no such line, it refuses with the next step and a non-zero exit. A run that
# is not red (green, cancelled, still running) is passed on to `gh run rerun` unchanged. JG_CI_RERUN_GH names the
# gh binary (tests use a recorded forge). It never edits a ticket and never re-runs on its own.
set -u
GH=${JG_CI_RERUN_GH:-gh-axi}
BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
usage() { echo "usage: JG_HOME=<home> jg-ci-rerun.sh <run id> [--repo <owner/repo>] [--failed]" >&2; exit 2; }
[ "$#" -ge 1 ] && [ -n "${JG_HOME:-}" ] || usage
id=$1; shift
case $id in ''|*[!0-9]*) usage ;; esac
repo=${GH_REPO:-}; failed=
while [ "$#" -gt 0 ]; do
  case $1 in
    --repo) [ "$#" -ge 2 ] || usage; repo=$2; shift ;;
    --failed) failed=--failed ;;
    *) usage ;;
  esac
  shift
done
if [ -z "$repo" ]; then
  repo=$(git remote get-url origin 2>/dev/null | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)$#\2#p' | sed 's/\.git$//')
fi
[ -n "$repo" ] || { echo "jg-ci-rerun: no repository: pass --repo <owner/repo>" >&2; exit 2; }
concl=$("$GH" api "repos/$repo/actions/runs/$id" --jq .conclusion 2>/dev/null) \
  || { echo "jg-ci-rerun: cannot read run $id in $repo; nothing was re-run" >&2; exit 1; }
case $concl in
  failure|timed_out|startup_failure)
    ticket=ci-red-run-$id
    show=$(JG_HOME=$JG_HOME "$BIN/jg-backlog.sh" show "$ticket" 2>/dev/null) || {
      echo "jg-ci-rerun: refused: run $id is red ($concl) and has no root-cause ticket yet. Never re-run to see if it passes." >&2
      echo "jg-ci-rerun: the watcher files $ticket on its next poll. Find the root cause, add a 'root-cause: <cause>' line to that ticket, then re-run." >&2
      exit 1; }
    printf '%s\n' "$show" | grep -Eq '(body: "|\\n)root-cause:[[:space:]]*[^[:space:]\\]' || {
      echo "jg-ci-rerun: refused: run $id is red ($concl) and ticket $ticket has no root-cause note. Never re-run to see if it passes." >&2
      echo "jg-ci-rerun: find the root cause, then add a line 'root-cause: <cause>' to the ticket body (jg-backlog.sh update $ticket --body ...), then re-run." >&2
      exit 1; }
    ;;
esac
exec "$GH" run rerun "$id" -R "$repo" ${failed:+"$failed"}
