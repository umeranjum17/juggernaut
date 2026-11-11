#!/usr/bin/env bash
# jg-lead-daemon.sh - start and check the always-on supervision daemon of a squad
# lead home on a harness with no background shell cycle (Codex).
#
# Why: a Codex lead that supervises with foreground checkpoints burns one model
# turn every few minutes with nothing to do, and between checkpoints no watcher
# holds the lock, so Main's lead-liveness check and the turn-end guard see a home
# with no supervision. No human types in a lead pane, so the away-mode presence
# gate does not apply: bin/jg-supervise-daemon.sh runs always-on with
# JG_LEAD_DAEMON=1, handles routine wakes in bash and types only an actionable
# event into the lead's pane. While it lives it keeps state/.lead-daemon, which
# bin/jg-wake-lib.sh (jg_lead_daemon_supervising) reads as supervision for the
# turn-end guard, the pull warning and Main's lead check.
#
# Usage:
#   jg-lead-daemon.sh start    Idempotent. Capture this pane, then (unless the
#                              daemon already holds this home) launch the daemon
#                              in a non-visible tracked terminal, through the
#                              launcher bin/jg-afk-launch.sh owns, never shell &.
#                              Exit 3 on a home that needs no lead daemon (not a
#                              squad lead home, or a harness with its own cycle).
#   jg-lead-daemon.sh status   Exit 0 and print "lead-daemon: running pid=<pid>"
#                              when the daemon owns this home, else exit 1.
#
# The daemon's terminal is recorded in state/.afk-daemon-terminal, the record the
# away launcher owns; a lead home never enters away mode, so the two do not meet.
# jg-compat (shim, slice S1; deleted by S10): old names still resolve.
set -u

JG_LEAD_DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/jg-afk-launch.sh
. "$JG_LEAD_DAEMON_DIR/jg-afk-launch.sh"
set +e

# The launcher's terminal command runs the away entry; a lead runs the daemon
# itself, in lead mode, so no away flag is ever written.
jg_afk_launch_entry_cmd() {
  printf '%s' "$JG_ROOT/bin/jg-supervise-daemon.sh"
}
jg_afk_launch_daemon_cmd() {  # <lead-target> <lead-backend>
  printf 'exec env JG_HOME=%q JG_SUPERVISOR_TARGET=%q JG_SUPERVISOR_BACKEND=%q JG_DAEMON_PRIMARY_HARNESS=%q JG_LEAD_DAEMON=1 %q' \
    "$JG_HOME" "$1" "$2" "$(jg_afk_launch_primary_harness)" "$(jg_afk_launch_entry_cmd)"
}

jg_lead_daemon_log() { printf 'lead-daemon: %s\n' "$*"; }

jg_lead_daemon_status() {
  local pid
  if jg_lead_daemon_owns_supervision "$JG_AFK_LAUNCH_STATE"; then
    pid=$(cat "$JG_AFK_LAUNCH_STATE/.supervise-daemon.lock/pid" 2>/dev/null || true)
    jg_lead_daemon_log "running pid=$pid"
    return 0
  fi
  jg_lead_daemon_log "down"
  return 1
}

jg_lead_daemon_start() {
  local harness target backend result
  harness=$(jg_afk_launch_primary_harness)
  if ! jg_lead_daemon_home "$JG_HOME" "$harness"; then
    jg_lead_daemon_log "not needed: this is not a squad lead home on a harness without its own supervision cycle (harness: $harness)"
    return 3
  fi
  if daemon_lock_held_by_live_daemon; then
    if jg_lead_daemon_present "$JG_AFK_LAUNCH_STATE"; then
      jg_lead_daemon_status
      return
    fi
    jg_lead_daemon_log "a daemon that is not the lead daemon holds this home; stop it before starting the lead daemon"
    return 1
  fi
  target=$(discover_supervisor_target) || {
    jg_lead_daemon_log "could not resolve this pane (set JG_SUPERVISOR_TARGET)"
    return 1; }
  backend=$(discover_supervisor_backend) || {
    jg_lead_daemon_log "could not resolve this pane's backend (set JG_SUPERVISOR_BACKEND)"
    return 1; }
  jg_afk_launch_reconcile || return 1
  case "$backend" in
    herdr) jg_afk_launch_create_herdr "$target" "$backend"; result=$? ;;
    tmux) jg_afk_launch_create_tmux "$target" "$backend"; result=$? ;;
    *)
      jg_lead_daemon_log "no non-visible daemon-launch primitive for backend '$backend' (supported: herdr, tmux)"
      result=1 ;;
  esac
  [ "$result" -eq 0 ] || return "$result"
  # The daemon writes its marker and identity just after it takes the lock.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    jg_lead_daemon_status && return 0
    sleep 0.1
  done
  return 1
}

jg_lead_daemon_main() {
  local result
  case "${1:-}" in
    start)
      trap jg_afk_launch_lock_release EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      jg_afk_launch_lock_acquire || return 1
      jg_lead_daemon_start
      result=$?
      jg_afk_launch_lock_release || result=1
      trap - EXIT INT TERM
      return "$result" ;;
    status) jg_lead_daemon_status ;;
    *) sed -n '/^# Usage:/,/^# The daemon/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  jg_lead_daemon_main "$@"
fi
