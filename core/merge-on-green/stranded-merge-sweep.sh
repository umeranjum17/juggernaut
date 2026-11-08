#!/usr/bin/env bash
# stranded-merge-sweep watcher check: a merged pull request that never reached the default branch. No model turn.
# Usage: stranded-merge-sweep.sh check <jg-home>
#
# Six merged pull requests sat on release/c-10 for days: the release closed without its own pull request into
# main, so their work was on neither main nor the next release. The forge says so plainly. For every project in
# <home>/data/projects.md whose clone has a github.com origin, this reads each closed release branch (every
# release/c-N below the newest) and asks the forge how many commits it is ahead of the default branch.
#   - ahead 0: the release reached the default branch; nothing to say.
#   - ahead above 0 on a branch listed in <home>/config/version-branch-carried: its work was carried onto a newer
#     release (bin/jg-version-branch-lib.sh jg_carried_branches); counted, never alarmed.
#   - ahead above 0 on any other closed branch: stranded work. The first sweep that sees it stamps the time; once
#     it has stood for 48 hours (JG_STRANDED_HOURS) one alert line names the repo, the branch, the ahead count and
#     the time it was first seen. The alert repeats only when the count changes.
# `report <jg-home>` prints one line per closed branch with its ahead count and state, for a human to read.
# State lives in <home>/data/jg-merge-on-green/stranded-sweep/. The forge is asked at most once per
# JG_STRANDED_SWEEP_MIN minutes (default 60) per home, so the watcher check stays cheap and never slows the work
# that runs beside it. A forge failure is silent and retried next sweep. Nothing is printed when nothing happened.
# merge-on-green.sh runs this after the stale-PR alarm and hands over its remaining time in JG_STRANDED_LIMIT.
# JG_STRANDED_GH names the gh-axi binary (tests point it at a stub).
set -u
mode=${1:-}
case $mode in check|report) ;; *) mode= ;; esac
[ "$#" -eq 2 ] && [ -n "$mode" ] && [ -d "$2/state" ] || { echo "usage: stranded-merge-sweep.sh check|report <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
GH=${JG_STRANDED_GH:-gh-axi}
MEM=$FMH/data/jg-merge-on-green/stranded-sweep
umask 077
BUDGET=$(( ${JG_CHECK_TIMEOUT:-30} / 3 )); [ "$BUDGET" -ge 5 ] || BUDGET=5
START=$(date +%s)
LIMIT=${JG_STRANDED_LIMIT:-$(( START + ${JG_CHECK_TIMEOUT:-30} * 4 / 5 ))}
HOURS=${JG_STRANDED_HOURS:-48}; case $HOURS in ''|*[!0-9]*) HOURS=48 ;; esac
EVERY=${JG_STRANDED_SWEEP_MIN:-60}; case $EVERY in ''|*[!0-9]*) EVERY=60 ;; esac
api() { timeout "$BUDGET" "$GH" api "$1" --jq "$2" 2>/dev/null; } # <path> <jq> -> jq text, nonzero on failure

if [ "$mode" = check ] && [ -f "$MEM/.last" ]; then
  last=$(cat "$MEM/.last" 2>/dev/null) || last=0
  case $last in ''|*[!0-9]*) last=0 ;; esac
  [ "$(( START - last ))" -ge "$(( EVERY * 60 ))" ] || exit 0
fi
carried=$(awk '{ sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if (length($0)) print }' "$FMH/config/version-branch-carried" 2>/dev/null)

repos=$([ -f "$FMH/data/projects.md" ] || exit 0
while IFS= read -r line; do
  name=${line%% \[*}; name=${name%% - *}; name=${name#- }
  url=$(git -C "$FMH/projects/$name" remote get-url origin 2>/dev/null) || continue
  printf '%s\n' "$url" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)$#\2#p' | sed 's/\.git$//'
done < "$FMH/data/projects.md" 2>/dev/null | sort -u)

complete=1
for repo in $repos; do
  [ "$(date +%s)" -lt "$LIMIT" ] || { complete=0; break; }
  key=${repo//\//__}
  default=$(api "repos/$repo" .default_branch) && [ -n "$default" ] || { complete=0; continue; }
  names=$(api "repos/$repo/branches?per_page=100" '.[].name') || { complete=0; continue; }
  names=$(printf '%s\n' "$names" | grep -E '^release/c-[0-9]+$' || true)
  newest=$(printf '%s\n' "$names" | awk -F'c-' 'NF > 1 && $2 + 0 > best { best = $2 + 0 } END { if (best) print best }')
  [ -n "$newest" ] || continue
  for b in $names; do
    n=${b#release/c-}
    [ "$n" -lt "$newest" ] || continue
    ahead=$(api "repos/$repo/compare/$default...$b" .ahead_by) || { complete=0; continue; }
    case $ahead in ''|*[!0-9]*) complete=0; continue ;; esac
    f=$MEM/$key.${b//\//__}
    state=closed
    if [ "$ahead" -eq 0 ]; then
      rm -f -- "$f" 2>/dev/null
    elif printf '%s\n' "$carried" | grep -qxF -- "$b"; then
      state=carried
      rm -f -- "$f" 2>/dev/null
    else
      state=stranded
    fi
    [ "$mode" = report ] && printf '%s %s ahead %s of %s (%s)\n' "$repo" "$b" "$ahead" "$default" "$state"
    [ "$state" = stranded ] && [ "$mode" = check ] || continue
    first=; seen=
    if [ -f "$f" ]; then read -r first seen < "$f" 2>/dev/null || :; fi
    case $first in ''|*[!0-9]*) first=$START; seen= ;; esac
    if [ "$(( START - first ))" -ge "$(( HOURS * 3600 ))" ] && [ "$seen" != "$ahead" ]; then
      echo "stranded-merge-sweep: $repo: $b is ahead of $default by $ahead commits and has been for $HOURS h or more (first seen $(date -u -d "@$first" +%FT%TZ)); merged work on it never reached $default - carry it onto the live release, then list the branch in config/version-branch-carried"
      seen=$ahead
    fi
    mkdir -p "$MEM" 2>/dev/null && printf '%s %s\n' "$first" "$seen" > "$f" 2>/dev/null || :
  done
done
if [ "$mode" = check ] && [ "$complete" = 1 ]; then
  mkdir -p "$MEM" 2>/dev/null && printf '%s\n' "$START" > "$MEM/.last" 2>/dev/null || :
fi
exit 0
