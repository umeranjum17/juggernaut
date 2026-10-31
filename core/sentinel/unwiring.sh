#!/usr/bin/env bash
# Undo wiring.sh: restore the jg-sentinel user unit to its pre-install text and restart the service on it, then remove the installed copy.
# Idempotent: rerun it once nothing is installed. Usage: unwiring.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: unwiring.sh [--dry-run]" >&2; exit 2; }
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-sentinel
UNIT=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/jg-sentinel.service
STAMP=$(date +%s)

if [ -e "$DEST/unit.absent" ]; then
  echo "refused: jg-sentinel.service did not exist before install. It stays, so the sentinel never stops; stop it by hand only if you mean to." >&2
  exit 1
fi
if [ ! -e "$DEST/unit.before" ]; then echo "not installed: nothing to restore"; exit 0; fi
if [ "$DRY" -eq 1 ]; then
  diff -u --label "$UNIT (installed)" --label "$UNIT (restored)" "$UNIT" "$DEST/unit.before" || true
  echo "dry run: nothing written; would restore the unit and restart jg-sentinel.service"
  exit 0
fi

mkdir -p "$(dirname "$UNIT")"
cp -p "$DEST/unit.before" "$UNIT.tmp-$STAMP" && mv "$UNIT.tmp-$STAMP" "$UNIT"
# Restart, never stop-then-start: the restored unit replaces the installed one in one step.
systemctl --user daemon-reload
systemctl --user restart jg-sentinel.service
rm -rf -- "$DEST"
echo "uninstalled: jg-sentinel.service restored to its pre-install unit and restarted"
