#!/usr/bin/env bash
# Durable per-task scratch-directory record: state/<id>.scratch.
# Usage: jg-scratch.sh register <task-id> <dir>   record one scratch directory
#        jg-scratch.sh list <task-id>             print the recorded directories that are safe to reap
# A task registers every temporary directory it creates beyond the spawn-owned
# /tmp/jg-<id> root (a mktemp -d, a cache or emulator folder) so bin/jg-teardown.sh
# can reap exactly those paths once the landed-work test passes, even when the
# session that created them is gone. The record is one literal absolute path per
# line; nothing is ever matched by glob or pattern.
# A path is accepted only when it is absolute, free of glob characters and
# "."/".." components, a real directory (not a symlink), owned by this user, at
# least two components deep, and neither $HOME, an ancestor of $HOME, nor a
# direct child of $HOME. register refuses anything else; list warns and skips
# unsafe paths and silently skips missing paths. Inspection or record-read
# failures fail the whole listing so teardown cannot act on a partial result.
# The juggernaut home, repository, state and data directories, their ancestors
# and descendants are ineligible. bin/jg-teardown.sh owns the removal itself.
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
DATA="${JG_DATA_OVERRIDE:-$JG_HOME/data}"

# shellcheck source=bin/jg-pr-lib.sh
. "$SCRIPT_DIR/jg-pr-lib.sh"

# Print the refusal reason and fail when <dir> is not a safe scratch directory.
scratch_path_refusal() {
  local dir=$1 home parent protected root ancestor
  case "$dir" in
    /*) ;;
    *) echo "not an absolute path" >&2; return 1 ;;
  esac
  case "$dir" in
    *[*?[]*|*']'*|*$'\n'*|*//*|*/|*/./*|*/.|*/../*|*/..)
      echo "contains a glob character, newline, empty or dot component" >&2; return 1 ;;
  esac
  [ ! -L "$dir" ] || { echo "not a real directory" >&2; return 1; }
  ancestor=$dir
  while :; do
    if [ -d "$ancestor" ] && [ ! -x "$ancestor" ]; then
      echo "cannot search $ancestor" >&2; return 2
    fi
    [ "$ancestor" != / ] || break
    ancestor=${ancestor%/*}
    [ -n "$ancestor" ] || ancestor=/
  done
  [ -e "$dir" ] || return 3
  [ -d "$dir" ] || { echo "not a real directory" >&2; return 1; }
  [ -O "$dir" ] || { echo "not owned by this user" >&2; return 1; }
  dir=$(cd "$dir" && pwd -P) || return 2
  for root in "$JG_HOME" "$JG_ROOT" "$STATE" "$DATA"; do
    [ -d "$root" ] || continue
    protected=$(cd "$root" && pwd -P) || return 2
    case "$dir/" in
      "$protected/"*) echo "is inside a protected home, repository, state or data directory" >&2; return 1 ;;
    esac
    case "$protected/" in
      "$dir/"*) echo "is an ancestor of a protected home, repository, state or data directory" >&2; return 1 ;;
    esac
  done
  parent=${dir%/*}
  [ -n "$parent" ] || { echo "too shallow" >&2; return 1; }
  home=$(cd "$HOME" 2>/dev/null && pwd -P) || return 2
  case "$home/" in
    "$dir"/*) echo "is HOME or an ancestor of HOME" >&2; return 1 ;;
  esac
  [ "$parent" != "$home" ] || { echo "is a direct child of HOME" >&2; return 1; }
}

usage() {
  echo "usage: jg-scratch.sh register <task-id> <dir> | list <task-id>" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
CMD=$1 ID=$2
jg_pr_task_id_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
RECORD="$STATE/$ID.scratch"

case "$CMD" in
  register)
    [ "$#" -eq 3 ] || usage
    DIR=$3
    reason=$(scratch_path_refusal "$DIR" 2>&1) \
      || { echo "error: refusing to register scratch directory $DIR: $reason" >&2; exit 1; }
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
    [ ! -L "$RECORD" ] || { echo "error: scratch record is a symlink" >&2; exit 1; }
    if [ -f "$RECORD" ] && grep -qxF -- "$DIR" "$RECORD"; then
      printf 'registered: %s\n' "$DIR"
      exit 0
    fi
    ( umask 077; printf '%s\n' "$DIR" >> "$RECORD" ) || exit 1
    printf 'registered: %s\n' "$DIR"
    ;;
  list)
    [ "$#" -eq 2 ] || usage
    [ -d "$STATE" ] && [ -r "$STATE" ] && [ -x "$STATE" ] || {
      echo "error: scratch state directory cannot be inspected" >&2; exit 1;
    }
    [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || exit 0
    [ -r "$RECORD" ] || { echo "error: scratch record cannot be read" >&2; exit 1; }
    recorded=$(cat -- "$RECORD") || { echo "error: scratch record could not be read completely" >&2; exit 1; }
    while IFS= read -r DIR || [ -n "$DIR" ]; do
      [ -n "$DIR" ] || continue
      if reason=$(scratch_path_refusal "$DIR" 2>&1); then
        printf '%s\n' "$DIR"
      else
        rc=$?
        case "$rc" in
          1) echo "warning: skipping recorded scratch directory $DIR for $ID: $reason" >&2 ;;
          3) ;;
          *) echo "error: cannot inspect recorded scratch directory $DIR for $ID: $reason" >&2; exit 1 ;;
        esac
      fi
    done <<EOF
$recorded
EOF
    ;;
  *) usage ;;
esac
