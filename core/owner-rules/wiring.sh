#!/usr/bin/env bash
# Turn on the owner rules in one juggernaut home: write config/owner-rules, which brief-inherit's
# brief seam reads, and wire the proof gate into the home's single config/merge-gate entry point,
# after the owner-details scan and before the home's own previous gate (addons/lib/merge-gate-lib.sh
# owns that file). Idempotent: a repeat run keeps the file it already wrote, and a home still on the
# old chained gate is folded into the one file without losing either check.
# Usage: wiring.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/merge-gate-lib.sh
. "$SRC/../lib/merge-gate-lib.sh"
H=$(cd "$1" && pwd -P)
f=$H/config/owner-rules
if [ "$DRY" -eq 1 ]; then
  echo "would write: $f"
  jgmg_dry_run "$H"
  echo "dry run: nothing written"
  exit 0
fi
printf '%s\n' 'owner-rules feature installed: brief-inherit runs owner-rules/bin/jg-owner-rules-lib.sh at brief creation; config/merge-gate runs owner-rules/bin/jg-owner-rules-gate.sh' > "$f"
jgmg_install "$H" rules "$SRC/bin/jg-owner-rules-gate.sh"
