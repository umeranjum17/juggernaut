#!/usr/bin/env bash
# Shared owner of the watcher's native push-transition escalation.
#
# The watcher and event-wait smoke tests source this library instead of loading
# the whole watcher to obtain handle_push_transition. Its source list is limited
# to the production boundaries the transition handler actually calls.

JG_PUSH_TRANSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/jg-wake-lib.sh
. "$JG_PUSH_TRANSITION_LIB_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$JG_PUSH_TRANSITION_LIB_DIR/jg-classify-lib.sh"
# shellcheck source=bin/jg-backend.sh
. "$JG_PUSH_TRANSITION_LIB_DIR/jg-backend.sh"
# shellcheck source=bin/jg-transition-lib.sh
. "$JG_PUSH_TRANSITION_LIB_DIR/jg-transition-lib.sh"
# Optional wait-timers feature.
_jg_pt_timers=$JG_PUSH_TRANSITION_LIB_DIR/../core/wait-timers/bin/jg-wait-timers-lib.sh
# shellcheck source=/dev/null
[ ! -r "$_jg_pt_timers" ] || . "$_jg_pt_timers"

TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${JG_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
JG_WAKE_POST_OUTPUT_ACTION=

CAPTAIN_CALL_IDENTITY=

task_captain_call_open() {  # <task>
  local task=$1
  CAPTAIN_CALL_IDENTITY=
  [ -n "$task" ] || return 1
  # shellcheck disable=SC2034 # Consumed by the watcher's stale-path captain-call check in jg-watch.sh.
  CAPTAIN_CALL_IDENTITY=$(JG_HOME="$JG_HOME" "$JG_PUSH_TRANSITION_LIB_DIR/jg-captain-hold.sh" \
    open "$task" --identity 2>/dev/null) || return 1
  return 0
}
# Set only after this watcher has printed a durable actionable reason. The
# watcher's EXIT cleanup uses it to distinguish an ordinary delivered close from
# an interruption that leaves a recovery gap before the next arm.
JG_WATCH_DELIVERED_REASON=
JG_WATCH_DELIVERY_PID=
JG_WATCH_DELIVERY_IDENTITY=
WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"
WATCH_DELIVERY_MAX_BYTES=${JG_WATCH_DELIVERY_MAX_BYTES:-65536}
WATCH_DELIVERY_KEEP_LINES=${JG_WATCH_DELIVERY_KEEP_LINES:-64}
case "$WATCH_DELIVERY_MAX_BYTES" in ''|*[!0-9]*|0) WATCH_DELIVERY_MAX_BYTES=65536 ;; esac
case "$WATCH_DELIVERY_KEEP_LINES" in ''|*[!0-9]*|0) WATCH_DELIVERY_KEEP_LINES=64 ;; esac

watch_delivery_clean_identity() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

watch_delivery_clean_reason() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-4096
}

watch_delivery_publish() {
  # Identity/reason cleaning are sequential $(): sibling $() args to one
  # printf are a bash 5.2 parse-error landmine when a CHLD trap is set.
  local reason=$1 i size tmp raw ident cleaned_reason
  [ -n "$JG_WATCH_DELIVERY_PID" ] || return 0
  [ -n "$JG_WATCH_DELIVERY_IDENTITY" ] || return 0
  i=0
  while ! jg_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  ident=$(watch_delivery_clean_identity "$JG_WATCH_DELIVERY_IDENTITY")
  cleaned_reason=$(watch_delivery_clean_reason "$reason")
  printf '%s\t%s\t%s\n' \
    "$JG_WATCH_DELIVERY_PID" \
    "$ident" \
    "$cleaned_reason" >> "$WATCH_DELIVERY_LOG" 2>/dev/null || true
  size=$(wc -c < "$WATCH_DELIVERY_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$WATCH_DELIVERY_MAX_BYTES" ]; then
        tmp="$WATCH_DELIVERY_LOG.tmp.$JG_WATCH_DELIVERY_PID"
        raw="$tmp.raw"
        tail -n "$WATCH_DELIVERY_KEEP_LINES" "$WATCH_DELIVERY_LOG" 2>/dev/null \
          | tail -c "$WATCH_DELIVERY_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^[0-9]+\t/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$WATCH_DELIVERY_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  jg_lock_release "$WATCH_DELIVERY_LOCK"
}

# Append one bounded best-effort line for an absorbed supervision event.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

# Exit after reporting one actionable wake. Tests override this callback.
wake() {
  local output_status=0
  # A reason that describes only the event this cycle classed `batch` or `silent` is
  # already recorded, so it does not leave the cycle; the next drain or the resurface
  # cadence delivers it. An urgent row from the same event latches
  # JG_WAKE_CYCLE_URGENT (bin/jg-wake-lib.sh) and always wakes.
  if [ -z "${JG_WAKE_CYCLE_URGENT:-}" ]; then
    case "${JG_WAKE_LAST:-}" in
      ''|now:*) ;;
      ?*:*) case "$1" in *"${JG_WAKE_LAST#*:}"*) return 0 ;; esac ;;
    esac
  fi
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  trap '' HUP INT TERM
  [ -z "$JG_WAKE_POST_OUTPUT_ACTION" ] || trap '' PIPE
  if echo "$1"; then
    output_status=0
    watch_delivery_publish "$1" || true
    # shellcheck disable=SC2034 # Read by bin/jg-watch.sh's EXIT cleanup.
    JG_WATCH_DELIVERED_REASON=$1
  else
    output_status=1
  fi
  if [ -n "$JG_WAKE_POST_OUTPUT_ACTION" ]; then
    "$JG_WAKE_POST_OUTPUT_ACTION" "$output_status" || true
  fi
  [ "$output_status" -eq 0 ] || exit "$output_status"
  exit 0
}

_hb_surfaced_path() {
  status_heartbeat_seen_marker_path "$STATE" "$1"
}

# The byte offset in <task>'s status log that the heartbeat backstop has already
# classified, or 0 when it has no usable position. A position rather than an
# event line lets the backstop catch an event the per-wake path missed,
# and comparing the last line cannot see an event a later routine append moved
# past - exactly the masking jg-classify-lib.sh's span read exists to stop. An
# absent or malformed marker (including one an older watcher wrote as a status
# line) reads 0, so the log is re-classified and the backstop errs toward
# surfacing rather than swallowing.
hb_surfaced_offset() {  # <task>
  status_presentation_marker_offset "$(_hb_surfaced_path "$1")" "$STATE/$1.status"
}

# Record a status log as successfully classified through the captured endpoint.
mark_surfaced() {  # <status-file> <captured-end-offset> <captured-identity>
  local f=$1 task
  case "$f" in *.status) ;; *) return 0 ;; esac
  task=$(basename "$f"); task="${task%.status}"
  status_presentation_marker_commit "$(_hb_surfaced_path "$task")" "$f" "$2" "$3"
}

mark_surface_reported() {  # <status-file> <reported-signature>
  local f=$1 task
  task=$(basename "$f"); task="${task%.status}"
  status_presentation_marker_report "$(_hb_surfaced_path "$task")" "$2"
}

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason span_record rest surface_end='' surface_ident=''
  pane_id=$(jg_transition_pane_id "$record")
  to=$(jg_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  # Optional alerts feature: suppresses the immediate wake for lanes it names (Cursor, held for the captain).
  if declare -F jg_alerts_push_suppress >/dev/null && jg_alerts_push_suppress "$task"; then
    jg_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  # A declared wait already names the human this transition would report: an
  # external dependency, or the captain a verified hold transferred the work to.
  # Either way the wait is durably recorded, so absorb the immediate escalation
  # and leave the bounded re-surface to the watcher's own pause cadence.
  if status_is_paused_or_captain_held "$(status_declared_wait_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared wait, awaiting external or captain): $window"
    jg_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  span_record=$(status_span_first_actionable_record "$STATE/$task.status" \
    "$(hb_surfaced_offset "$task")")
  case $? in
    0|1) surface_end=${span_record%%$'\t'*}; rest=${span_record#*$'\t'}; surface_ident=${rest%%$'\t'*} ;;
  esac
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  jg_wake_append stale "$window" "$reason" || exit 1
  jg_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status" "$surface_end" "$surface_ident"
  if [ -n "$task" ] && declare -F jg_wait_timer_push_delivered >/dev/null; then jg_wait_timer_push_delivered "$task" "$window" || exit 1; fi
  wake "$reason"
}

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
