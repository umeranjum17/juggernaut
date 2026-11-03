#!/usr/bin/env bash
# Print the one-line session-start instruction only for a genuine juggernaut
# primary whose current harness session has not already acquired the home lock.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JG_ROOT="${JG_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
STATE="${JG_STATE_OVERRIDE:-$JG_HOME/state}"

# shellcheck source=bin/jg-gate-refuse-lib.sh
. "$SCRIPT_DIR/jg-gate-refuse-lib.sh"
# shellcheck source=bin/jg-primary-scope-lib.sh
. "$SCRIPT_DIR/jg-primary-scope-lib.sh"
# shellcheck source=bin/jg-operational-input.sh
. "$SCRIPT_DIR/jg-operational-input.sh"

jg_is_gate_agent "$JG_ROOT" && exit 0
jg_primary_scope_matches "$JG_ROOT" "$STATE" || exit 0

lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    # A lock pid of 1 is legitimate inside a PID namespace, where the harness
    # holding the home lock IS pid 1, so it is no longer rejected outright; the
    # liveness check below still gates it. On a host, a lock file that wrongly
    # names pid 1 can now make this hook conclude the lock is already held and
    # stay silent, which is the safe direction for a SessionStart hook whose only
    # outputs are one nudge line or nothing.
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Stop only after the top of the chain has been compared, for the same
    # namespace reason as bin/jg-session-lock-lib.sh's walk.
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    [ "$pid" -ge 1 ] || return 1
  done
  return 1
}

lock_is_in_ancestry && exit 0
nudge=
jg_operational_input_encode session-start \
  "Run \`bin/jg-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
