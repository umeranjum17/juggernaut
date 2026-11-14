#!/usr/bin/env bash
# trunk-ci ci-result watcher check: the CI result of a trunk commit reaches the trunk by itself, within one tick of the end of its
# run, with no hand step and no model turn.
# Usage: ci-result.sh check <jg-home>
#
# For each project with a trunk (<home>/state/trunk-branch-<project>) whose clone has a github.com origin, it lists the runs of that
# trunk branch on the forge and groups them by commit. A commit counts once all its runs have ended: red when any run ended
# failure, timed_out or startup_failure, green when every run ended success, skipped or neutral (a cancelled run is no result and is
# waited on). Only a commit that is on the local trunk counts. Each new result is one row in data/trunk-ci-observed.tsv, written
# under state/.trunk-ci-result.lock:
#   project, commit, epoch the newest run ended, green|red, the deciding run id (the first failed run of a red, the newest run of a green), watch|act, acted|held|failed
# A commit that has a row is never read again, so a later tick prints and writes nothing.
#
# Two modes. WATCH is the default and only records. ACT also calls `bin/jg-trunk.sh ci <project-dir> <commit> green|red`, which owns
# the green pin, the move of every home and the red alert; this script changes none of that. A project acts only when
# <home>/config/trunk-ci-result says `act` AND at most JG_TRUNK_CI_RED_MAX (default 2) of its last JG_TRUNK_CI_WINDOW (default 20)
# observed results, this one included, are red: a trunk that is red this often is not moved back by a script. A result held back for
# that reason is recorded as `held`. A commit that already has a row for the same result in data/trunk-ci.tsv is recorded and not
# sent again. A forge that does not answer is silent; the next tick asks again. Each red prints one line (a check wake).
# JG_TRUNK_CI_GH names the gh-axi binary (a test names a forge stand-in).
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: ci-result.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state DATA=$FMH/data
GH=${JG_TRUNK_CI_GH:-gh-axi}
BUDGET=$(( ${JG_CHECK_TIMEOUT:-30} / 3 )); [ "$BUDGET" -ge 5 ] || BUDGET=5
LIMIT=$(( $(date +%s) + ${JG_CHECK_TIMEOUT:-30} * 4 / 5 ))
RED_MAX=${JG_TRUNK_CI_RED_MAX:-2} WINDOW=${JG_TRUNK_CI_WINDOW:-20}
OUT=$DATA/trunk-ci-observed.tsv
umask 077
mkdir -p "$DATA" 2>/dev/null
exec 9> "$STATE/.trunk-ci-result.lock" && flock -n 9 || exit 0  # one run per home writes the rows

# One line per commit whose runs have all ended: sha, newest end epoch, newest run id, green|red. Commits with a run still going, a
# cancelled run and no red, or no run at all give no line.
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
RESULTS='.workflow_runs | group_by(.head_sha)[]
  | select(all(.[]; .status == "completed"))
  | (map(.conclusion) | unique) as $c
  | (if any($c[]; . == "failure" or . == "timed_out" or . == "startup_failure") then "red"
     elif all($c[]; . == "success" or . == "skipped" or . == "neutral") then "green" else empty end) as $r
  | [.[0].head_sha, (max_by(.updated_at) | .updated_at | fromdateiso8601),
     (if $r == "red" then (map(select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure")) | min_by(.id) | .id)
      else (max_by([.updated_at, .id]) | .id) end), $r] | @tsv'

mode_act() { [ "$(tr -d '[:space:]' < "$FMH/config/trunk-ci-result" 2>/dev/null)" = act ]; }
# red results among the last WINDOW rows of the project
red_in_window() {  # <project>
  awk -F'\t' -v p="$1" '$1 == p { print $4 }' "$OUT" 2>/dev/null | tail -n "$WINDOW" | grep -c '^red$' || true
}

while IFS=$'\t' read -r p repo; do
  [ -n "$p" ] || continue
  [ "$(date +%s)" -lt "$LIMIT" ] || break
  dir=$FMH/projects/$p
  trunk=$(cat "$STATE/trunk-branch-$p" 2>/dev/null) || continue
  tip=$(git -C "$dir" rev-parse --verify -q "refs/heads/$trunk") || continue
  runs=$(timeout "$BUDGET" "$GH" api "repos/$repo/actions/runs?branch=$trunk&per_page=100" --jq "$RESULTS" 2>/dev/null) || continue  # the forge did not answer
  while IFS=$'\t' read -r sha at id result; do
    [ -n "$sha" ] || continue
    grep -q "^$p	$sha	" "$OUT" 2>/dev/null && continue
    { git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null && git -C "$dir" merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; } || continue
    how=watch acted=-
    if mode_act; then
      how=act
      # this result counts in its own window
      reds=$(( $(red_in_window "$p") + $([ "$result" = red ] && echo 1 || echo 0) ))
      if [ "$reds" -gt "$RED_MAX" ]; then acted=held
      elif grep -Eq "^$p	$sha	[0-9]+	$result(	|\$)" "$DATA/trunk-ci.tsv" 2>/dev/null; then acted=acted
      elif JG_HOME=$FMH timeout "$BUDGET" "$FMH/bin/jg-trunk.sh" ci "$dir" "$sha" "$result" >/dev/null 2>&1; then acted=acted
      else acted=failed; fi
    fi
    # a failed act is retried by the next tick: no row until it is sent or held
    [ "$acted" != failed ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$sha" "$at" "$result" "$id" "$how" "$acted" >> "$OUT"
    [ "$result" != red ] || echo "trunk-ci: $p CI is red at ${sha:0:12} (run $id, $how${acted:+: $acted})"
  done <<< "$runs"
done < <(sed -n 's/^- \(.*\)$/\1/p' "$DATA/projects.md" 2>/dev/null | while IFS= read -r line; do
  name=${line%% \[*}; name=${name%% - *}
  url=$(git -C "$FMH/projects/$name" remote get-url origin 2>/dev/null) || continue
  repo=$(printf '%s\n' "$url" | sed -n 's#^\(https://github\.com/\|git@github\.com:\|ssh://git@github\.com/\)\([A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*\)$#\2#p' | sed 's/\.git$//')
  [ -z "$repo" ] || printf '%s\t%s\n' "$name" "$repo"
done | sort -u)
exit 0
