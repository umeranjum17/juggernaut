#!/usr/bin/env bash
# jg-lease-tick.sh - keep each live worker's lease on its ticket, and return a row nobody holds to ready.
#
# Usage: jg-lease-tick.sh <jg-home>
#
# One step of the delivery tick (bin/jg-delivery-tick.sh), which the home's watcher runs every 30 s and the host sentinel every 60 s, so a
# worker stays live on the board while the watcher is down. For each task record with a `ticket=` and an `agent_name=` whose agent is alive
# it sends `jg-backlog.sh beat <ticket>` as the agent name once 120 s have passed since the record's last beat (the mtime of
# state/<task>.beat; no file reads as never). A lease is 300 s, so three tries fall inside it. It reads no lease first: that read costs as
# much as the beat. At most 20 beats go out in one pass, the longest-waiting first, so more live workers than one pass serves are all served
# within a few passes and none starves.
# A beat that bd refuses because the row is not in progress (a hold, a date) is a wait, not a fault: the file is touched, no line is printed,
# and the next beat comes 120 s later, which takes a new lease once the hold is over. A beat that fails is printed once and tried at the
# next tick, as is a row another name owns.
# The tick relaunches nothing and reclaims no lane: a record keeps its row when its pane is gone, done or not, and recovery of that lane stays
# with the supervisor (`bin/jg-control.sh relaunch`) and the sentinel's own relaunch. The one reclaim is a row in progress whose lease is
# 10 minutes past and for which this home holds no task record at all: `jg-backlog.sh reclaim` returns it to ready and names who lost it.
# config/lease-reclaim holding `report` prints what would be reclaimed and writes nothing. Home scripts only: no pane writes a beat.
# JG_LEASE_AGENT (<task> -> alive|dead|missing|unknown) names the agent-state command; tests point it at a stub.
# Always exits 0; a failure is one line on stderr.
set -u
[ "$#" -eq 1 ] && [ -d "${1:-}/state" ] || { echo "usage: jg-lease-tick.sh <jg-home>  (a home with a state directory)" >&2; exit 2; }
H=$(cd "$1" && pwd -P)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
STATE=$H/state
export JG_HOME=$H JG_STATE_OVERRIDE=$STATE JG_DATA_OVERRIDE=$H/data JG_CONFIG_OVERRIDE=$H/config
INTERVAL=120 LIMIT=20
mval() { sed -n "s/^$2=//p" "$1" | tail -n 1; }
mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
agent_state() {  # <task> <meta>
  if [ -n "${JG_LEASE_AGENT:-}" ]; then "$JG_LEASE_AGENT" "$1" 2>/dev/null || echo unknown; return 0; fi
  # shellcheck source=bin/jg-backend.sh disable=SC1091
  ( . "$SCRIPT_DIR/jg-backend.sh" >/dev/null 2>&1 \
      && jg_backend_agent_state "$(jg_backend_of_meta "$2")" "$(jg_backend_target_of_meta "$2")" "$2" "$1" ) 2>/dev/null || echo unknown
}

now=$(date +%s) held=() due=()
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=${meta##*/}; id=${id%.meta}
  ticket=$(mval "$meta" ticket)
  held+=(--keep "${ticket:-$id}" --keep "$id")
  name=$(mval "$meta" agent_name)
  [ -n "$ticket" ] && [ -n "$name" ] || continue
  last=$(mtime "$STATE/$id.beat")
  [ $((now - last)) -ge "$INTERVAL" ] || continue
  due+=("$last $id")
done

sent=0
while read -r _ id; do
  [ -n "$id" ] && [ "$sent" -lt "$LIMIT" ] || continue
  meta=$STATE/$id.meta
  [ "$(agent_state "$id" "$meta")" = alive ] || continue
  sent=$((sent + 1))
  rc=0; out=$(JG_BACKLOG_LANE=$(mval "$meta" agent_name) "$SCRIPT_DIR/jg-backlog.sh" beat "$(mval "$meta" ticket)" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$STATE/$id.beat"
  else
    [ "$rc" -ne 13 ] || : > "$STATE/$id.beat"
    echo "jg-lease-tick: the beat for $id failed, tried again at the next tick: $(printf '%s' "$out" | tr '\n' ' ')" >&2
  fi
done < <(printf '%s\n' "${due[@]-}" | sort -n -s -k1,1)

mode=--report; [ "$(cat "$H/config/lease-reclaim" 2>/dev/null)" = report ] || mode=
"$SCRIPT_DIR/jg-backlog.sh" reclaim ${mode:+"$mode"} "${held[@]}" || echo "jg-lease-tick: the reclaim step failed in $H" >&2
exit 0
