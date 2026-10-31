#!/usr/bin/env bash
# jg-ticket.sh - record one task's ticket truth on the fleet board now.
#
# The board is the sign-off board named by config/fleet-board, whose tickets the
# tickets-sync feature publishes from this home's backlog and lane records. This
# is the fork-side call the lifecycle makes, so a merge, a dispatch, a cleanup or
# a release cut records what it knows at the moment it happens instead of leaning
# on whoever remembers to write a status line before the next poll.
#
# Usage: jg-ticket.sh <task-id> [--stage WORD] [--state WORD] [--pr URL] [--release TEXT]
#        jg-ticket.sh id <task-id>
#   id         Print the ticket id this home's sync publishes for a task, so a
#              card can name its ticket (--ticket) and the board shows it there.
#   --stage    queued | building | review | merging | done
#   --state    queued | "in progress" | "on hold" | done   (done also sets 100%)
#   --pr       the delivered PR's full URL; "" clears the linked PRs
#   --release  this ticket's target release
#
# The writer is core/tickets-sync/ticket.py, installed at
# ${XDG_DATA_HOME:-$HOME/.local/share}/jg-tickets-sync/tickets-sync/ticket.py
# (JG_TICKETS_TICKET overrides the path).
# When the feature is not installed, or this home has no fleet board, this does
# nothing and exits 0: the board is optional and the poll owns creating tickets.
# A failure names its cause on stderr and exits 1, so callers guard the call and
# a board problem never fails a merge, a spawn or a cleanup.
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
JG_HOME="${JG_HOME:-${JG_ROOT_OVERRIDE:-$JG_ROOT}}"
CONFIG="${JG_CONFIG_OVERRIDE:-$JG_HOME/config}"

usage() {
  sed -n '/^# Usage:/,/^#   --release/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ''|--*) usage >&2; exit 2 ;;
esac
TASK=$1
shift
case "$TASK" in
  *[!A-Za-z0-9._-]*|'') echo "jg-ticket: invalid task id: $TASK" >&2; exit 2 ;;
esac
# The sync publishes main/<task> as `jg-<sha256 32>` (core/tickets-sync/ticket.py
# owns that rule); id prints it without touching the board.
if [ "$TASK" = id ] && [ "$#" -eq 1 ]; then
  TASK=${1:-}
  case "$TASK" in
    ''|*[!A-Za-z0-9._-]*) echo "jg-ticket: invalid task id: $TASK" >&2; exit 2 ;;
  esac
  printf 'jg-%s\n' "$(printf 'main/%s' "$TASK" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-32)"
  exit 0
fi
[ "$#" -eq 0 ] || case "$1" in
  --stage|--state|--pr|--release) ;;
  *) usage >&2; exit 2 ;;
esac

WRITER="${JG_TICKETS_TICKET:-${XDG_DATA_HOME:-${HOME:-}/.local/share}/jg-tickets-sync/tickets-sync/ticket.py}"
[ -f "$WRITER" ] || exit 0
[ -e "$CONFIG/fleet-board" ] || exit 0

if ! command -v python3 >/dev/null 2>&1; then
  echo 'jg-ticket: python3 is required to write a ticket' >&2
  exit 1
fi
JG_HOME=$JG_HOME exec python3 "$WRITER" "$TASK" "$@"
