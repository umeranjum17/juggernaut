#!/usr/bin/env bash
# jg-ready-trace.sh - put each lane's ready and resumed moments on its ticket's trail.
#
# Usage: jg-ready-trace.sh <jg-home>
#
# One step of the delivery tick (bin/jg-delivery-tick.sh), for every delivery mode and for a Recon. For each task record with a
# `ticket=` line it reads the last line of the task's status file:
#   - `done [at=<epoch>]` not recorded yet: records `commit` with source jg-done, ref `<task>@done-<epoch>`, at that epoch, and sets
#     metadata.ready_at. A later `done` of the same lane records a newer ready_at.
#   - any other last line, for a lane whose last record was a ready: records `resume` with source jg-done, ref `<task>@resumed-<epoch>`,
#     and sets metadata.resumed_at, so the stage stops reading ready.
# A done line writes no moment when its head is the one last offered while the lane still reads ready, and none while a landing stands: a
# head that is not on the trunk then puts the wait `lead` (reason `decision`) on the row. The last head is kept in state/.ready-trace/<task>.head.
# What it recorded last is kept in state/.ready-trace/<task> (`ready:<epoch>` or `resumed:<epoch>`), so a tick that finds nothing new
# makes no store call. A failed write keeps the old note and is tried again by the next tick. Always exits 0; a failure is one line.
set -u
[ "$#" -eq 1 ] && [ -d "${1:-}/state" ] || { echo "usage: jg-ready-trace.sh <jg-home>  (a home with a state directory)" >&2; exit 2; }
H=$(cd "$1" && pwd -P)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
STATE=$H/state NOTES=$H/state/.ready-trace
# shellcheck source=bin/jg-trace-lib.sh
. "$SCRIPT_DIR/jg-trace-lib.sh"
export JG_HOME=$H JG_STATE_OVERRIDE=$STATE JG_DATA_OVERRIDE=$H/data JG_CONFIG_OVERRIDE=$H/config

# The head a lane offers: its branch in its project, empty when the record names neither (then a done line is judged by its time alone).
lane_head() {  # <meta file>
  local project branch
  project=$(sed -n 's/^project=//p' "$1" | tail -n 1); branch=$(sed -n 's/^branch=//p' "$1" | tail -n 1)
  [ -n "$project" ] && [ -n "$branch" ] || return 0
  git -C "$project" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null || true
}
# A landing stands for the ticket (the stage rule of bin/jg-beads-stage.py): it is delivering on the line, or released.
landing_stands() {  # <ticket>
  case $("$SCRIPT_DIR/jg-backlog.sh" ticket-stage "$1" 2>/dev/null | cut -f1) in released|delivering.batched|delivering.live|delivering.joining) return 0 ;; esac
  return 1
}
# Whether <head> is on the project's trunk branch (state/trunk-branch-<project>).
on_trunk() {  # <meta file> <head>
  local project trunk
  project=$(sed -n 's/^project=//p' "$1" | tail -n 1); trunk=$(cat "$STATE/trunk-branch-$(basename -- "$project")" 2>/dev/null) || return 1
  git -C "$project" merge-base --is-ancestor "$2" "refs/heads/$trunk" 2>/dev/null
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=${meta##*/}; id=${id%.meta}
  ticket=$(sed -n 's/^ticket=//p' "$meta" | tail -n 1)
  [ -n "$ticket" ] && [ -f "$STATE/$id.status" ] || continue
  line=$(tail -n 1 "$STATE/$id.status")
  note=$(cat "$NOTES/$id" 2>/dev/null || true)
  at=$(printf '%s' "$line" | sed -n 's/^[a-z-]*[^[]*\[at=\([0-9][0-9]*\)\].*/\1/p')
  case $line in
    done\ *|done:*)
      [ -n "$at" ] && [ "$note" != "ready:$at" ] || continue
      head=$(lane_head "$meta"); last=$(cat "$NOTES/$id.head" 2>/dev/null || true)
      if [ -n "$head" ] && [ -n "$last" ] && [ "$head" != "$last" ] && landing_stands "$ticket"; then
        # A landing stands, so this done line is no new try: it writes no moment. A head that is not on the trunk waits for the lead.
        on_trunk "$meta" "$head" || "$SCRIPT_DIR/jg-backlog.sh" wait "$ticket" lead decision >/dev/null \
          || { echo "jg-ready-trace: could not set the wait on $ticket; the next tick tries again" >&2; continue; }
        mkdir -p "$NOTES" && printf 'ready:%s\n' "$at" > "$NOTES/$id" && printf '%s\n' "$head" > "$NOTES/$id.head"
        continue
      fi
      case $note in ready:*) [ -z "$head" ] || [ "$head" != "$last" ] || { printf 'ready:%s\n' "$at" > "$NOTES/$id"; continue; } ;; esac  # the same head again while still ready: nothing
      if jg_trace_record "$ticket" commit work-id "$id@done-$at" --source jg-done --at "$at" --payload "{\"task\":\"$id\"}"; then
        mkdir -p "$NOTES" && printf 'ready:%s\n' "$at" > "$NOTES/$id"
        [ -z "$head" ] || printf '%s\n' "$head" > "$NOTES/$id.head"
      fi ;;
    *)
      case $note in ready:*) ;; *) continue ;; esac
      now=${at:-$(date +%s)}
      if jg_trace_record "$ticket" resume work-id "$id@resumed-$now" --source jg-done --at "$now" --payload "{\"task\":\"$id\"}"; then
        printf 'resumed:%s\n' "$now" > "$NOTES/$id"
      fi ;;
  esac
done
exit 0
