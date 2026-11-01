#!/usr/bin/env bash
# Restart squad leads onto the current instruction surface and launch-time
# wiring, persisting their open records first.
#
# Usage: jg-squad-lead-restart.sh <squad-lead-id>... [--help]
#
# This is the executable half of /resupply's reload step. A running agent
# holds AGENTS.md and every skill it has loaded frozen from launch, and no
# verified harness offers a reload, so a re-read steer cannot replace either -
# it appends a second copy of the mate's own job description with no defined
# precedence. Replacing the agent is the only mechanism that guarantees the new
# bytes are the ones read, and the only one that re-resolves the launch-time
# wiring - harness, model, effort, turn-end hooks, and every other flag a harness
# reads once at startup. That second half is why the update pass sends every live
# mate here, including one already on the target commit: launch-time wiring is
# not derivable from a git diff, so an unchanged tracked surface does not mean
# the running agent is already on the current behavior.
#
# The cost of that guarantee is the conversation, which is why this command runs
# in two phases and why the first one is a GATE, not a courtesy:
#
#   A. PERSIST. Every mate is asked, in one marked request, to durably record the
#      open work it holds only in conversation - a task for each unfiled open
#      record, including a captain call it formed but never registered, and a
#      status correction for each task whose recorded state is now stale. That is
#      the /intel skill's "Open-record persistence" contract and nothing else from
#      it: no memory, learnings, or captain-preference sweep, which would make
#      every instruction update cost far more than the reload it is paying for.
#      All requests go out before any restart, so a slow mate delays only its own
#      restart instead of serializing the fleet behind it. Restarts themselves run
#      one at a time: lifecycle control takes one home-wide lock (bin/jg-lease-lib.sh),
#      so two relaunches in flight collide and one of them loses its restart.
#   B. RESTART. Only after that mate's own correlated answer lands on the parent
#      channel. The gate is that answer, never a wall clock, so a mate that is
#      mid-turn queues the request behind that turn; the bound below exists to
#      end the wait, not to authorize a restart without the answer. A timeout
#      deliberately leaves that unanswered expectation open: it is a genuine
#      open loop owned by the ordinary pending-reply recovery ladder, not state
#      this restart pass may close.
#      A local mate's answer is often still mid-turn when it lands, and the
#      relaunch refuses to type its exit command into a composer it cannot
#      prove empty. So after the answer, the pass also waits, bounded, until
#      that mate's composer reads exactly empty; a mate still busy at the bound
#      is nudged and keeps its agent. A remote mate's composer lives on its
#      host, where the host-local relaunch applies the same refusal itself.
#
# A mate whose persist answer did not arrive or whose runtime cannot prove a
# restart gets the ordinary re-read nudge and is reported as a nudge, never as a
# clean reload. Once a relaunch is attempted, any failed or ambiguous result is
# reported as unknown rather than attributing it to either incarnation.
#
# Placement changes the transport and nothing else. A local mate is restarted
# with bin/jg-control.sh <id> relaunch, which republishes this home's own
# metadata directly; a remote mate is restarted with
# bin/jg-remote-squad-lead-relaunch.sh, which runs that same command on its
# host over bin/jg-on.sh and then republishes this primary's own route
# metadata from the identity the host confirmed, since the host-local verb can
# only rewrite its own endpoint record. The restart decision, the profile, the
# request text, the bound, the failure vocabulary, and this report are all
# computed here in the primary and are identical for both.
#
# Nothing here forces, stashes, or discards anything. bin/jg-control.sh owns the
# restart transaction, its checkpoint, its journal, and its rollback; a refusal
# before the agent is stopped leaves the mate running exactly as it was.
#
# Restart candidacy itself belongs to bin/jg-update.sh, which knows which homes
# the update pass actually left on the target commit; this command re-checks
# capability on its own argv rather than trusting a caller's list.
#
# Environment knobs:
#   JG_SQUAD_LEAD_PERSIST_WAIT  seconds to wait for one mate's persist answer (900)
#   JG_SQUAD_LEAD_IDLE_WAIT     seconds after that answer to wait for its composer to read empty (600)
#   JG_SQUAD_LEAD_PERSIST_POLL  seconds between checks of the answer and the composer (5)
#
#   A restart is reported with the epoch it started and the epoch it finished, so a pass
#   log shows for itself whether two restarts ever overlapped.
#
# Exit status: 0 every named mate restarted; 3 at least one was nudged or left
# unreached and every mate was still accounted for; 1 the input itself is
# unusable; 2 invalid use.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
_jg_d=${BASH_SOURCE[0]%/*}
[ "$_jg_d" != "${BASH_SOURCE[0]}" ] || _jg_d=.
if [ -r "$_jg_d/jg-compat.sh" ]; then
  # shellcheck source=bin/jg-compat.sh
  . "$_jg_d/jg-compat.sh"
else
  # A copy of this script with no compat file beside it (a test fixture) has no
  # legacy record to read, so every legacy reader answers "nothing legacy here".
  eval 'jg_compat_legacy_of() { printf "%s\n" "${1-}"; }
    jg_compat_legacy_product() { printf "%s\n" "${1-}"; }
    jg_compat_record_ok() { [ "${1-}" = "${2-}" ]; }
    jg_compat_label_ok() { [ -n "${1-}" ] && [ "${1-}" = "${2-}" ]; }
    jg_compat_marker_ok() { [ "${1-}" = JUGGERNAUT_OP ]; }
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,72{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

if [ -z "${JG_HOME:-}" ]; then
  echo "error: JG_HOME is not set; jg-squad-lead-restart refuses to resolve squad leads without an explicit juggernaut home" >&2
  exit 1
fi
[ -d "$JG_HOME" ] || { echo "error: JG_HOME '$JG_HOME' is not a directory" >&2; exit 1; }
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing; jg-squad-lead-restart cannot resolve squad leads for JG_HOME '$JG_HOME'" >&2; exit 1; }

# shellcheck source=bin/jg-squad-lead-restart-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-restart-lib.sh"
# shellcheck source=bin/jg-squad-lead-nudge-lib.sh
. "$SCRIPT_DIR/jg-squad-lead-nudge-lib.sh"
# shellcheck source=bin/jg-pending-reply-lib.sh
. "$SCRIPT_DIR/jg-pending-reply-lib.sh"

PERSIST_WAIT=${JG_SQUAD_LEAD_PERSIST_WAIT:-900}
IDLE_WAIT=${JG_SQUAD_LEAD_IDLE_WAIT:-600}
PERSIST_POLL=${JG_SQUAD_LEAD_PERSIST_POLL:-5}
case "$PERSIST_WAIT" in ''|*[!0-9]*) echo "error: JG_SQUAD_LEAD_PERSIST_WAIT must be a non-negative integer: $PERSIST_WAIT" >&2; exit 2 ;; esac
case "$IDLE_WAIT" in ''|*[!0-9]*) echo "error: JG_SQUAD_LEAD_IDLE_WAIT must be a non-negative integer: $IDLE_WAIT" >&2; exit 2 ;; esac
case "$PERSIST_POLL" in ''|*[!0-9]*|0) echo "error: JG_SQUAD_LEAD_PERSIST_POLL must be a positive integer: $PERSIST_POLL" >&2; exit 2 ;; esac

IDS=()
for arg in "$@"; do
  case "$arg" in
    -*) echo "error: unexpected argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
  # /resupply's action line names each mate by its jg-<id> selector; the
  # bare id is equally acceptable so a hand-run stays natural.
  id=${arg#jg-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid squad lead id: $arg" >&2; exit 2 ;; esac
  case " ${IDS[*]:-} " in
    *" $id "*) continue ;;
  esac
  IDS+=("$id")
done
[ "${#IDS[@]}" -gt 0 ] || { usage >&2; exit 2; }

# Parked-home guard (core/parked-homes): a parked squad_lead home
# gets no restart pass at all - no persist request, no relaunch, no nudge. One
# line names each skip. The shim answers not parked when the feature is absent.
# shellcheck source=bin/jg-parked-homes-lib.sh
. "$SCRIPT_DIR/jg-parked-homes-lib.sh"
LIVE_IDS=()
for id in ${IDS[@]+"${IDS[@]}"}; do
  jg_parked_skip_meta "$STATE/$id.meta" "$id" restart && continue
  LIVE_IDS+=("$id")
done
IDS=(${LIVE_IDS[@]+"${LIVE_IDS[@]}"})
[ "${#IDS[@]}" -gt 0 ] || exit 0

# Per-mate pass state, kept as parallel indexed arrays so this stays bash-3.2
# safe. PLAN is the phase the mate reached: persisted-pending, awaiting-empty,
# restarting, done, or fallback with the reason already decided.
PLAN=()
REASON=()
CORR=()
DEADLINE=()
PLACEMENT=()
HOST=()
HARNESS=()
MODEL=()
EFFORT=()
RESTART_PID=()
RESTART_RESULT=()

restarted_count=0
nudged_count=0
unreached_count=0

# The first line of a command's output that carries anything, flattened to one
# readable line with its "error: " prefix dropped. A refusal's own words are the
# most useful thing this report can carry, and its first line is often blank.
first_reported_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

# Send the ordinary re-read steer to a mate this pass will not restart, and say
# plainly which it was. A nudge is a partial reload and is never reported as more.
fall_back_to_nudge() {  # <id> <reason>
  local id=$1 reason=$2 out
  if out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/jg-send.sh" "$id" "$JG_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
    nudged_count=$((nudged_count + 1))
    printf 'nudged: %s: %s\n' "$id" "$reason"
  else
    unreached_count=$((unreached_count + 1))
    printf 'unreached: %s: %s; the re-read message could not be delivered either: %s\n' \
      "$id" "$reason" "$(first_reported_line "$out")"
  fi
}

report_unreached() {  # <id> <reason>
  unreached_count=$((unreached_count + 1))
  printf 'unreached: %s: %s\n' "$1" "$2"
}

restart_mate() {  # <array-index>
  local i=$1 id restart_out restart_rc restart_reason ran_on
  id=${IDS[$i]}
  # The watcher's own relaunch notice for this restart is not news (defaults/wake-routing).
  printf '%s\t%s\n' "$(date +%s)" "$id" >> "$STATE/.squad-lead-restart-pass" 2>/dev/null || true
  if [ "${PLACEMENT[i]}" = remote ]; then
    restart_out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/jg-remote-squad-lead-relaunch.sh" \
      "$id" "${HARNESS[i]}" "${MODEL[i]:-default}" "${EFFORT[i]:-default}" < /dev/null 2>&1)
    restart_rc=$?
  else
    restart_out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/jg-control.sh" "$id" relaunch 2>&1)
    restart_rc=$?
  fi
  if [ "$restart_rc" -eq 0 ]; then
    ran_on=$(printf '%s\n' "$restart_out" | sed -n 's/^relaunched .* harness=\([^ ]*\).*/\1/p' | tail -1)
    [ -n "$ran_on" ] || ran_on=${HARNESS[i]}
    if [ "${PLACEMENT[i]}" = remote ]; then
      printf 'restarted: %s on %s (%s) at %s\n' "$id" "${HOST[i]}" "$ran_on" "$(date +%s)"
    else
      printf 'restarted: %s (%s) at %s\n' "$id" "$ran_on" "$(date +%s)"
    fi
    return
  fi

  restart_reason=$(first_reported_line "$restart_out")
  [ -n "$restart_reason" ] || restart_reason="the restart failed without a reported reason"
  report_unreached "$id" "the restart outcome is unknown: $restart_reason"
}

# Whether a local mate's composer reads exactly empty right now, through the
# same classifier jg-control's exit guard reads, so a relaunch started here is
# not refused for a composer that is still mid-turn.
composer_reads_empty() {  # <array-index>
  local id=${IDS[$1]}
  jg_backend_validate_task_endpoint "$STATE/$id.meta" "$id" 2>/dev/null || return 1
  [ "$(jg_backend_composer_state "$JG_BACKEND_VALIDATED_BACKEND" \
    "$JG_BACKEND_VALIDATED_TARGET" "jg-$id" 2>/dev/null)" = empty ]
}

# The persist answer landed: a remote mate restarts now, a local one first
# waits for its composer to read empty.
persist_answered() {  # <array-index>
  local i=$1
  if [ "${PLACEMENT[i]}" = remote ]; then
    pending_count=$((pending_count - 1))
    launch_restart "$i"
    return
  fi
  DEADLINE[i]=$(($(date +%s) + IDLE_WAIT))
  PLAN[i]=awaiting-empty
}

launch_restart() {  # <array-index>
  # One restart at a time. bin/jg-control.sh takes a home-wide lease-command lock
  # for lifecycle control, so two relaunches at once collide on it and one of them
  # loses its restart. Every persist request is still sent before any restart, so a
  # slow mate delays only its own turn in the queue, never the fleet's requests.
  if [ "$restart_active_count" -gt 0 ]; then
    PLAN[$1]=ready
    restart_ready_count=$((restart_ready_count + 1))
    return
  fi
  start_restart_worker "$1"
}

start_restart_worker() {  # <array-index>
  local i=$1 result tmp
  result="$RESULT_DIR/$i.result"
  tmp="$result.tmp"
  # Print the start from this loop, not from the worker: the worker's own stdout is
  # captured until it finishes, so a line printed there would land after the outcome.
  printf 'restarting: %s at %s\n' "${IDS[$i]}" "$(date +%s)"
  ( trap - EXIT; restart_mate "$i" > "$tmp"; mv -f "$tmp" "$result" ) &
  RESTART_PID[i]=$!
  RESTART_RESULT[i]=$result
  PLAN[i]=restarting
  restart_active_count=$((restart_active_count + 1))
}

# Start the next queued restart once nothing else is restarting, so the queue drains
# in argv order without ever putting two relaunches in flight.
launch_next_ready() {
  local i=0
  [ "$restart_active_count" -eq 0 ] && [ "$restart_ready_count" -gt 0 ] || return 0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" = ready ]; then
      restart_ready_count=$((restart_ready_count - 1))
      start_restart_worker "$i"
      return 0
    fi
    i=$((i + 1))
  done
}

harvest_restarts() {
  local i out worker_state
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != restarting ]; then
      i=$((i + 1))
      continue
    fi
    if [ -f "${RESTART_RESULT[i]}" ]; then
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      out=$(cat "${RESTART_RESULT[i]}")
    else
      if kill -0 "${RESTART_PID[i]}" 2>/dev/null; then
        worker_state=$(ps -p "${RESTART_PID[i]}" -o stat= 2>/dev/null || true)
        case "$worker_state" in
          Z*) ;;
          *)
            i=$((i + 1))
            continue
            ;;
        esac
      fi
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      if [ -f "${RESTART_RESULT[i]}" ]; then
        out=$(cat "${RESTART_RESULT[i]}")
      else
        out="unreached: ${IDS[$i]}: the restart worker exited before publishing an outcome"
      fi
    fi
    printf '%s\n' "$out"
    case "$out" in
      restarted:*) restarted_count=$((restarted_count + 1)) ;;
      nudged:*) nudged_count=$((nudged_count + 1)) ;;
      *) unreached_count=$((unreached_count + 1)) ;;
    esac
    PLAN[i]="done"
    restart_active_count=$((restart_active_count - 1))
    i=$((i + 1))
  done
}

# --- phase A: persist ------------------------------------------------------
# Every request goes out before any restart, so the fleet persists concurrently
# and one busy mate delays only itself.

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  id=${IDS[$i]}
  PLAN[i]="fallback"
  REASON[i]=""
  CORR[i]=""
  DEADLINE[i]=""
  PLACEMENT[i]=""
  HOST[i]=""
  HARNESS[i]=""
  MODEL[i]=""
  EFFORT[i]=""
  if ! jg_squad_lead_restart_capable "$STATE/$id.meta"; then
    REASON[i]=$JG_SQUAD_LEAD_RESTART_REASON
    i=$((i + 1))
    continue
  fi
  PLACEMENT[i]=$JG_SQUAD_LEAD_RESTART_PLACEMENT
  HOST[i]=$JG_SQUAD_LEAD_RESTART_HOST
  HARNESS[i]=$JG_SQUAD_LEAD_RESTART_HARNESS
  if [ "${PLACEMENT[i]}" = remote ]; then
    # A local relaunch re-resolves this home's durable squad_lead pin on its own,
    # which is the one owner of that resolution. A remote one cannot: it runs in
    # a home whose config/squad-lead-harness is deliberately NOT inherited, so
    # the file on that host belongs to a different home and re-resolving there
    # would silently move the mate onto another runtime. Resolve the pin here and
    # pass it explicitly, so both placements land on the same decision.
    if ! HARNESS[i]=$("$SCRIPT_DIR/jg-harness.sh" squad_lead "$id") \
      || ! MODEL[i]=$("$SCRIPT_DIR/jg-harness.sh" squad-lead-model "$id") \
      || ! EFFORT[i]=$("$SCRIPT_DIR/jg-harness.sh" squad-lead-effort "$id"); then
      REASON[i]="its configured squad_lead profile is invalid; no restart was attempted"
      i=$((i + 1))
      continue
    fi
    case "${EFFORT[i]}" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *) EFFORT[i]="" ;;
    esac
    if [ "${EFFORT[i]}" = ultra ] && ! "$SCRIPT_DIR/jg-harness.sh" validate-native-effort "${HARNESS[i]}" "${MODEL[i]}" "${EFFORT[i]}"; then
      REASON[i]="the configured Ultra profile does not select native Codex through Pi"
      i=$((i + 1))
      continue
    fi
  fi

  if ! corr=$(jg_pending_reply_create "$JG_HOME" "$STATE" "$id" \
    "$JG_SQUAD_LEAD_PERSIST_REQUEST"); then
    REASON[i]="its answer about the open work cannot be tracked, so a clean reload could not be proven"
    i=$((i + 1))
    continue
  fi
  if ! send_out=$(JG_HOME="$JG_HOME" JG_STATE_OVERRIDE="$STATE" \
    JG_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/jg-send.sh" "$id" "$JG_SQUAD_LEAD_PERSIST_REQUEST" 2>&1); then
    jg_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    REASON[i]="the request to write down its open work could not be delivered: $(first_reported_line "$send_out")"
    i=$((i + 1))
    continue
  fi
  CORR[i]=$corr
  DEADLINE[i]=$(($(date +%s) + PERSIST_WAIT))
  PLAN[i]="persisted-pending"
  i=$((i + 1))
done

# --- phase B: restart ------------------------------------------------------

RESULT_DIR=$(mktemp -d "$STATE/.squad-lead-restart.XXXXXX") || {
  echo "error: could not create restart result directory under $STATE" >&2
  exit 1
}
trap 'rm -rf -- "$RESULT_DIR"' EXIT
pending_count=0
restart_active_count=0
restart_ready_count=0
i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  if [ "${PLAN[i]}" = persisted-pending ]; then
    pending_count=$((pending_count + 1))
  else
    fall_back_to_nudge "${IDS[$i]}" "${REASON[i]}"
    PLAN[i]="done"
  fi
  i=$((i + 1))
done

while [ "$((pending_count + restart_active_count + restart_ready_count))" -gt 0 ]; do
  now=$(date +%s)
  next_wait=$PERSIST_POLL
  # Resolve every arrived answer before processing any timeout. Delivery of a
  # later fleet request can outlast an earlier mate's deadline under load; that
  # expired mate must not hold an already-confirmed mate behind its fallback.
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" = persisted-pending ] \
      && jg_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
      persist_answered "$i"
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != persisted-pending ]; then
      i=$((i + 1))
      continue
    fi
    if [ "$now" -ge "${DEADLINE[i]}" ]; then
      # A reply can land after the fleet-wide resolution pass. Recheck at the
      # timeout decision so an answer already on disk wins over the fallback.
      if jg_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
        persist_answered "$i"
      else
        fall_back_to_nudge "${IDS[$i]}" \
          "it did not confirm within ${PERSIST_WAIT}s that its open work is written down, so its conversation was not spent"
        PLAN[i]="done"
        pending_count=$((pending_count - 1))
      fi
    else
      remaining=$((DEADLINE[i] - now))
      [ "$remaining" -ge "$next_wait" ] || next_wait=$remaining
    fi
    i=$((i + 1))
  done
  # A just-answered mate is checked in the same pass, so an idle one restarts
  # without waiting a poll.
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" = awaiting-empty ]; then
      if composer_reads_empty "$i"; then
        pending_count=$((pending_count - 1))
        launch_restart "$i"
      elif [ "$(date +%s)" -ge "${DEADLINE[i]}" ]; then
        fall_back_to_nudge "${IDS[$i]}" \
          "it wrote down its open work but was still busy ${IDLE_WAIT}s later (its input box never read empty), so it was not stopped mid-turn"
        PLAN[i]="done"
        pending_count=$((pending_count - 1))
      else
        remaining=$((DEADLINE[i] - $(date +%s)))
        [ "$remaining" -ge "$next_wait" ] || next_wait=$remaining
      fi
    fi
    i=$((i + 1))
  done
  harvest_restarts
  launch_next_ready
  [ "$((pending_count + restart_active_count + restart_ready_count))" -eq 0 ] || sleep "$next_wait"
done

# --- summary ---------------------------------------------------------------

printf 'summary: %d of %d restarted, %d nudged, %d unreached\n' \
  "$restarted_count" "${#IDS[@]}" "$nudged_count" "$unreached_count"
[ "$((nudged_count + unreached_count))" -eq 0 ] || exit 3
exit 0
