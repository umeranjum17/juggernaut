#!/usr/bin/env bash
# stale-pr-alarm watcher check: alert on an open PR nobody is looking at. No model turn.
# Usage: stale-pr-alarm.sh check <jg-home>
#
# PR 394 sat two days on release/c-5, conflicting and with no checks, and nothing alerted. For every
# project in <home>/data/projects.md whose clone (<home>/projects/<name>) has a github.com origin, this
# lists the open PRs with gh-axi and raises one alert line per PR naming its URL and the reason:
#   - a release PR (its base or its head is release/c-N) with no started CI 30 minutes after it opened
#     (no check run past queued and no commit status on the head; PR 644 sat 80 minutes with none), or
#   - no checks and no update for 24 hours (no check run and no commit status on the head, and
#     updated_at older than 24 h), or
#   - its base is a release/* branch that already merged into the default branch (a closed, merged PR
#     from that branch into main exists, so the PR can never land where it points), or listed in
#     <home>/config/version-branch-carried (a closed release whose work moved to a newer one); that
#     alert names the live release branch.
# Each alert is the central `stranded` alert (bin/jg-alert.sh raise, then deliver; subject <owner>__<repo>.<number>), so it
# reaches the lead as one wake. The reason is remembered per PR in <home>/data/jg-merge-on-green/stale-pr-alarm/, so the
# next poll stays silent; a PR that is closed, healthy or changes reason resolves its alert and forgets it or raises it again.
# Only PRs we own are watched: the author is the home's gh login, or the PR URL is recorded as pr= in a
# task meta (<home>/state/*.meta). An outside author's PR on an upstream repo we only contribute to is ignored.
# A forge failure is silent and retried next sweep. Closing or rebasing the PR is out of scope, and so
# is the open-PR cap, which merge-on-green.sh owns. Nothing is printed when nothing happened.
# merge-on-green.sh runs this after its own work and hands over its remaining time in JG_STALE_PR_LIMIT.
# JG_RELEASE_CI_MINUTES (default 30) sets the release-PR wait.
# JG_STALE_PR_GH names the gh-axi binary (tests point it at recorded fixtures); JG_STRANDED_ALERT names jg-alert.sh.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: stale-pr-alarm.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
GH=${JG_STALE_PR_GH:-gh-axi}
MEM=$FMH/data/jg-merge-on-green/stale-pr-alarm
ALERT=${JG_STRANDED_ALERT:-$FMH/bin/jg-alert.sh}
umask 077
BUDGET=$(( ${JG_CHECK_TIMEOUT:-30} / 3 )); [ "$BUDGET" -ge 5 ] || BUDGET=5
START=$(date +%s)
RELEASE_WAIT_MIN=${JG_RELEASE_CI_MINUTES:-30}; case $RELEASE_WAIT_MIN in ''|*[!0-9]*) RELEASE_WAIT_MIN=30 ;; esac
RELEASE_WAIT=$(( RELEASE_WAIT_MIN * 60 ))
LIMIT=${JG_STALE_PR_LIMIT:-$(( START + ${JG_CHECK_TIMEOUT:-30} * 4 / 5 ))}
alert() { JG_HOME=$FMH "$ALERT" "$@"; }
# page <subject>: one live stranded alert for the subject, rung to the lead (a changed reason replaces the old record).
page() { alert resolve "stranded--$1" >/dev/null 2>&1; alert raise stranded "$1" | alert deliver; }
api() { timeout "$BUDGET" "$GH" api "$1" --jq "$2" 2>/dev/null; } # <path> <jq> -> jq text, nonzero on failure

me=$(api user .login) && [ -n "$me" ] || exit 0 # no login, no ownership test: retry next sweep
owned=$(cat "$FMH"/state/*.meta 2>/dev/null | sed -n 's/^pr=//p')

repos=$(sed -n 's/^- \(.*\)$/\1/p' "$FMH/data/projects.md" 2>/dev/null | while IFS= read -r line; do
  name=${line%% \[*}; name=${name%% - *}
  url=$(git -C "$FMH/projects/$name" remote get-url origin 2>/dev/null) || continue
  printf '%s\n' "$url" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)$#\2#p' | sed 's/\.git$//'
done | sort -u)

for repo in $repos; do
  [ "$(date +%s)" -lt "$LIMIT" ] || break
  prs=$(api "repos/$repo/pulls?state=open&per_page=100" '.[]|[.number,.html_url,.base.ref,.updated_at,.head.sha,.user.login,.created_at,.head.ref]|@tsv') || continue
  key=${repo//\//__}; flagged=' '; cut=0
  livebranches=$(api "repos/$repo/branches?per_page=100" '.[].name|select(test("^release/c-[0-9]+$"))') || livebranches=''

  while IFS=$'\t' read -r num url base updated sha author created headref; do
    [ -n "$num" ] || continue
    [ "$author" = "$me" ] || printf '%s\n' "$owned" | grep -qxF -- "$url" || continue
    [ "$(date +%s)" -lt "$LIMIT" ] || { cut=1; break; }
    reasons=''
    ts=$(date -u -d "$updated" +%s 2>/dev/null) || ts=
    # A release PR whose head has no started CI run after RELEASE_WAIT seconds; this subsumes the 24 h reason below.
    case "$base $headref" in *release/c-[0-9]*)
      cts=$(date -u -d "$created" +%s 2>/dev/null) || cts=
      if [ -n "$cts" ] && [ "$(( START - cts ))" -ge "$RELEASE_WAIT" ]; then
        runs=$(api "repos/$repo/commits/$sha/check-runs" '[.check_runs[]|select((.status // "completed") != "queued")]|length') && stat=$(api "repos/$repo/commits/$sha/status" '.statuses|length') \
          && [ "$runs" = 0 ] && [ "$stat" = 0 ] && reasons="release PR: no CI started ${RELEASE_WAIT_MIN} min after it opened"
      fi ;;
    esac
    if [ -z "$reasons" ] && [ -n "$ts" ] && [ "$(( START - ts ))" -ge 86400 ]; then
      runs=$(api "repos/$repo/commits/$sha/check-runs" .total_count) && stat=$(api "repos/$repo/commits/$sha/status" '.statuses|length') \
        && [ "$runs" = 0 ] && [ "$stat" = 0 ] && reasons='no checks and no update for 24 h'
    fi
    case $base in release/*)
      if awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length($0)) print }' "$FMH/config/version-branch-carried" 2>/dev/null | grep -qxF -- "$base"; then
        # A carried branch is closed: its work moved to a newer release, so name the live one.
        live=$(printf '%s\n' "$livebranches" | awk -F/ -v b="$base" 'BEGIN { sub(/.*c-/, "", b) } { n = $0; sub(/.*c-/, "", n); if (n + 0 > b + 0 && n + 0 > best) { best = n + 0; name = $0 } } END { if (name) print name }')
        reasons="${reasons:+$reasons; }base branch $base is a closed release branch whose work was carried${live:+; the live release branch is $live}"
      else
        merged=$(api "repos/$repo/pulls?state=closed&base=main&head=${repo%%/*}:$base&per_page=10" 'map(select(.merged_at!=null))|length') \
          && [ "${merged:-0}" -gt 0 ] && reasons="${reasons:+$reasons; }base branch $base is a release branch already merged into main"
      fi ;;
    esac
    [ -n "$reasons" ] || continue
    flagged="$flagged$num "
    [ "$(cat "$MEM/$key.$num" 2>/dev/null)" = "$reasons" ] && continue
    page "$key.$num"
    mkdir -p "$MEM" 2>/dev/null && printf '%s\n' "$reasons" > "$MEM/$key.$num" 2>/dev/null || :
  done <<< "$prs"
  # Forget a PR that is no longer flagged (closed, merged, or healthy again), so a new stall alerts again.
  [ "$cut" = 0 ] || continue
  for f in "$MEM/$key."*; do
    [ -f "$f" ] || continue
    case $flagged in *" ${f##*.} "*) ;; *) rm -f -- "$f"; alert resolve "stranded--${f##*/}" >/dev/null 2>&1 ;; esac
  done
done
exit 0
