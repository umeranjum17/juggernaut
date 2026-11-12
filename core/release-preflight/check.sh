#!/usr/bin/env bash
# release-preflight - can this home pass the merge gate of a release it is about to open?
#
# Usage: check.sh <jg-home>
#
# The merge gate of a release pull request needs two things that a Squad Lead home may not hold: a proof board for the
# merge-card evidence (jg_board_file: this home's, else its parent's) and the approval key that signs the owner's yes
# (state/captain-approval.key, this home's or its parent's). Each miss prints one line `missing<TAB><what><TAB><command>`
# naming the command that Main runs to close it; exit 1. Nothing missing: no output, exit 0. A usage error is exit 2.
# bin/jg-trunk.sh push_batch runs it before a release opens, so a lead home learns in the first minute that the merge
# would be refused, and waits on Main (wait=main, reason=approval) instead of finding out at the merge.
set -u
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: check.sh <jg-home>" >&2; exit 2; }
HOME_DIR=$(cd "$1" && pwd -P)
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
BIN=$(cd "$HERE/../../bin" && pwd -P)
# shellcheck source=bin/jg-compat.sh disable=SC1091
. "$BIN/jg-compat.sh"
# shellcheck source=bin/jg-squad-lead-parent-lib.sh disable=SC1091
. "$BIN/jg-squad-lead-parent-lib.sh"
# shellcheck source=bin/jg-board-link-lib.sh disable=SC1091
. "$BIN/jg-board-link-lib.sh"

STATE=${JG_STATE_OVERRIDE:-$HOME_DIR/state}
rc=0
miss() { printf 'missing\t%s\t%s\n' "$1" "$2"; rc=1; }

jg_board_file "$HOME_DIR" >/dev/null \
  || miss "no proof board is configured for this home or its parent" "add a --board <file> line to $HOME_DIR/config/post-merge"

if [ ! -s "$STATE/captain-approval.key" ]; then
  parent=
  if jg_squad_lead_parent_record_parse "$(jg_compat_parent_marker "$HOME_DIR")" && [ "$JG_SQUAD_LEAD_PARENT_ROUTE" = local ]; then parent=$JG_SQUAD_LEAD_PARENT_HOME; fi
  [ -n "$parent" ] && [ -s "$parent/state/captain-approval.key" ] \
    || miss "no approval key signs the owner's yes in this home or its parent" "JG_HOME=${parent:-$HOME_DIR} $BIN/jg-inbox.sh approve <note id> <ticket> (makes the key)"
fi
exit "$rc"
