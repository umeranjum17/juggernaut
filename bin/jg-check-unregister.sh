#!/usr/bin/env bash
# Retire an intentional custom watcher check and its trust binding.
# Usage: jg-check-unregister.sh <id>
# Pass only the id. An unset JG_STATE_OVERRIDE selects JG_HOME/state; an
# explicitly empty override, an invalid id, or a resolved state path that is
# not an existing non-symlink directory is refused before removal.
# Each existing named artifact must be an ordinary single-link file on the
# state directory's device; only <id>.check.sh and <id>.check-trust are removed.
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
STATE="${JG_STATE_OVERRIDE-$JG_HOME/state}"

# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"

if [ "$#" -ne 1 ] || ! jg_pr_task_id_valid "$1"; then
  echo "error: invalid custom check unregistration" >&2
  exit 2
fi

ID=$1

if [ -z "${STATE-}" ] || [ ! -d "${STATE-}" ] || [ -L "${STATE-}" ]; then
  echo "error: state directory is unavailable" >&2
  exit 1
fi

CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
STATE_DEVICE=$(jg_pr_file_device "$STATE") || {
  echo "error: state directory is unavailable" >&2
  exit 1
}

for artifact in "$CHECK" "$TRUST"; do
  [ -e "$artifact" ] || [ -L "$artifact" ] || continue
  if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
    || [ "$(jg_pr_file_device "$artifact")" != "$STATE_DEVICE" ] \
    || [ "$(jg_pr_file_link_count "$artifact")" != 1 ]; then
    echo "error: custom check is unsafe to remove" >&2
    exit 1
  fi
done

rm -f -- "$CHECK" "$TRUST" || {
  echo "error: custom check could not be removed" >&2
  exit 1
}
printf 'unregistered: state/%s.check.sh\n' "$ID"
