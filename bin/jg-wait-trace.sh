#!/usr/bin/env bash
# jg-wait-trace.sh - put each lane's declared wait on its ticket, and take it off when the lane moves on.
#
# Usage: jg-wait-trace.sh <jg-home>
#
# One step of the delivery tick (bin/jg-delivery-tick.sh), beside bin/jg-ready-trace.sh. For each task record with a `ticket=` line it
# reads the last line of the task's status file:
#   - `paused [at=<epoch>] [wait=<who>] [reason=<word>]` not recorded yet: writes the wait on the ticket (`jg-backlog.sh wait`), so a
#     lane parked with `reason=parked` reads parked, and any other declared wait reads as the one who owes the move and why.
#   - any other last line, for a lane whose wait this step wrote: writes the wait `none`, so the ticket stops waiting once the lane
#     works, reports done or is refused again (the wait a lander refusal wrote, core/trunk-landing/ticket-trail.sh, is kept as `refused:<epoch>` and goes when a newer line is written).
# What it wrote last is kept in state/.wait-trace/<task> (`<epoch>`), so a tick that finds nothing new makes no store call. A failed
# write keeps the old note and is tried again by the next tick. Always exits 0; a failure is one line.
set -u
[ "$#" -eq 1 ] && [ -d "${1:-}/state" ] || { echo "usage: jg-wait-trace.sh <jg-home>  (a home with a state directory)" >&2; exit 2; }
H=$(cd "$1" && pwd -P)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
STATE=$H/state NOTES=$H/state/.wait-trace
export JG_HOME=$H JG_STATE_OVERRIDE=$STATE JG_DATA_OVERRIDE=$H/data JG_CONFIG_OVERRIDE=$H/config

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=${meta##*/}; id=${id%.meta}
  ticket=$(sed -n 's/^ticket=//p' "$meta" | tail -n 1)
  [ -n "$ticket" ] && [ -f "$STATE/$id.status" ] || continue
  line=$(tail -n 1 "$STATE/$id.status"); note=$(cat "$NOTES/$id" 2>/dev/null || true)
  at=$(printf '%s' "$line" | sed -n 's/^[a-z-]*[^[]*\[at=\([0-9][0-9]*\)\].*/\1/p')
  case $line in
    paused\ *|paused:*)
      who=$(printf '%s' "$line" | sed -n 's/^[^:]*[[ ]wait=\([a-z]*\).*/\1/p'); why=$(printf '%s' "$line" | sed -n 's/^[^:]*[[ ]reason=\([a-z]*\).*/\1/p')
      [ -n "$who" ] && [ -n "$why" ] && [ -n "$at" ] && [ "$note" != "$at" ] || continue
      if "$SCRIPT_DIR/jg-backlog.sh" wait "$ticket" "$who" "$why" >/dev/null; then mkdir -p "$NOTES" && printf '%s\n' "$at" > "$NOTES/$id"
      else echo "jg-wait-trace: could not write the wait of $ticket; the next tick tries again" >&2; fi ;;
    *)
      [ -n "$note" ] && [ "$note" != "refused:$at" ] || continue  # a refusal's wait stays while its own line is the last one
      if "$SCRIPT_DIR/jg-backlog.sh" wait "$ticket" none >/dev/null; then rm -f -- "$NOTES/$id"
      else echo "jg-wait-trace: could not clear the wait of $ticket; the next tick tries again" >&2; fi ;;
  esac
done
exit 0
