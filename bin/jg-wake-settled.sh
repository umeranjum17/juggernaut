#!/usr/bin/env bash
# jg-wake-settled.sh - is the wake that just closed a watcher already settled?
#
#   jg-wake-settled.sh check     exit 0 and print nothing when the wake is settled; exit 1 and
#                                print the first open condition when it is not
#
# A settled wake needs a turn no more: re-prompting the model for it spends a turn that finds
# nothing to do (docs/turnend-guard.md "Settled wake"). It is settled only when ALL of these hold,
# so any one open condition keeps the re-prompt:
#   queue      no queued row the main actor could act on (bin/jg-wake-lib.sh's pending count)
#   recovery   no recovery episode waiting for its acknowledgement (state/.watcher-down)
#   decision   no open decision in any status log
#   unread     no unread informational status line
#   captain    no captain message waiting to be tagged (bin/jg-overwatch-kpi.sh pending)
#   fleet      the fleet looks the way it did when the last drain acknowledged
#              (state/.wake-ack-fleet-fp, written by bin/jg-wake-drain.sh --ack-through);
#              a missing baseline counts as changed
# A live supervision cycle is the caller's concern, not this check's. An unreadable source counts as open.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/jg-wake-lib.sh
. "$SCRIPT_DIR/jg-wake-lib.sh"
# shellcheck source=bin/jg-classify-lib.sh
. "$SCRIPT_DIR/jg-classify-lib.sh"

open_condition() {  # <name> <detail>
  printf '%s: %s\n' "$1" "$2"
  exit 1
}

settled_check() {
  local count token f decisions unread kpi

  count=$(jg_wake_actor_pending_count main) || count=1
  [ "$count" = 0 ] || open_condition queue "$count wake row(s) wait for a turn"

  token=
  if jg_recovery_marker_snapshot "$STATE/.watcher-down"; then
    token=$JG_RECOVERY_MARKER_TOKEN
  elif [ -e "$STATE/.watcher-down" ] || [ -L "$STATE/.watcher-down" ]; then
    open_condition recovery "the recovery marker cannot be read"
  fi
  case "$token" in
    ''|acked:*) ;;
    *) open_condition recovery "a recovery episode is waiting for its acknowledgement" ;;
  esac

  for f in "$STATE"/*.status; do
    [ -e "$f" ] || continue
    decisions=$(status_open_decisions "$f") || open_condition decision "a status log cannot be read"
    [ -z "$decisions" ] || open_condition decision "$(basename "$f" .status) has an open decision"
  done

  unread=$(scan_unread_surface_lines "$STATE") || open_condition unread "the status logs cannot be read"
  [ -z "$unread" ] || open_condition unread "an unread status line waits"

  kpi=$("$SCRIPT_DIR/jg-overwatch-kpi.sh" pending 2>/dev/null) || kpi=
  [ -z "$kpi" ] || open_condition captain "a captain message waits to be tagged"

  jg_wake_core fleet-unchanged "$STATE/.wake-ack-fleet-fp" >/dev/null 2>&1 \
    || open_condition fleet "the fleet changed since the last acknowledgement"
}

case "${1:-}" in
  check) settled_check; exit 0 ;;
  *) echo "usage: $(basename "$0") check" >&2; exit 2 ;;
esac
