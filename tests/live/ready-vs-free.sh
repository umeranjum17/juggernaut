#!/usr/bin/env bash
# Live check 4 (stop 3, every 1 min): ready tickets are not left beside free lanes. Ready = tickets bin/jg-backlog.sh ready --spawnable
# lists; free = config/lane-target minus the task records in state/. Both at once for longer than JG_LIVE_REFILL_S (default 300) is red.
# shellcheck source=tests/live/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
limit=${JG_LIVE_REFILL_S:-300}; now=$(live_now); mark=$STATE/.live-ready-free-since
ready=$(${JG_LIVE_READY_CMD:-"$LIVE_ROOT/bin/jg-backlog.sh" ready --spawnable} 2>/dev/null | grep -c . )
target=$(cat "$CONFIG/lane-target" 2>/dev/null || echo 0); case $target in ''|*[!0-9]*) target=0 ;; esac
lanes=$(find "$STATE" -maxdepth 1 -name '*.meta' 2>/dev/null | grep -c .); free=$((target - lanes))
if [ "$ready" -gt 0 ] && [ "$free" -gt 0 ]; then
  [ -s "$mark" ] || { mkdir -p "$STATE" && echo "$now" > "$mark"; }
  since=$(cat "$mark" 2>/dev/null || echo "$now")
  [ $((now - since)) -le "$limit" ] || live_red "$ready ready ticket(s) beside $free free lane(s) for $((now - since))s"
  live_pass "$ready ready beside $free free, waiting $((now - since))s of ${limit}s"
fi
rm -f -- "$mark"
live_pass "$ready ready, $free free: nothing waits on a lane"
