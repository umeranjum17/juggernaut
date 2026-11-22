#!/usr/bin/env bash
# trunk-release ci-watch watcher check: a red release pull request is recorded and filed for a fix within one tick. No model turn.
# Usage: ci-watch.sh check <jg-home>
#
# For each project with a release row in <home>/data/trunk-releases.tsv, the last row names the release pull request and the
# trunk commit it carries. bin/jg-pr-state.sh reads that pull request's required checks. A check in a failed state (a state
# that is not one of the waiting ones) on a pull request that is still open is a red release, and the watch does two things,
# once for each head:
#   1. records the red through `bin/jg-trunk.sh ci <project-dir> <head> red <url> <failed check>`, which owns the green pin;
#   2. through the same command, files one fix ticket for that head and submits it to auto-dispatch.
# A head with an approved repair is not touched again. An incomplete submission is retried on the next tick.
# A forge that does not answer, a merged or closed pull request and a pull request with no failed check are silent.
#
# It also writes data/trunk-release-age.tsv for the board's Landed -> Released view, one row per project with a release row:
#   project, landed-not-released count, oldest landed-not-released epoch (empty when none), age in seconds at this run
# A landing counts when its commit (data/trunk-landings.tsv) is not yet in the released mark (state/trunk-released-<project>).
# JG_CI_WATCH_NOW sets the clock for a test.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: ci-watch.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state DATA=$FMH/data
NOW=${JG_CI_WATCH_NOW:-$(date +%s)}
BUDGET=${JG_CHECK_TIMEOUT:-30}
umask 077
exec 9> "$STATE/.trunk-release-ci-watch.lock" && flock -n 9 || exit 0  # one run per home

# The first failed check of a pull request: `<name> (<state>)`, empty when none failed. The waiting states are not a red.
failed_check() {  # <state output>
  sed -n 's/^\(REQUIRED \)\{0,1\}CHECK: //p' <<<"$1" \
    | grep -Eiv '\((pending|in_progress|queued|waiting|requested|expected)\)$' | head -n 1
}

# The board numbers for one project: the landings that are not yet in the released mark.
write_age() {  # <project> <proj-dir>
  local p=$1 dir=$2 mark n=0 oldest='' c at
  mark=$(cat "$STATE/trunk-released-$p" 2>/dev/null || true)
  while IFS=$'\t' read -r c at; do
    [ -n "$c" ] || continue
    if [ -z "$mark" ] || ! git -C "$dir" merge-base --is-ancestor "$c" "$mark" 2>/dev/null; then
      n=$((n + 1)); { [ -n "$oldest" ] && [ "$oldest" -le "$at" ]; } || oldest=$at
    fi
  done < <(awk -F'\t' -v p="$p" '$2 == p && $4 ~ /^[0-9]+$/ { print $3 "\t" $4 }' "$DATA/trunk-landings.tsv" 2>/dev/null)
  local out=$DATA/trunk-release-age.tsv
  { grep -v "^$p	" "$out" 2>/dev/null || true; printf '%s\t%s\t%s\t%s\n' "$p" "$n" "$oldest" "${oldest:+$((NOW - oldest))}"; } > "$out.tmp.$$" \
    && mv -f "$out.tmp.$$" "$out"
}

[ -s "$DATA/trunk-releases.tsv" ] || exit 0
while IFS= read -r p; do
  dir=$FMH/projects/$p
  [ -d "$dir" ] || continue
  write_age "$p" "$dir"
  read -r head url < <(awk -F'\t' -v p="$p" 'NF >= 6 && $1 == p { c = $3; u = $6 } END { print c, u }' "$DATA/trunk-releases.tsv")
  url=$(grep -Eo 'https?://[^"[:space:],]+/pull/[0-9]+' <<<"$url" | head -n 1)
  [ -n "$head" ] && [ -n "$url" ] || continue
  item=ci-red-release-$p-${head:0:12}
  [ ! -f "$STATE/dispatch-approved/$item" ] && [ ! -f "$STATE/dispatch-approved/ci-red-$p-${head:0:12}" ] || continue
  out=$(JG_HOME=$FMH timeout --kill-after=5 "$BUDGET" "$FMH/bin/jg-pr-state.sh" "$url" 2>/dev/null) || continue  # the forge did not answer: the next tick asks again
  grep -q '^STATE: ' <<<"$out" && continue  # merged or closed: not a release in flight
  bad=$(failed_check "$out"); [ -n "$bad" ] || continue
  JG_HOME=$FMH JG_STATE_OVERRIDE=$STATE JG_DATA_OVERRIDE=$DATA JG_CONFIG_OVERRIDE=$FMH/config \
    timeout "$BUDGET" "$FMH/bin/jg-trunk.sh" ci "$dir" "$head" red "$url" "$bad" 9>&- >&2 || continue
  echo "trunk-release: $url is red ($bad); repair submitted to dispatch"
done < <(awk -F'\t' 'NF >= 6 { print $1 }' "$DATA/trunk-releases.tsv" | sort -u)
exit 0
