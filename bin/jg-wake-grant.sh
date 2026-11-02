#!/usr/bin/env bash
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
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"

BRANCH_ROWS="$STATE/.branch-eligible-rows"
BRANCH_OWNER="$STATE/.branch-eligible-owner"
MAIN_ROWS="$STATE/.main-eligible-rows"
TMP=
LOCK_HELD=false

# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ "$LOCK_HELD" = false ] || jg_lock_release "$JG_WAKE_QUEUE_LOCK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# jg-wake-lib.sh owns both the grant row-list shape and the owner-record read.
rows_valid() { jg_wake_grant_rows_valid "$1"; }

owner_matches() { # [<pid>] [<generation>]
  jg_wake_branch_owner_matches "$BRANCH_OWNER" "${1:-}" "${2:-}"
}

case "${1:-}" in
  activate)
    pid=${2:-}
    generation=${3:-}
    [ "$#" -eq 3 ] || exit 2
    case "$pid" in ''|*[!0-9]*|1) exit 2 ;; esac
    case "$generation" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
    identity=$(jg_pid_identity "$pid" 2>/dev/null) || exit 1
    [ -n "$identity" ] || exit 1
    TMP=$(mktemp "$STATE/.branch-eligible-owner.tmp.XXXXXX") || exit 1
    printf '%s\n%s\n%s\n%s\n' jg-branch-eligible-owner-v1 "$pid" "$identity" "$generation" > "$TMP" || exit 1
    chmod 0600 "$TMP" || exit 1
    jg_lock_acquire_wait "$JG_WAKE_QUEUE_LOCK"
    LOCK_HELD=true
    [ "$(jg_pid_identity "$pid" 2>/dev/null || true)" = "$identity" ] || exit 1
    rm -f -- "$BRANCH_ROWS" || exit 1
    _jg_atomic_replace "$TMP" "$BRANCH_OWNER" || exit 1
    TMP=
    ;;
  publish)
    generation=${2:-}
    [ "$#" -gt 2 ] || exit 2
    case "$generation" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
    shift 2
    TMP=$(mktemp "$STATE/.branch-eligible-rows.tmp.XXXXXX") || exit 1
    printf '%s\n' "$@" > "$TMP" || exit 1
    chmod 0600 "$TMP" || exit 1
    rows_valid "$TMP" || exit 2
    jg_lock_acquire_wait "$JG_WAKE_QUEUE_LOCK"
    LOCK_HELD=true
    owner_matches '' "$generation" || exit 1
    replace=1
    if [ -e "$BRANCH_ROWS" ] || [ -L "$BRANCH_ROWS" ]; then
      rows_valid "$BRANCH_ROWS" && cmp -s "$TMP" "$BRANCH_ROWS" || exit 1
      replace=0
    fi
    awk -F '\t' -v requested="$TMP" -v main="$MAIN_ROWS" '
      BEGIN {
        while ((getline line < requested) > 0) wanted[line]=1
        while ((getline line < main) > 0) owned[line]=1
      }
      NF >= 5 && $2 ~ /^[0-9]+$/ && $2 in wanted { present[$2]=1 }
      END {
        for (seq in wanted) if (seq in owned) exit 3
        for (seq in wanted) if (!(seq in present)) exit 1
      }
    ' "$JG_WAKE_QUEUE"
    rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    if [ "$replace" -eq 1 ]; then
      _jg_atomic_replace "$TMP" "$BRANCH_ROWS" || exit 1
      TMP=
    fi
    ;;
  release)
    generation=${2:-}
    [ "$#" -eq 2 ] || exit 2
    jg_lock_acquire_wait "$JG_WAKE_QUEUE_LOCK"
    LOCK_HELD=true
    owner_matches '' "$generation" || exit 1
    rm -f -- "$BRANCH_ROWS" || exit 1
    ;;
  deactivate)
    pid=${2:-}
    generation=${3:-}
    [ "$#" -eq 3 ] || exit 2
    jg_lock_acquire_wait "$JG_WAKE_QUEUE_LOCK"
    LOCK_HELD=true
    owner_matches "$pid" "$generation" || exit 1
    rm -f -- "$BRANCH_ROWS" "$BRANCH_OWNER" || exit 1
    ;;
  *)
    echo "usage: jg-wake-grant.sh activate PID GENERATION | publish GENERATION SEQUENCE... | release GENERATION | deactivate PID GENERATION" >&2
    exit 2
    ;;
esac

jg_lock_release "$JG_WAKE_QUEUE_LOCK"
LOCK_HELD=false
exit 0
