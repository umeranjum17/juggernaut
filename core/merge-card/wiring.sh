#!/usr/bin/env bash
# Wire one home's PR-flow post-merge hook to this checkout's own merge-card. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
#
# config/post-merge is the hook bin/jg-merge-gate-lib.sh runs after a merge. It is one exec line that runs
# <jg-home>/core/merge-card/merge-card post --board <board>, so the hook follows the code whenever the home
# fast-forwards instead of running a copy somebody installed once. The board is the one the home already
# names: the --board of an existing hook, else JG_PROOF_BOARD. A home with neither has no evidence board
# and gets no hook (reported, exit 0). A hook that is not a merge-card hook is somebody's own and is
# refused untouched.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
HOOK=${JG_CONFIG_OVERRIDE:-$FMH/config}/post-merge
CARD=$FMH/core/merge-card/merge-card
refuse() { printf 'merge-card: refused: %s\n' "$*" >&2; exit 1; }

[ -x "$CARD" ] || refuse "$CARD is not an executable merge-card"
board=${JG_PROOF_BOARD:-}
if [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
  [ -f "$HOOK" ] && [ ! -L "$HOOK" ] || refuse "$HOOK is not a regular file; move it aside and run this again"
  grep -Eq "^exec .*merge-card'? post --board " "$HOOK" || refuse "$HOOK is not a merge-card hook; move it aside and run this again"
  board=$(sed -n "s/.*--board[= ]'\{0,1\}\([^' ]*\).*/\1/p" "$HOOK" | head -n 1)
fi
if [ -z "$board" ]; then
  echo "merge-card: no evidence board named (no hook and no JG_PROOF_BOARD); wrote nothing for $FMH"
  exit 0
fi

HOOK_TEXT=$(printf '#!/bin/sh\nexec %q post --board %q "$@"\n' "$CARD" "$board")
if [ "$DRY" -eq 1 ]; then
  echo "would write: $HOOK (mode 755):"
  printf '%s\n' "$HOOK_TEXT" | sed 's/^/  /'
  exit 0
fi
if [ -f "$HOOK" ] && [ "$(cat "$HOOK")" = "$HOOK_TEXT" ] && [ -x "$HOOK" ]; then
  echo "merge-card: already wired $FMH (nothing changed)"
  exit 0
fi
mkdir -p "$(dirname "$HOOK")"
new=$(mktemp "$HOOK.XXXXXX") || refuse "cannot write beside $HOOK"
trap 'rm -f -- "$new"' EXIT
printf '%s\n' "$HOOK_TEXT" > "$new"
chmod 755 "$new"
mv -f "$new" "$HOOK"
echo "merge-card: wired $FMH (hook runs $CARD)"
