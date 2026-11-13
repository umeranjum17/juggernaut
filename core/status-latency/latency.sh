#!/usr/bin/env bash
# status-latency: a status line reaches the owner of its lane within a minute, and an alarm says so when it does not.
# The owner is the home that holds the lane: the lead's home for a lead's lane, Main's home otherwise. A lane's status line is
# "done|failed|blocked|needs-decision [at=<epoch>]: ..."; the watcher of that home turns it into a wake, and bin/jg-wake-lib.sh
# writes one row to data/wake-ledger.tsv when it does. The delay is the epoch of that row minus the [at=] stamp of the line.
#
#   latency.sh check <jg-home>   the registered watcher check. For the newest transition line of each live lane it writes one row
#                                to data/status-latency.tsv (task, line epoch, word, wake epoch, seconds) and raises the alert when
#                                the wake took longer than the limit, or has not come and the limit has passed.
#
# The limit is JG_STATUS_LATENCY_LIMIT_SECONDS (default 120). A transition over the limit raises `undelivered` through bin/jg-alert.sh at
# rung 3 (Main), because the owner's own watcher is what failed to wake it; the key is one per transition, so it rings once.
# The watcher runs this check, so a watcher that is fully stopped is the supervision-down alert's case, not this one; a slow or late watcher
# shows here as a line whose wake row is late or missing. It reads records only. A line older than an hour when first seen is skipped.
# JG_STATUS_LATENCY_NOW is the clock and JG_STATUS_LATENCY_ALERT the alert command; a test sets them.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: latency.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state DATA=$FMH/data
OUT=$DATA/status-latency.tsv LEDGER=$DATA/wake-ledger.tsv
LIMIT=${JG_STATUS_LATENCY_LIMIT_SECONDS:-120}
case $LIMIT in ''|*[!0-9]*) LIMIT=120 ;; esac
NOW=${JG_STATUS_LATENCY_NOW:-$(date +%s)}
ALERT=${JG_STATUS_LATENCY_ALERT:-$FMH/bin/jg-alert.sh}
umask 077
mkdir -p "$DATA"
exec 9> "$STATE/.status-latency.lock" && flock -n 9 || exit 0  # one run per home writes the rows
[ -s "$OUT" ] || printf 'task\tline_at\tword\twoke_at\tseconds\n' > "$OUT"

for f in "$STATE"/*.status; do
  [ -f "$f" ] && [ -f "${f%.status}.meta" ] || continue  # live lanes only; a torn-down lane keeps its old status file
  task=$(basename "$f" .status)
  line=$(awk 'NF { l = $0 } END { print l }' "$f")
  word=${line%%[ :[]*}
  case $word in done|failed|blocked|needs-decision) ;; *) continue ;; esac
  at=$(printf '%s' "$line" | sed -n 's/^[^[]*\[at=\([0-9]\{9,\}\)\].*/\1/p')
  [ -n "$at" ] || continue
  awk -F'\t' -v t="$task" -v a="$at" '$1 == t && $2 == a { f = 1 } END { exit !f }' "$OUT" && continue
  [ $((NOW - at)) -le 3600 ] || continue
  # The first wake the watcher raised for this lane's status file at or after the line.
  woke=$(cat "$LEDGER.1" "$LEDGER" 2>/dev/null | awk -F'\t' -v k="$task.status" -v a="$at" '$3 == "signal" && $4 == k && $1 >= a { print $1; exit }')
  if [ -n "$woke" ]; then
    secs=$((woke - at))
  else
    [ $((NOW - at)) -gt "$LIMIT" ] || continue  # no wake yet and the limit has not passed: look again on the next tick
    secs=
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$task" "$at" "$word" "$woke" "$secs" >> "$OUT"
  [ -z "$secs" ] || [ "$secs" -gt "$LIMIT" ] || continue
  note="The $word line of $task, written $(((NOW - at) / 60)) minutes ago, ${woke:+woke its owner only after $secs seconds}${woke:-has not woken its owner}. The limit is $LIMIT seconds."
  JG_HOME=$FMH JG_STATE_OVERRIDE=$STATE bash "$ALERT" raise undelivered "status-$task-$at" --rung 3 --ticket "$task" --note "$note" --deliver >/dev/null \
    || echo "status-latency: could not raise the alert for $task ($word at $at); recorded in $OUT"
done
exit 0
