#!/usr/bin/env bash
# trunk-latency: the minutes from a lane's done line to its landing, the stage that held them, and one alert for a landing over the
# five-minute target. The times live on the ticket in Beads; this script writes no file of its own.
# Usage: latency.sh measure <jg-home> <task> <commit>   print the landing's timing as one JSON object (the payload of the lander's `land`
#                                   event): stage, queue_s, landing_s, gate_s, load, queue_why, ready (epoch). Writes nothing.
#        latency.sh check <jg-home>   the watcher check: for each landing of the last hour that the check has not read yet, read the
#                                   ticket's ready time and the landing's `land` event (jg-backlog.sh trace landing), and raise the
#                                   slow-delivery alert through bin/jg-alert.sh for one over the limit, naming the stage from the payload
#
# measure reads only records that the landing check and the lane already write:
#   data/trunk-landings.tsv         one row per landing: task, project, commit, landed epoch, gate, [batch-from=<commit>]
#   data/trunk-landing-proofs.tsv   the lane head (receipt=<verdict>@<head>), the gate seconds (gate=ran:N,failed:F,secs:S) and the
#                                   lane's done epoch (done=<epoch>), which the landing records while the status file exists
#   data/jg-trunk-landing/          the landing start: <task>.<head>.launch-*.log for a lane landed alone, batch.launch-*.log
#                                   for a stack (the landing check starts one landing at a time, so the last start before the
#                                   landing row is the one that landed it); <task>.<head>.queue-why, the reason the lane waited
#   state/chat.jsonl, state/<task>.status   the lane's `done [at=<epoch>]` lines, read when the proofs row holds no done epoch
#   /proc/loadavg                   the one-minute host load, kept only for a landing at most 10 minutes old
# The stage is the one of queue (the done line to the landing start), landing (the start to the gate: start lock, rebase, admission) and
# gate (the lint and the changed tests) that held the most seconds, or before-gate when the start is not on record; queue_s, landing_s and
# gate_s add up to the seconds from ready to landed. A queue stage always names its reason in queue_why: behind <lane>, behind attempt of
# <lane>, first seen +N s, slot full, or `not recorded`.
# Alert: a landing over JG_MERGE_LATENCY_LIMIT_MINUTES (default 5, the limit core/merge-on-green reads too) raises the slow-delivery alert
# through bin/jg-alert.sh, one key per landing. The minutes are the ticket's ready time to the event's time. A landing more than an hour
# old is not read: the check ran late or was off.
set -u
[ "$#" -ge 2 ] && [ -d "$2/state" ] || { echo "usage: latency.sh check <jg-home> | measure <jg-home> <task> <commit>" >&2; exit 2; }
verb=$1
FMH=$(cd "$2" && pwd -P)
STATE=$FMH/state DATA=$FMH/data
MEM=$DATA/jg-trunk-landing LANDINGS=$DATA/trunk-landings.tsv
NOW=${JG_TRUNK_LATENCY_NOW:-$(date +%s)}  # the clock; a test sets it to replay a dated landing

# measure <task> <commit>: the payload of the landing, as one JSON object on stdout.
measure() {
  local task=$1 commit=$2 landed extra proof head gate prev ready start glob load minutes stage qsecs lsecs why dones f
  read -r landed extra < <(awk -F'\t' -v t="$task" -v c="$commit" '$1 == t && $3 == c { l = $4; e = $6 } END { print l, e }' "$LANDINGS" 2>/dev/null)
  [ -n "${landed:-}" ] || { echo "latency: no landing row of $task at $commit" >&2; return 1; }
  proof=$(awk -F'\t' -v t="$task" -v c="$commit" '$1 == t && $3 == c { p = $0 } END { print p }' "$DATA/trunk-landing-proofs.tsv" 2>/dev/null)
  head=$(sed -n 's/.*receipt=[A-Z]*@\([0-9a-f]*\).*/\1/p' <<< "$proof")
  gate=$(sed -n 's/.*gate=ran:[0-9]*,failed:[0-9]*,secs:\([0-9]*\).*/\1/p' <<< "$proof")
  [ -z "$head" ] || for f in "$MEM/$task.$head"*.state; do  # the receipt names a short head; the landing records name it in full
    f=${f#"$MEM/$task."}; [[ ${f%.state} =~ ^[0-9a-f]{40,64}$ ]] && { head=${f%.state}; break; }
  done
  # The done epoch the landing recorded (done=<epoch> on its proofs row, written while the status file existed), else the lane's last
  # done line, after the task's previous landing and at or before this one, from the message log and the status file.
  ready=$(sed -n 's/.*\tdone=\([0-9][0-9]*\)\(\t.*\)\{0,1\}$/\1/p' <<< "$proof")
  if [ -z "$ready" ]; then
    prev=$(awk -F'\t' -v t="$task" -v l="$landed" '$1 == t && $4 < l && $4 > p { p = $4 } END { print p + 0 }' "$LANDINGS")
    dones=$( { grep -F '"kind":"status"' "$STATE/chat.jsonl" 2>/dev/null \
                 | jq -Rr 'fromjson? | select(.kind == "status" and (.from | tostring) == $t) | [(.at | tostring), (.text | tostring)] | @tsv' --arg t "$task"
               [ -f "$STATE/$task.status" ] && sed "s/^/\t/" "$STATE/$task.status"; } \
             | awk -F'\t' '$2 ~ /^done[: ]/ { at = $1; if (match($2, /\[at=[0-9]+\]/)) at = substr($2, RSTART + 4, RLENGTH - 5); if (at ~ /^[0-9]+$/) print at }')
    ready=$(awk -v p="$prev" -v l="$landed" '$1 > p && $1 <= l && $1 > r { r = $1 } END { print r }' <<< "$dones")
  fi
  start=
  if [ -n "$ready" ]; then
    case ${extra:-} in batch-from=*) glob="$MEM/batch.launch-*.log" ;; *) glob="$MEM/$task.${head:-*}.launch-*.log" ;; esac
    start=$(for f in $glob; do [ -f "$f" ] && stat -c %Y "$f"; done | awk -v a="$ready" -v b="$landed" '$1 >= a && $1 <= b && $1 > m { m = $1 } END { if (m) print m }')
  fi
  load=
  [ $((NOW - landed)) -gt 600 ] || load=$(awk '{ print $1; exit }' "${JG_TRUNK_LATENCY_LOADAVG:-/proc/loadavg}" 2>/dev/null)
  # The stage and the seconds of each step (- when the landing start is not on record).
  read -r minutes stage qsecs lsecs < <(awk -v r="$ready" -v s="$start" -v l="$landed" -v g="${gate:-0}" 'BEGIN {
    if (r == "") { print "- - - -"; exit }
    t = l - r; if (t < 0) t = 0; if (g > t) g = t
    if (s == "") { n["before-gate"] = t - g; o = "before-gate gate" }
    else { n["queue"] = s - r; n["landing"] = l - s - g; o = "queue landing gate" }
    n["gate"] = g; k = split(o, names, " "); best = names[1]
    for (i = 1; i <= k; i++) { if (n[names[i]] < 0) n[names[i]] = 0; if (n[names[i]] > n[best]) best = names[i] }
    printf "%.0f %s %s %s\n", t / 60, best, (s == "" ? "-" : n["queue"]), (s == "" ? "-" : n["landing"]) }')
  why=$(head -n 1 "$MEM/$task.$head.queue-why" 2>/dev/null)
  [ -n "$why" ] || [ "$stage" != queue ] || why='not recorded'
  jq -nc --arg stage "$stage" --arg q "$qsecs" --arg l "$lsecs" --arg g "${gate:-}" --arg load "$load" --arg why "$why" --arg ready "$ready" '
    def n: if . == "" or . == "-" then null else tonumber end;
    {stage: (if $stage == "-" then null else $stage end), queue_s: ($q | n), landing_s: ($l | n), gate_s: ($g | n), load: ($load | n), queue_why: (if $why == "" then null else $why end), ready: ($ready | n)}'
}

# check: read what the lander wrote on the ticket and raise the alert for a landing over the limit.
check() {
  local LIMIT=${JG_MERGE_LATENCY_LIMIT_MINUTES:-5} task commit landed read_ready read_landed payload minutes stage secs why facts note
  local ALERT=${JG_TRUNK_LATENCY_ALERT:-$FMH/bin/jg-alert.sh}  # the home's own alert function, like core/merge-on-green reads its bin/jg-pr-merge.sh
  local BACKLOG=${JG_TRUNK_LATENCY_BACKLOG:-$FMH/bin/jg-backlog.sh} SEEN=$STATE/.trunk-latency.seen
  case $LIMIT in ''|*[!0-9]*) LIMIT=5 ;; esac
  [ -s "$LANDINGS" ] || return 0
  umask 077
  exec 9> "$STATE/.trunk-latency.lock" && flock -n 9 || return 0  # one run per home reads the landings
  while IFS=$'\t' read -r task _ commit landed _; do
    [ $((NOW - landed)) -le 3600 ] || continue
    grep -qxF "$task $commit" "$SEEN" 2>/dev/null && continue
    IFS=$'\t' read -r read_ready read_landed payload < <(JG_HOME=$FMH JG_DATA_OVERRIDE=$DATA bash "$BACKLOG" trace landing "$task" "$commit" 2>/dev/null)
    [ -n "${read_landed:-}" ] || continue  # the ticket has no event of this landing yet: read it again on the next run
    printf '%s %s\n' "$task" "$commit" >> "$SEEN"
    [ -n "${read_ready:-}" ] && [ "$read_ready" != - ] || read_ready=$(jq -r '.ready // empty | todate' <<< "${payload:-null}" 2>/dev/null)
    [ -n "$read_ready" ] || continue  # no ready time on record: counted nowhere, as before
    minutes=$(( ($(date -u -d "$read_landed" +%s) - $(date -u -d "$read_ready" +%s) + 30) / 60 ))
    [ "$minutes" -gt "$LIMIT" ] || continue
    stage=$(jq -r '.stage // "before-gate"' <<< "${payload:-null}" 2>/dev/null)
    why=$(jq -r '.queue_why // empty' <<< "${payload:-null}" 2>/dev/null)
    case $stage in queue) secs=queue_s ;; landing) secs=landing_s ;; gate) secs=gate_s ;; *) secs= ;; esac
    note="landing took $minutes minutes; the $stage held $(jq -r --arg k "$secs" 'if $k == "" or .[$k] == null then "most" else "\(.[$k] / 60 | round)" end' <<< "${payload:-null}") minutes${why:+ ($why)}"
    # A landing that waited behind a landing that was running is the row's quiet fact. A refused raise is one warning line.
    facts=(); [ "$stage" != queue ] || case $why in 'behind attempt'*) ;; behind\ *) facts=(--fact queued-behind-running-landing) ;; esac
    JG_HOME=$FMH JG_STATE_OVERRIDE=$STATE bash "$ALERT" raise slow-delivery "$task-${commit:0:12}" --mode local-trunk --kind ship-delivering \
      "${facts[@]}" --ticket "$task" --note "$note" --deliver >/dev/null || echo "trunk-latency: could not raise the slow-delivery alert for $task ($minutes minutes, $stage)"
  done < "$LANDINGS"
}

case $verb in
  measure) [ "$#" -eq 4 ] || { echo "usage: latency.sh measure <jg-home> <task> <commit>" >&2; exit 2; }; measure "$3" "$4" ;;
  check) [ "$#" -eq 2 ] || { echo "usage: latency.sh check <jg-home>" >&2; exit 2; }; check; exit 0 ;;
  *) echo "usage: latency.sh check <jg-home> | measure <jg-home> <task> <commit>" >&2; exit 2 ;;
esac
