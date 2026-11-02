#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: jg-afk-start.sh
#   Sets state/.afk (mode preserved on refresh, see jg_afk_flag_write) unless
#   JG_AFK_STATE_PREPARED=1, checks state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon (a REFRESH: no stale-artifact clear);
#     - otherwise clears any prior away session's stale escalation artifacts
#       (jg_afk_clear_stale_artifacts) for a direct, non-prepared start, then
#       execs bin/jg-supervise-daemon.sh in the foreground. A prepared start was
#       already cleared transactionally by bin/jg-afk-launch.sh.
#
# This file is sourceable: its BASH_SOURCE guard keeps main from running, while
# exposing the daemon-lock helpers and jg_afk_clear_stale_artifacts. Sourcing it
# enables nounset and errexit; callers that need different shell options must
# restore them explicitly.
#
# This is the COMMON daemon entry for every backend. HOW it becomes a tracked
# background process differs by harness/backend and is owned elsewhere:
#   - Harnesses with a native in-pane tracked-background tool (e.g. claude, grok)
#     run this directly via that tool, so the daemon inherits the captain pane's
#     env and auto-discovers it.
#   - Harnesses with NO native background mechanism (e.g. pi) run this THROUGH
#     bin/jg-afk-launch.sh, which creates a non-visible tracked terminal per
#     backend (herdr tab/workspace, tmux detached session) and passes the
#     captain pane in as JG_SUPERVISOR_TARGET so injection targets it, not the
#     daemon's own new pane.
# Do not wrap this in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background terminal stays
# attached and has a real lifecycle.
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
    jg_compat_marker() { printf "%s\n" "${1-}/.jg-squad-lead-home"; }
    jg_compat_parent_marker() { printf "%s\n" "${1-}/.jg-squad-lead-parent"; }
    jg_compat_claims_root() { printf "%s\n" "${1-}"; }
    jg_compat_pick() { printf "%s\n" "${1-}"; }
    jg_compat_kind() { printf "%s\n" "${1-}"; }
    jg_compat_meta_is_squad_lead() { grep -q "^kind=squad_lead\$" "${1-}" 2>/dev/null; }'
fi
unset _jg_d
set -eu

JG_AFK_START_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$JG_AFK_START_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
JG_AFK_STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"
JG_AFK_LOCK="$JG_AFK_STATE/.supervise-daemon.lock"
JG_AFK_DAEMON="$JG_AFK_START_DIR/jg-supervise-daemon.sh"

# shellcheck source=bin/jg-wake-lib.sh
. "$JG_AFK_START_DIR/jg-wake-lib.sh"

jg_afk_start_usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# jg_afk_clear_stale_artifacts: on a FRESH away-session entry (the daemon is not
# already running), drop the previous away session's leftover escalation-delivery
# artifacts so they cannot surface as stale escalations under the new session.
# These are session-scoped by timing: a fresh entry owns a new supervision
# session and the new daemon has not produced anything yet, so anything present
# here belongs to a PRIOR session. This never drops a genuinely-pending
# escalation - the delivery buffer is a transient cache, and any condition still
# true (a crew still blocked, a check still firing) is re-derived and re-escalated
# fresh by the daemon's heartbeat catch-all scan and the durable
# state/.wake-queue replay (see docs/herdr-backend.md "Away-mode stale-artifact
# lifecycle" and bin/jg-supervise-daemon.sh's escalate_add/inject_wedge_alarm).
# NOT called on a refresh (daemon already alive), so the current session's own
# buffered escalations are preserved.
jg_afk_clear_stale_artifacts() {  # <state-dir>
  local state=$1
  rm -f "$state/.subsuper-escalations" \
        "$state/.subsuper-escalations.since" \
        "$state/.subsuper-inject-wedged" \
        "$state/.subsuper-unknown-acked" 2>/dev/null
}

daemon_lock_owner() {
  local owner
  if [ -L "$JG_AFK_LOCK" ]; then
    owner=$(readlink "$JG_AFK_LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$JG_AFK_LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$JG_AFK_LOCK" ] || return 1
  printf '%s\n' "$JG_AFK_LOCK"
}

daemon_pid_matches() {
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(jg_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$JG_AFK_DAEMON"*|*"jg-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

daemon_lock_pid() {
  local owner
  owner=$(daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

daemon_lock_held_by_live_daemon() {
  local owner pid
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  jg_pid_alive "$pid" || return 1
  daemon_pid_matches "$pid" "$owner"
}

jg_afk_flag_write() {  # <state-dir> [mode]
  local state=$1 requested_mode=${2:-} lock="$1/.cursor-park-owner.lock" \
    pending attempt=0 status=1 mode
  mkdir -p "$state" || return 1
  [ ! -d "$state/.afk" ] || return 1
  # An explicit mode is a caller's deliberate request (a fresh /watchover or /radio-silence
  # entry). Omitted means "just refresh" (an already-running daemon, or
  # recovery re-entering generically) and PRESERVES whatever mode is already
  # on disk via jg_afk_mode - which itself falls back to "away" when nothing
  # is on disk yet, so a genuinely fresh unspecified entry still defaults
  # away. This is what keeps a refresh from silently flipping a captain's
  # quiet mode back to away underneath them (kunchenguid/juggernaut#2356).
  case "$requested_mode" in
    away|quiet) mode=$requested_mode ;;
    *) mode=$(jg_afk_mode "$state") ;;
  esac
  pending=$(mktemp "$state/.afk.pending.XXXXXX") || return 1
  { printf '%s\n' "$mode"; date '+%s'; } > "$pending" || { rm -f "$pending"; return 1; }
  while [ "$attempt" -lt 50 ]; do
    attempt=$((attempt + 1))
    if jg_lock_try_acquire "$lock"; then
      mv "$pending" "$state/.afk" && status=0
      jg_lock_release "$lock"
      rm -f "$pending" 2>/dev/null || true
      return "$status"
    fi
    [ "$attempt" -lt 50 ] && sleep 0.1
  done
  rm -f "$pending" 2>/dev/null || true
  return 1
}

jg_afk_start_main() {
  case "${1:-}" in
    '' ) ;;
    -h|--help) jg_afk_start_usage; return 0 ;;
    * ) echo "usage: $(basename "${BASH_SOURCE[1]:-jg-afk-start.sh}")" >&2; return 2 ;;
  esac

  mkdir -p "$JG_AFK_STATE"
  if [ "${JG_AFK_STATE_PREPARED:-0}" = 1 ]; then
    [ -f "$JG_AFK_STATE/.afk" ] || { echo "afk: launcher-prepared state is missing" >&2; return 1; }
  else
    jg_afk_flag_write "$JG_AFK_STATE" || { echo "afk: failed to write away-mode flag" >&2; return 1; }
  fi

  local pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  if daemon_lock_held_by_live_daemon; then
    echo "afk: daemon already running pid=$pid"
    return 0
  fi

  if jg_pid_alive "$pid" && [ -n "$pid" ]; then
    jg_lock_remove_path "$JG_AFK_LOCK" 2>/dev/null || true
  fi

  # Fresh start: clear the previous away session's stale delivery artifacts
  # before the new daemon can surface them (fix for the leaked-artifact defect).
  if [ "${JG_AFK_STATE_PREPARED:-0}" != 1 ]; then
    jg_afk_clear_stale_artifacts "$JG_AFK_STATE"
  fi

  echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
  exec "$JG_AFK_DAEMON"
}

# Run only when executed, not when sourced (tests source jg_afk_clear_stale_artifacts
# and the lock helpers directly).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  jg_afk_start_main "$@"
fi
