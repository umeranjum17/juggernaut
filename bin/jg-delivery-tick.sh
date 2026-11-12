#!/usr/bin/env bash
# jg-delivery-tick.sh - one delivery pass for one home, with no model awake.
#
# Usage: jg-delivery-tick.sh <jg-home>
#
# A step whose next move is known runs from a tick, never from a model's cycle. Two callers run this
# pass: the host sentinel (core/sentinel/bin/jg-sentinel.sh), every minute for its own home and each
# local, unparked lead home, so a worker's done lands while no watcher runs; and the home's watcher
# (bin/jg-watch.sh) on its fast tick, so a live home acts within seconds. The pass is the trunk landing
# check (core/trunk-landing/trunk-landing.sh check), which also starts the go-live and the rollover.
# It first walks the steering inboxes (jg_task_inbox_walk): each task with an unread record gets one
# step of the re-ring ladder, which the watcher's window loop runs too, so a steer reaches its worker
# or its lead whatever either cycle does. Its next step records each lane's ready or resumed moment on its ticket's trail
# (bin/jg-ready-trace.sh), for every delivery mode. A home with no local trunk (no state/trunk-tip-*) has no
# landing to run. The stop loop runs after the landing check even when there is no trunk.
#
# One runner: the pass holds the home's state/.delivery-tick.lock, and a caller that finds it held does
# nothing, so the two callers never run one home's pass at the same time. The landing check's own start
# lock and per-landing run locks still keep one landing per lane.
#
# One owner of the result: the check's lines belong to the home, whoever ran the pass. They are kept in
# state/.jg-check-output-trunk-landing and raised as one `check trunk-landing` row in the home's wake
# queue, which defaults/wake-routing classes. When that row is due now, its reason is printed, so a live
# watcher rings its model at once; the sentinel leaves the row to the home's next supervision drain.
#
# Exit: 0 after a pass, or when another runner holds it; 1 when the row could not be queued (its reason
# is still printed); 2 for usage.
set -u
[ "$#" -eq 1 ] && [ -d "${1:-}/state" ] || { echo "usage: jg-delivery-tick.sh <jg-home>  (a home with a state directory)" >&2; exit 2; }
H=$(cd "$1" && pwd -P)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# The home's own records, never the caller's: the sentinel runs this for other homes than its own.
export JG_HOME=$H JG_STATE_OVERRIDE=$H/state JG_CONFIG_OVERRIDE=$H/config JG_DATA_OVERRIDE=$H/data
unset STATE JG_WAKE_QUEUE JG_WAKE_QUEUE_LOCK
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$SCRIPT_DIR/jg-task-inbox-lib.sh"

LOCK=$H/state/.delivery-tick.lock
jg_lock_try_acquire "$LOCK" || exit 0
trap 'jg_lock_release "$LOCK"' EXIT

# A stale row the ladder queues as due now is printed, as the landing row below is, so a live watcher
# rings its model at once; otherwise the row waits for the home's next supervision drain.
# shellcheck disable=SC2329 # Named by JG_LADDER_WAKE below; the ladder calls it.
tick_ladder_wake() { case ${JG_WAKE_LAST:-} in now:*) printf '%s\n' "$1" ;; esac; }
JG_LADDER_WAKE=tick_ladder_wake jg_task_inbox_walk "$H/state" || echo "jg-delivery-tick: a steering-inbox step could not write its record in $H" >&2
# Each ready or resumed lane reaches its ticket's trail within the tick (bin/jg-ready-trace.sh); it never stops the pass.
bash "$SCRIPT_DIR/jg-ready-trace.sh" "$H" >&2 || echo "jg-delivery-tick: the ready trail step failed in $H" >&2
# A missing required check is reported in the same queue as other supervision findings.
required_out=$(bash "$SCRIPT_DIR/jg-required-checks.sh" "$H" 2>&1) || true
if [ -n "$required_out" ]; then
  printf '%s\n' "$required_out"
  jg_wake_append check required-checks "$required_out" || echo "jg-delivery-tick: could not report required checks" >&2
fi
# The stop loop runs after the landing check, including homes without a trunk.
# shellcheck disable=SC2329 # The EXIT trap calls this after the landing check.
tick_stops() (
  # shellcheck source=core/wait-timers/bin/jg-stops-lib.sh
  . "$SCRIPT_DIR/../core/wait-timers/bin/jg-stops-lib.sh" && jg_stops_tick
)
trap 'tick_stops || echo "jg-delivery-tick: stop processing failed in $H" >&2; jg_lock_release "$LOCK"' EXIT
# The owner's bypass ends at its end time, and a ticket's when the ticket is released or closed (machine 17).
bash "$SCRIPT_DIR/jg-proof-bypass.sh" expire >/dev/null 2>&1 || echo "jg-delivery-tick: the proof bypass could not be expired in $H" >&2
# A lane that reported done inside a standing bypass is passed over proving here, before the landing check reads its proof.
bash "$SCRIPT_DIR/jg-proof-bypass-apply.sh" "$H" || echo "jg-delivery-tick: the proof bypass could not be applied in $H" >&2
compgen -G "$H/state/trunk-tip-*" >/dev/null || exit 0

OUT=$H/state/.jg-check-output-trunk-landing
tmp=$(mktemp "$OUT.XXXXXX") || { echo "jg-delivery-tick: cannot write in $H/state" >&2; exit 1; }
# The check reports by its lines, not by its exit.
bash "$SCRIPT_DIR/../core/trunk-landing/trunk-landing.sh" check "$H" > "$tmp" 2>/dev/null
[ -s "$tmp" ] || { rm -f -- "$tmp"; exit 0; }
mv -f -- "$tmp" "$OUT" || { rm -f -- "$tmp"; echo "jg-delivery-tick: cannot keep the landing check's output in $OUT" >&2; exit 1; }

prefix='check: trunk-landing: '; suffix=' [full output: state/.jg-check-output-trunk-landing]'
reason="$prefix$(head -c $((4096 - ${#prefix} - ${#suffix})) "$OUT" | tr '\t\r\n' '   ')$suffix"
JG_WAKE_LAST=
if ! jg_wake_append check trunk-landing "$reason"; then
  echo "jg-delivery-tick: could not queue the trunk-landing row in $H" >&2
  printf '%s\n' "$reason"
  exit 1
fi
case $JG_WAKE_LAST in now:*) printf '%s\n' "$reason" ;; esac
exit 0
