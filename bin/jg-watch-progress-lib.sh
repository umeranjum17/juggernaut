#!/usr/bin/env bash
# Progress feature for jg-watch.sh. The watcher supplies its state, timers and
# classification helpers; jg-busy-lib.sh supplies worker-generation identity.

# Observe native activity, execution status and turn events independently of
# screen churn. Declared waits stay with their existing wait/escalation owner.
observe_window_progress() {  # <window-key> <task> <last-status>
  local key=$1 task=$2 f moved=1 identity observed="$STATE/.activity-observed-$1"
  identity="$task:$(jg_busy_current_gen "$STATE" "$task" 2>/dev/null || true)"
  local cutoff="$observed.next"
  printf '%s' "$identity" > "$cutoff" || return 1
  if [ "$(cat "$observed" 2>/dev/null || true)" != "$identity" ]; then
    rm -f "$STATE/.activity-$key"
    mv -f "$cutoff" "$observed"
    return
  fi
  for f in "$STATE/$task.status" "$STATE/$task.turn-ended" "$STATE/$task.busy-state" "$STATE/$task.progress"; do
    if [ "$f" = "$STATE/$task.status" ] && status_is_paused_or_captain_held "$3"; then continue; fi
    [ ! "$f" -nt "$observed" ] || moved=0
  done
  mv -f "$cutoff" "$observed" || return 1
  [ "$moved" -ne 0 ] || touch "$STATE/.activity-$key"
}

task_validation_active() {  # <task>
  [ -n "$1" ] || return 1
  "$JG_CREW_STATE_BIN" "$1" 2>/dev/null | grep -q '^state: working · source: run-step · execution active ·'
}

window_progress_absorbed() {  # <window> <task> <key> <hash> <previous-hash> <busy-now>
  local w=$1 task=$2 key=$3 h=$4 prev=$5 busy_now=$6
  local cf="$STATE/.count-$key" sf="$STATE/.stale-$key"
  local ssf="$STATE/.stale-since-$key" ewf="$STATE/.wedge-escalations-$key"
  if { [ "$h" = "$prev" ] && [ "$(cat "$cf" 2>/dev/null || echo 0)" -ge 1 ]; } \
    || { [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task" "$key"; }; then
    if [ "$(age_of "$STATE/$task.progress")" -lt "$STALE_ESCALATE_SECS" ] \
      || [ "$(age_of "$STATE/.activity-$key")" -lt "$STALE_ESCALATE_SECS" ]; then
      clear_stale_hash_tracking "$key"
      triage_log "absorbed stale (recent worker progress): $w"
      return 0
    fi
    # Bound the external read even while an active step stays on one screen.
    # The shared wedge timer rechecks the same proof when its bound is due.
    if afk_present && [ "$busy_now" -ne 0 ] && { [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ] \
      || [ "$(age_of "$ssf")" -ge "$STALE_ESCALATE_SECS" ]; }; then
      if task_validation_active "$task"; then
        printf '%s' "$h" > "$sf"
        date +%s > "$ssf"
        rm -f "$ewf"
        clear_write_tracking "$key"
        triage_log "absorbed stale (active validation step): $w"
        return 0
      elif [ -e "$ssf" ] && afk_present; then
        rm -f "$sf" "$ssf"
      fi
    fi
  fi
  return 1
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
