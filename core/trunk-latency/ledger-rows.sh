#!/usr/bin/env bash
# trunk-latency ledger rows: the landings' timing as the rows the feeds read, taken from the ticket's ledger instead of a file.
# Usage: ledger-rows.sh <jg-home> [<since epoch> [<until epoch>]]
# Prints a header line and one tab-separated row per landing of data/trunk-landings.tsv (landed at or after <since> and before <until>)
# whose ticket holds the lander's `land` event (jg-backlog.sh trace landing; core/trunk-latency/latency.sh measure writes its payload):
#   task head commit first_done ready gate_start launch landed minutes stage gate_secs load queue_why queue_secs landing_secs
# first_done and gate_start are not on the ledger and stay empty; launch is ready plus the queue seconds; landed is the event's time;
# minutes is ready to landed; a landing with no ready time has empty ready and minutes. A landing whose ticket has no event is left out.
# Env: JG_DATA_OVERRIDE (default <home>/data); JG_TRUNK_LATENCY_BACKLOG (default <home>/bin/jg-backlog.sh), as latency.sh reads them.
set -u
[ "$#" -ge 1 ] && [ -d "$1" ] || { echo "usage: ledger-rows.sh <jg-home> [<since> [<until>]]" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P); since=${2:-0}; until=${3:-9999999999}
DATA=${JG_DATA_OVERRIDE:-$FMH/data}
BACKLOG=${JG_TRUNK_LATENCY_BACKLOG:-$FMH/bin/jg-backlog.sh}
printf 'task\thead\tcommit\tfirst_done\tready\tgate_start\tlaunch\tlanded\tminutes\tstage\tgate_secs\tload\tqueue_why\tqueue_secs\tlanding_secs\n'
[ -s "$DATA/trunk-landings.tsv" ] || exit 0
while IFS=$'\t' read -r task _ commit at _; do
  case $task in ''|revert-*) continue ;; esac
  case $at in ''|*[!0-9]*) continue ;; esac
  [ "$at" -ge "$since" ] && [ "$at" -lt "$until" ] || continue
  IFS=$'\t' read -r ready_at landed_at payload < <(JG_HOME=$FMH JG_DATA_OVERRIDE=$DATA bash "$BACKLOG" trace landing "$task" "$commit" 2>/dev/null)
  [ -n "${landed_at:-}" ] || continue
  landed=$(date -u -d "$landed_at" +%s 2>/dev/null) || continue
  ready=
  if [ -n "${ready_at:-}" ] && [ "$ready_at" != - ]; then ready=$(date -u -d "$ready_at" +%s 2>/dev/null)
  else ready=$(jq -r '.ready // empty' <<< "${payload:-null}" 2>/dev/null); fi
  jq -r --arg task "$task" --arg commit "$commit" --arg ready "${ready:-}" --argjson landed "$landed" '
    def s: if . == null then "" else tostring end;
    ($ready | if . == "" then null else tonumber end) as $r
    | [$task, (.head | s), $commit, "", ($r | s), "",
       (if $r != null and .queue_s != null then $r + .queue_s else null end | s), $landed,
       (if $r != null then ((($landed - $r) / 60 | if . < 0 then 0 else . end) | round) else null end | s),
       (.stage | s), (.gate_s | s), (.load | s), (.queue_why | s), (.queue_s | s), (.landing_s | s)] | @tsv' <<< "${payload:-null}"
done < "$DATA/trunk-landings.tsv"
