#!/usr/bin/env bash
# trunk-latency watcher check: one row per local-trunk landing with the minutes from the lane's done line to its landing
# row and the stage that held most of them, and one alert for a landing over the five-minute target.
# Usage: latency.sh check <jg-home>
#
# It reads only records that the landing check and the lane already write:
#   data/trunk-landings.tsv         one row per landing: task, project, commit, landed epoch, gate, [batch-from=<commit>]
#   data/trunk-landing-proofs.tsv   the lane head (receipt=<verdict>@<head>), the gate seconds (gate=ran:N,failed:F,secs:S) and the
#                                   lane's done epoch (done=<epoch>), which the landing records while the status file exists
#   data/jg-trunk-landing/          the landing start: <task>.<head>.launch-*.log for a lane landed alone, batch.launch-*.log
#                                   for a stack (the landing check starts one landing at a time, so the last start before the
#                                   landing row is the one that landed it)
#   state/chat.jsonl, state/<task>.status   the lane's `done [at=<epoch>]` lines; a landed lane's status file is removed at
#                                   cleanup, so the message log is the record that stays
#   data/jg-trunk-landing/<task>.<head>.queue-why   why the lane waited, written by the lander at the landing start (core/trunk-landing/queue-why.sh)
#   data/<task>/.done-done/runs/*.json      the start of the worker's first sealed test run at the head: the first record of
#                                   a test run bound to that head (the light gate before it writes no record)
#   /proc/loadavg                   the one-minute host load, written only for a landing at most 10 minutes old
# It writes data/trunk-latency.tsv, one row per landing row (task and commit), with the fields
#   task head commit first_done ready gate_start launch landed minutes stage gate_secs load queue_why
# ready is the last done line at or before the landing row and first_done the first, as table T of the plan's measure.py
# reads them; minutes is (landed - ready) / 60, rounded the same way. The stage is the one of queue (the done line to the
# landing start), landing (the start to the gate: start lock, rebase, admission) and gate (the lint and the changed tests)
# that held the most seconds, or before-gate when the start is not on record. A landing with no done line on record gets a
# row with empty ready, minutes and stage: it is counted, not dropped. A queue stage always names its reason in queue_why: behind
# <lane>, behind attempt of <lane>, first seen +N s, or `not recorded` for a landing the lander wrote no reason for.
# Alert: a landing over JG_MERGE_LATENCY_LIMIT_MINUTES (default 5, the limit core/merge-on-green reads too) raises the slow-delivery
# alert through bin/jg-alert.sh, one key per landing. A landing more than an hour old when its row is written (the first run in a home,
# or a check that was off) is recorded with no alert, and the run prints one line, which becomes a check wake, that counts those over the limit.
set -u
[ "$#" -eq 2 ] && [ "$1" = check ] && [ -d "$2/state" ] || { echo "usage: latency.sh check <jg-home>" >&2; exit 2; }
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state DATA=$FMH/data
MEM=$DATA/jg-trunk-landing OUT=$DATA/trunk-latency.tsv LANDINGS=$DATA/trunk-landings.tsv
[ -s "$LANDINGS" ] || exit 0
LIMIT=${JG_MERGE_LATENCY_LIMIT_MINUTES:-5}
case $LIMIT in ''|*[!0-9]*) LIMIT=5 ;; esac
NOW=${JG_TRUNK_LATENCY_NOW:-$(date +%s)}  # the clock; a test sets it to replay a dated landing
ALERT=${JG_TRUNK_LATENCY_ALERT:-$FMH/bin/jg-alert.sh}  # the home's own alert function, like core/merge-on-green reads its bin/jg-pr-merge.sh
LOADAVG=${JG_TRUNK_LATENCY_LOADAVG:-/proc/loadavg}
umask 077
exec 9> "$STATE/.trunk-latency.lock" && flock -n 9 || exit 0  # one run per home writes the rows

# The landing rows that have no latency row yet. The header line keeps the file non-empty, so awk reads it first.
H1='task\thead\tcommit\tfirst_done\tready\tgate_start\tlaunch\tlanded\tminutes\tstage\tgate_secs\tload\tqueue_why'
[ -s "$OUT" ] || printf '%b\n' "$H1" > "$OUT"
[ "$(head -n 1 "$OUT")" != "${H1%$'\t'queue_why}" ] || sed -i "1s/\$/\tqueue_why/" "$OUT"  # a file from before the column keeps its rows
pending=$(awk -F'\t' 'FNR == NR { seen[$1 "\t" $3] = 1; next } NF >= 4 && !(($1 "\t" $3) in seen)' "$OUT" "$LANDINGS")
[ -n "$pending" ] || exit 0

# Every done line on record, as `<task> <epoch>`: the [at=] stamp of the line, else the time the message log took it.
dones=$( { grep -F '"kind":"status"' "$STATE/chat.jsonl" 2>/dev/null \
             | jq -Rr 'fromjson? | select(.kind == "status") | [(.from | tostring), (.at | tostring), (.text | tostring)] | @tsv'
           cut -f1 <<< "$pending" | sort -u | while IFS= read -r t; do
             [ -f "$STATE/$t.status" ] && sed "s/^/$t\t\t/" "$STATE/$t.status"
           done; } \
         | awk -F'\t' '$3 ~ /^done[: ]/ { at = $2; if (match($3, /\[at=[0-9]+\]/)) at = substr($3, RSTART + 4, RLENGTH - 5)
                                         if (at ~ /^[0-9]+$/) print $1, at }')

# launch_at <glob> <from> <to>: the latest start record matching the glob, from <from> to <to>.
launch_at() {
  local f
  for f in $1; do [ -f "$f" ] && stat -c %Y "$f"; done | awk -v a="$2" -v b="$3" '$1 >= a && $1 <= b && $1 > m { m = $1 } END { if (m) print m }'
}

old=0 old_over=0
while IFS=$'\t' read -r task _ commit landed _ extra; do
  proof=$(awk -F'\t' -v t="$task" -v c="$commit" '$1 == t && $3 == c { p = $0 } END { print p }' "$DATA/trunk-landing-proofs.tsv" 2>/dev/null)
  head=$(sed -n 's/.*receipt=[A-Z]*@\([0-9a-f]*\).*/\1/p' <<< "$proof")
  gate=$(sed -n 's/.*gate=ran:[0-9]*,failed:[0-9]*,secs:\([0-9]*\).*/\1/p' <<< "$proof")
  [ -z "$head" ] || for f in "$MEM/$task.$head"*.state; do  # the receipt names a short head; the landing records name it in full
    f=${f#"$MEM/$task."}; [[ ${f%.state} =~ ^[0-9a-f]{40,64}$ ]] && { head=${f%.state}; break; }
  done
  # The done lines of this landing: after the task's previous landing row, at or before this one.
  prev=$(awk -F'\t' -v t="$task" -v l="$landed" '$1 == t && $4 < l && $4 > p { p = $4 } END { print p + 0 }' "$LANDINGS")
  read -r first ready < <(awk -v t="$task" -v p="$prev" -v l="$landed" '$1 == t && $2 > p && $2 <= l { if (!f || $2 < f) f = $2; if ($2 > r) r = $2 }
                                                                      END { print (f ? f " " r : "") }' <<< "$dones")
  # The done epoch the landing recorded (done=<epoch> on its proofs row, written while the status file existed) is read first.
  rec=$(sed -n 's/.*\tdone=\([0-9][0-9]*\)\(\t.*\)\{0,1\}$/\1/p' <<< "$proof")
  [ -z "$rec" ] || { ready=$rec; [ -n "${first:-}" ] && [ "$first" -le "$rec" ] || first=$rec; }
  start=
  if [ -n "${ready:-}" ]; then
    case $extra in batch-from=*) glob="$MEM/batch.launch-*.log" ;; *) glob="$MEM/$task.${head:-*}.launch-*.log" ;; esac
    start=$(launch_at "$glob" "$ready" "$landed")
  fi
  gstart=
  [ -z "$head" ] || gstart=$(for f in "$DATA/$task/.done-done/runs/"*.json; do
      [ -f "$f" ] && jq -r --arg h "$head" 'select((.commit // "") | startswith($h)) | .started_at // empty' "$f" 2>/dev/null
    done | while IFS= read -r iso; do date -u -d "$iso" +%s 2>/dev/null; done | sort -n | head -n 1)
  load=
  [ $((NOW - landed)) -gt 600 ] || load=$(awk '{ print $1; exit }' "$LOADAVG" 2>/dev/null)
  # minutes, stage, the stage's seconds: the share each stage held of the done line to the landing row.
  read -r minutes stage _ < <(awk -v r="${ready:-}" -v s="$start" -v l="$landed" -v g="${gate:-0}" 'BEGIN {
    if (r == "") { print ""; exit }
    t = l - r; if (t < 0) t = 0; if (g > t) g = t
    if (s == "") { n["before-gate"] = t - g; o = "before-gate gate" }
    else { n["queue"] = s - r; n["landing"] = l - s - g; o = "queue landing gate" }
    n["gate"] = g; k = split(o, names, " "); best = names[1]
    for (i = 1; i <= k; i++) { if (n[names[i]] < 0) n[names[i]] = 0; if (n[names[i]] > n[best]) best = names[i] }
    printf "%.0f %s %.0f\n", t / 60, best, n[best] / 60 }')
  why=$(cat "$MEM/$task.$head.queue-why" 2>/dev/null | head -n 1)
  [ -n "$why" ] || [ "${stage:-}" != queue ] || why='not recorded'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$task" "$head" "$commit" "${first:-}" "${ready:-}" "$gstart" \
    "$start" "$landed" "${minutes:-}" "${stage:-}" "$gate" "$load" "$why" >> "$OUT"
  if [ $((NOW - landed)) -gt 3600 ]; then
    old=$((old + 1)); [ "${minutes:-0}" -le "$LIMIT" ] || old_over=$((old_over + 1)); continue
  fi
  [ "${minutes:-0}" -gt "$LIMIT" ] || continue
  # The alert is the alert table's slow-delivery row (bin/jg-alert.sh); the row in $OUT names the stage and its minutes. A landing that
  # waited behind a landing that was running is the row's quiet fact. A refused raise is one warning line, never a lost row.
  facts=(); [ "${stage:-}" != queue ] || case $why in 'behind attempt'*) ;; behind\ *) facts=(--fact queued-behind-running-landing) ;; esac
  JG_HOME=$FMH JG_STATE_OVERRIDE=$STATE bash "$ALERT" raise slow-delivery "$task-${commit:0:12}" --mode local-trunk --kind ship-delivering \
    "${facts[@]}" --ticket "$task" --deliver >/dev/null || echo "trunk-latency: could not raise the slow-delivery alert for $task ($minutes minutes, ${stage:-}); recorded in $OUT"
done <<< "$pending"
[ "$old" -eq 0 ] || printf 'trunk-latency: recorded %s earlier landings with no alert, %s of them over the %s-minute target; %s\n' \
  "$old" "$old_over" "$LIMIT" "$OUT"
exit 0
