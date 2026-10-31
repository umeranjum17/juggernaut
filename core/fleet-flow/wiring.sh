#!/usr/bin/env bash
# Install or update the home flow check for this user. Idempotent. Usage: wiring.sh [--dry-run]
# Main's config/jg-flow-check.sh becomes a symlink to the installed copy; this script never writes it.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: wiring.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/jg-flow-check.sh
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-fleet-flow/jg-flow-check.sh
if cmp -s "$SRC" "$DEST"; then echo "unchanged: $DEST"
elif [ "$DRY" -eq 1 ]; then echo "would copy: $SRC -> $DEST"; echo "dry run: nothing written"
else mkdir -p "${DEST%/*}"; install -m 755 "$SRC" "$DEST"; echo "copied: $SRC -> $DEST"
fi
