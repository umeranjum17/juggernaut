#!/usr/bin/env bash
# launchd exec target for the Juggernaut-owned dev.juggernaut.herdr.jg-remote
# launch agent: make the Aqua login session own the jg-remote Herdr server.
#
# Usage:
#   jg-remote-herdr-guard.sh <herdr-path> <session>
#
# bin/jg-remote-doctor.sh renders the launch agent as the account's login
# shell running `exec <this script> <herdr> jg-remote` with
# LimitLoadToSessionType=Aqua, RunAtLoad, KeepAlive={SuccessfulExit=false},
# and ThrottleInterval=10, then bootstraps it into gui/<uid>. That domain, not
# the login shell, is what gives this process and every server it execs the
# Aqua audit session and login-keychain access; the login shell only gives the
# server the account's own environment.
# `herdr server` stays in the foreground under launchd, as verified in
# docs/verification/runtime-backends.md under "jg-remote server birth and login-keychain access", so the final exec provides the complete supervision lifecycle.
#
# Decision, made once per launch (exit codes matter under SuccessfulExit=false:
# 0 tells launchd the job is done until something restarts it, non-zero asks
# for a retry after the throttle interval):
#   no server owns the session socket  -> exec `herdr server --session <s>`
#                                          (foreground, launchd-supervised)
#   the owner was born in the Aqua session (launchd or the Aqua remote-job
#   worker)                            -> exit 0, leave it alone
#   the owner was born anywhere else (an SSH remote attach, a shell over
#   ssh/mosh, or a birth it cannot prove) -> `herdr server stop`, wait until the
#                                          socket is released, then exec
#                                          `herdr server --session <s>` at once
#                                          so the socket is rebound before a
#                                          reconnecting SSH attach can start
#                                          another foreign server
#   the foreign server does not release the socket in time -> exit 1
# A takeover closes every pane in that session; the parent juggernaut's
# squad_lead liveness sweep relaunches its mates into the Aqua-born server.
# bin/jg-remote-herdr-owner-lib.sh owns the owner discovery and the birth
# markers; JG_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS (default 50) bounds the
# release wait in tenths of a second. Every decision prints one line to
# stdout, which launchd routes to the agent's log.
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
set -u

SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
# shellcheck source=bin/jg-remote-herdr-owner-lib.sh
. "$SCRIPT_DIR/jg-remote-herdr-owner-lib.sh"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ "$#" -eq 2 ] || usage
HERDR_BIN=$1
SESSION=$2
[ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ] || { printf 'jg-remote-herdr-guard: herdr is not executable: %s\n' "$HERDR_BIN" >&2; exit 1; }
[ -n "$SESSION" ] || usage
command -v jq >/dev/null 2>&1 || { printf 'jg-remote-herdr-guard: jq does not resolve on the launch agent PATH\n' >&2; exit 1; }
STOP_WAIT_TENTHS=${JG_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS:-50}

log() { printf 'jg-remote-herdr-guard: %s\n' "$*"; }

herdr_status() { # prints the session's status JSON, empty when herdr fails
  HERDR_SESSION="$SESSION" "$HERDR_BIN" status --json --session "$SESSION" 2>/dev/null || true
}

status_running() { # <status-json>
  [ "$(printf '%s' "$1" | jq -r '.server.running // false' 2>/dev/null)" = true ]
}

start_server() {
  log "starting the herdr server for session $SESSION inside this launch agent (pid $$)"
  exec "$HERDR_BIN" server --session "$SESSION"
}

STATUS=$(herdr_status)
if ! status_running "$STATUS"; then
  log "no server owns session $SESSION"
  start_server
fi

SOCKET=$(printf '%s' "$STATUS" | jq -r '.server.socket // empty' 2>/dev/null)
OWNER=$(jg_remote_herdr_socket_owner "$SOCKET"); OWNER_RC=$?
if [ "$OWNER_RC" -eq 2 ]; then
  log "session $SESSION is running but lsof does not resolve, so its server's birth cannot be proven"
  BIRTH=unknown
elif [ -z "$OWNER" ]; then
  log "session $SESSION is running but no herdr process could be proven to own ${SOCKET:-its socket}"
  BIRTH=unknown
else
  BIRTH=$(jg_remote_herdr_owner_birth "$OWNER")
fi

if jg_remote_herdr_birth_is_aqua "$BIRTH"; then
  log "session $SESSION is served by pid $OWNER born in the Aqua login session ($BIRTH); nothing to do"
  exit 0
fi

log "session $SESSION is served by ${OWNER:+pid }${OWNER:-an unproven process} born outside the Aqua login session ($BIRTH); its panes cannot reach the login keychain, taking the session over"
HERDR_SESSION="$SESSION" "$HERDR_BIN" server stop --session "$SESSION" >/dev/null 2>&1 \
  || log "herdr server stop for session $SESSION did not succeed; waiting for the socket anyway"
i=0
while [ "$i" -lt "$STOP_WAIT_TENTHS" ]; do
  if ! status_running "$(herdr_status)"; then
    log "session $SESSION released its socket after $i tenths of a second"
    start_server
  fi
  sleep 0.1
  i=$((i + 1))
done
log "the foreign server for session $SESSION did not release its socket within $STOP_WAIT_TENTHS tenths of a second; exiting 1 so launchd retries"
exit 1
