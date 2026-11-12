#!/usr/bin/env bash
# jg-beat.sh - the one writer of a task's beat record: state/beats/<task-id>.
#
# Usage: jg-beat.sh append <state-dir> <task-id> <event> [error-type]
#
# One line per beat: `<epoch> <event>` plus ` error=<type>` when the turn ended on an API error.
# The events are the Claude Code hook names (UserPromptSubmit, PostToolBatch, Stop, StopFailure,
# SessionEnd); a runtime with no such hook gets its beat from the same writer (slice H3b).
# The record is a time series for the stall check to read; it calls no model and takes milliseconds.
# It keeps the last 200 lines once it passes 400, so a long task cannot grow it without end.
# Exit codes: 0 written; 1 refused (bad input, unwritable record); 2 usage.
set -u

[ "${1-}" = append ] && [ $# -ge 4 ] && [ $# -le 5 ] || { sed -n '2,12p' "$0" >&2; exit 2; }
state=$2 id=$3 event=$4 err=${5-}
case $id in ''|*/*|.*) echo "jg-beat: bad task id" >&2; exit 1 ;; esac
case $event in ''|*[!A-Za-z0-9_-]*) echo "jg-beat: bad event" >&2; exit 1 ;; esac
case $err in *[!A-Za-z0-9_.-]*) err=unknown ;; esac
[ -d "$state" ] || { echo "jg-beat: no state dir $state" >&2; exit 1; }

dir=$state/beats
mkdir -p "$dir" || exit 1
rec=$dir/$id
printf '%s %s%s\n' "$(date +%s)" "$event" "${err:+ error=$err}" >>"$rec" || exit 1
if [ "$(wc -l <"$rec")" -gt 400 ]; then
  tail -n 200 "$rec" >"$rec.tmp.$$" && mv -f "$rec.tmp.$$" "$rec"
fi
exit 0
