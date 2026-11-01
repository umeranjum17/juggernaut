#!/usr/bin/env bash
# Turn the owner rules off in one juggernaut home: remove config/owner-rules and drop the proof gate
# from the home's single config/merge-gate entry point (addons/lib/merge-gate-lib.sh owns that file), so
# the owner-details scan and the home's own previous gate keep running.
# Usage: unwiring.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: unwiring.sh [--dry-run] <jg-home>' >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/merge-gate-lib.sh
. "$SRC/../lib/merge-gate-lib.sh"
H=$(cd "$1" && pwd -P)
f=$H/config/owner-rules
[ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
if jgmg_owned "$H"; then
  if [ "$DRY" -eq 1 ]; then jgmg_dry_run_remove "$H"; else jgmg_remove "$H" rules; fi
elif jgmg_present "$(jgmg_gate "$H")"; then
  echo "kept: $(jgmg_gate "$H") merge gate is not ours; leaving it"
fi
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
