#!/usr/bin/env bash
# jg-delivery-tick.sh - one delivery pass for one home, with no model awake.
#
# Usage: jg-delivery-tick.sh <jg-home>
#
# A step whose next move is known runs from a tick, never from a model's cycle. Three callers run this
# pass: the host sentinel (core/sentinel/bin/jg-sentinel.sh), when due for its own home and each
# local, unparked lead home, so a worker's done lands while no watcher runs; the home's watcher
# (bin/jg-watch.sh) on its fast tick, so a live home acts within seconds; and a worker's own done line
# (bin/jg-lavish-guard.sh --append, with JG_DELIVERY_TICK_KICK=1), so the lander sees the lane in seconds
# instead of on the next beat. The pass is the trunk landing
# check (core/trunk-landing/trunk-landing.sh check), which also starts the go-live and the rollover.
# It first walks the steering inboxes (jg_task_inbox_walk): each task with an unread record gets one
# step of the re-ring ladder, which the watcher's window loop runs too, so a steer reaches its worker
# or its lead whatever either cycle does. It recovers unfinished idle workers
# (core/lane-end/idle-redrive.sh) and stops the agent of each Built lane
# (core/lane-end/stop-at-built.sh). Its next step records each lane's ready or resumed moment on its ticket's trail
# (bin/jg-ready-trace.sh), for every delivery mode, and sends each live worker's heartbeat (bin/jg-lease-tick.sh). A home with no local trunk (no state/trunk-tip-*) has no
# landing to run. The stop loop runs after the landing check even when there is no trunk.
#
# One runner: the pass holds the home's state/.delivery-tick.lock, and a caller that finds it held does
# nothing, so the callers never run one home's pass at the same time. The landing check's own start
# lock and per-landing run locks still keep one landing per lane.
#
# One more pass for a kick that came too late: a kicked call (JG_DELIVERY_TICK_KICK=1) that finds the
# lock held leaves state/.delivery-tick.again, tries the lock once more and exits 0. A pass removes the
# mark right after taking the lock, and a pass that ends with the mark present starts one more pass
# detached, so a done line that arrived after the running pass read its lanes is seen at once. The
# watcher and the sentinel never leave the mark. JG_DELIVERY_TICK_TRACE=<file> (a test hook) appends one
# line for each pass that took the lock.
#
# One owner of the result: the check's lines belong to the home, whoever ran the pass. They are kept in
# state/.jg-check-output-trunk-landing and raised as one `check trunk-landing` row in the home's wake
# queue, which defaults/wake-routing classes. When that row is due now, its reason is printed, so a live
# watcher rings its model at once; the sentinel leaves the row to the home's next supervision drain.
#
# Exit: 0 after a pass, or when another runner holds it; 1 when the row could not be queued (its reason
# is still printed); 2 for usage.
# JG_DELIVERY_TICK_REPORT_BUSY=1 makes a non-kicked call return 75 when it cannot take the lock.
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
AGAIN=$H/state/.delivery-tick.again
# A kicked call that finds the lock held leaves the mark first, then tries once more: a pass that ends in between
# is taken over here, and one that ends later sees the mark.
if ! jg_lock_try_acquire "$LOCK"; then
  if [ "${JG_DELIVERY_TICK_KICK:-}" != 1 ]; then
    [ "${JG_DELIVERY_TICK_REPORT_BUSY:-}" != 1 ] || exit 75
    exit 0
  fi
  : > "$AGAIN" 2>/dev/null || true
  jg_lock_try_acquire "$LOCK" || exit 0
fi
rm -f -- "$AGAIN"
[ -z "${JG_DELIVERY_TICK_TRACE:-}" ] || printf '%s pass %s\n' "$(date +%s)" "$$" >> "$JG_DELIVERY_TICK_TRACE" 2>/dev/null || true
# Release the lock, then start one more pass, detached, when a kick left the mark while this one ran.
# shellcheck disable=SC2329 # The EXIT traps call this.
tick_release() {
  jg_lock_release "$LOCK"
  [ -e "$AGAIN" ] || return 0
  unset JG_DELIVERY_TICK_KICK
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$SCRIPT_DIR/jg-delivery-tick.sh" "$H" </dev/null >/dev/null 2>&1 &
  else
    nohup bash "$SCRIPT_DIR/jg-delivery-tick.sh" "$H" </dev/null >/dev/null 2>&1 &
  fi
}
trap tick_release EXIT

# A stale row the ladder queues as due now is printed, as the landing row below is, so a live watcher
# rings its model at once; otherwise the row waits for the home's next supervision drain.
# shellcheck disable=SC2329 # Named by JG_LADDER_WAKE below; the ladder calls it.
tick_ladder_wake() { case ${JG_WAKE_LAST:-} in now:*) printf '%s\n' "$1" ;; esac; }
JG_LADDER_WAKE=tick_ladder_wake jg_task_inbox_walk "$H/state" || echo "jg-delivery-tick: a steering-inbox step could not write its record in $H" >&2
bash "$SCRIPT_DIR/../core/lane-end/idle-redrive.sh" >&2 || echo "jg-delivery-tick: the idle worker recovery step failed in $H" >&2
# Each ready or resumed lane reaches its ticket's trail within the tick (bin/jg-ready-trace.sh); it never stops the pass.
bash "$SCRIPT_DIR/jg-ready-trace.sh" "$H" >&2 || echo "jg-delivery-tick: the ready trail step failed in $H" >&2
# A lane's declared wait (a park included) reaches its ticket in the same tick (bin/jg-wait-trace.sh); it never stops the pass.
bash "$SCRIPT_DIR/jg-wait-trace.sh" "$H" >&2 || echo "jg-delivery-tick: the wait trail step failed in $H" >&2
# A Built lane (done line, PASS receipt at its branch head) has its agent stopped at once; the copy, branch and record stay.
bash "$SCRIPT_DIR/../core/lane-end/stop-at-built.sh" "$H" >&2 || echo "jg-delivery-tick: the stop-at-built step failed in $H" >&2
# Each live worker keeps its lease on its ticket, and a row no record of this home holds returns to ready (bin/jg-lease-tick.sh); it never stops the pass.
bash "$SCRIPT_DIR/jg-lease-tick.sh" "$H" >&2 || echo "jg-delivery-tick: the lease step failed in $H" >&2
# A deep Recon's writer/critic loop takes each move it owes here (the critic, its round, the researcher's gaps, the revision), so no move waits for a model's
# turn; a stop is a wake line for Main (core/recon-loop). It never stops the pass.
bash "$SCRIPT_DIR/../core/recon-loop/recon-loop.sh" tick "$H" || echo "jg-delivery-tick: the Recon loop step failed in $H" >&2
# A finished Recon or critic lane whose required next step nobody took in 10 minutes raises the done-unhandled P1 (core/next-step); it never stops the pass.
bash "$SCRIPT_DIR/../core/next-step/next-step.sh" tick "$H" >&2 || echo "jg-delivery-tick: the next-step alert step failed in $H" >&2
# A Blitz plan or a Goal with ready work that made no progress for 10 minutes raises the fleet-blocked P1, which only progress clears (core/loop-stall); it never stops the pass.
bash "$SCRIPT_DIR/../core/loop-stall/loop-stall.sh" tick "$H" >&2 || echo "jg-delivery-tick: the loop stall step failed in $H" >&2
# A missing required check is reported in the same queue as other supervision findings.
required_out=$(bash "$SCRIPT_DIR/jg-required-checks.sh" "$H" 2>&1) || true
if [ -n "$required_out" ]; then
  printf '%s\n' "$required_out"
  JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" bash "$SCRIPT_DIR/jg-alert.sh" raise supervision-down required-checks --home "$H" \
    --note "$(printf '%s' "$required_out" | tr '\n' ' ')" --deliver || echo "jg-delivery-tick: could not report required checks" >&2
else
  JG_HOME="$H" JG_STATE_OVERRIDE="$H/state" bash "$SCRIPT_DIR/jg-alert.sh" resolve supervision-down--required-checks --proof source:required-checks-present >/dev/null 2>&1 || true
fi
# The stop loop runs after the landing check, including homes without a trunk.
# shellcheck disable=SC2329 # The EXIT trap calls this after the landing check.
tick_stops() (
  # shellcheck source=core/wait-timers/bin/jg-stops-lib.sh
  . "$SCRIPT_DIR/../core/wait-timers/bin/jg-stops-lib.sh" && jg_stops_tick
)
trap 'tick_stops || echo "jg-delivery-tick: stop processing failed in $H" >&2; tick_release' EXIT
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
