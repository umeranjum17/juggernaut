#!/usr/bin/env bash
# stop-at-built.sh - the agent of a Built lane stops at once, with no model awake.
#
# Usage: stop-at-built.sh <jg-home>
#
# A ship lane is Built when its latest status line is `done` and its completion receipt is a PASS at the
# exact head of its branch. The delivery tick (bin/jg-delivery-tick.sh) runs this pass, so the agent ends
# within one tick of the done line, not on the next lead-sweep beat (core/lead-sweep, which stays the
# fallback for a done lane with no receipt). The end is `bin/jg-control.sh <id> exit`, which verifies the
# agent stopped and writes state/<id>.exit: that record is how the home knows the agent is stopped. The
# branch, the copy and the ticket stay for the landing; nothing is torn down, parked or forced.
#
# Machine: 1 worker: done -> stopped.
#   done, PASS receipt at the branch head, agent alive, no exit record newer than the done line -> exit
#   a lane with a landing under way, a parked lane, a lane whose agent is gone, a lane not done -> untouched
#   a receipt that is FAIL, for another head, task or spawn -> untouched (the lane is not Built)
# A refused exit is printed once per lane and reason (data/lane-end/<id>.reported), on stderr, never fatal.
# JG_LANE_END_CONTROL and JG_LANE_END_AGENT (<id> -> alive|dead|missing|unknown) name the control and
# agent-state commands; tests point them at stubs.
# Exit: 0 after a pass, 2 for usage.
set -u
[ "$#" -eq 1 ] && [ -d "${1:-}/state" ] || { echo "usage: stop-at-built.sh <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
STATE=$FMH/state
MEM=$FMH/data/lane-end
CONTROL=${JG_LANE_END_CONTROL:-$FMH/bin/jg-control.sh}
command -v jq >/dev/null 2>&1 || exit 0
umask 077
mkdir -p "$MEM" || exit 0
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
run_as_home() { JG_HOME="$FMH" JG_STATE_OVERRIDE="$STATE" "$@"; }
agent_state() {  # <id> <meta>
  if [ -n "${JG_LANE_END_AGENT:-}" ]; then run_as_home "$JG_LANE_END_AGENT" "$1" 2>/dev/null || echo unknown; return 0; fi
  ( . "$FMH/bin/jg-backend.sh" >/dev/null 2>&1 \
      && jg_backend_agent_state "$(jg_backend_of_meta "$2")" "$(jg_backend_target_of_meta "$2")" "$2" "$1" ) 2>/dev/null || echo unknown
}
# built <id> <meta>: succeeds when the lane's receipt is a PASS for this task, this spawn and the branch head.
built() {
  local id=$1 meta=$2 proj branch head spawn
  proj=$(mval "$meta" project); branch=$(mval "$meta" branch); branch=${branch:-fm/$id}
  [ -d "$proj" ] || return 1
  head=$(git -C "$proj" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || return 1
  spawn=$(mval "$meta" spawn_gen)
  jq -e --arg id "$id" --arg head "$head" --arg gen "$spawn" \
    '.task == $id and .verdict == "PASS" and .head == $head and ($gen == "" or .spawn_gen == $gen)' \
    "$STATE/$id.run-receipt.json" >/dev/null 2>&1
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  [ "$(mval "$meta" kind)" = ship ] || continue
  case $(tail -n 1 "$STATE/$id.status" 2>/dev/null) in done\ *|done:*) ;; *) continue ;; esac
  [ ! -e "$STATE/$id.parked" ] || continue
  ls "$STATE"/.trunk-run-"$id"-*.lock >/dev/null 2>&1 && continue
  exited=$(head -n 1 "$STATE/$id.exit" 2>/dev/null); case $exited in ''|*[!0-9]*) exited=0 ;; esac
  [ "$exited" -lt "$(mtime "$STATE/$id.status")" ] || continue
  built "$id" "$meta" || continue
  case $(agent_state "$id" "$meta") in dead|missing) continue ;; esac
  if run_as_home "$CONTROL" "$id" exit >/dev/null 2>&1; then
    rm -f -- "$MEM/$id.reported"
    echo "lane-end: $id is Built, its agent was stopped; its copy and branch stay"
  else
    why='is Built, but its agent could not be stopped'
    [ "$(cat "$MEM/$id.reported" 2>/dev/null)" = "$why" ] && continue
    printf '%s\n' "$why" > "$MEM/$id.reported"
    echo "lane-end: $id $why" >&2
  fi
done
exit 0
