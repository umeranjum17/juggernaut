#!/usr/bin/env bash
# Remove delete-guard's installed adapters, registered check, and Claude hook. Usage: unwiring.sh [--dry-run] <jg-home>
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true

set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: unwiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-delete-guard
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
# Every Claude config folder: ~/.claude and each Claude account folder in the muxr registry the account pool launches
# workers with (CLAUDE_CONFIG_DIR), whose settings.json replaces ~/.claude's. Rerun after adding an account.
REG=${JG_CLAUDE_ACCOUNTS_REGISTRY:-$HOME/.muxr/plans/accounts-v1.json}
CLAUDE_DIRS=$( { echo "$HOME/.claude"; [ ! -e "$REG" ] || jq -r '.accounts[] | select(.provider == "claude") | .folder' "$REG" || echo "warning: cannot read $REG; only ~/.claude is covered" >&2; } | awk '!seen[$0]++')
while read -r d; do
  SETTINGS=$d/settings.json
  if [ -s "$SETTINGS" ] && jq -e '[.hooks.PreToolUse[]?.hooks[]? | (.command // "") | select(contains("jg-delete-guard/guard.mjs"))] | length > 0' "$SETTINGS" >/dev/null; then
    jq '.hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks |= map(select((.command // "") | contains("jg-delete-guard/guard.mjs") | not)) | select(.hooks | length > 0)]) | if .hooks.PreToolUse == [] then del(.hooks.PreToolUse) else . end | if .hooks == {} then del(.hooks) else . end' "$SETTINGS" > "$TMP/settings.json"
    if ! cmp -s "$SETTINGS" "$TMP/settings.json"; then
      echo "update: $SETTINGS"
      if [ "$DRY" -eq 0 ]; then
        stamp=$(date +%s); cp -p "$SETTINGS" "$SETTINGS.bak-delete-guard-$stamp"
        mv "$TMP/settings.json" "$SETTINGS"
      fi
    fi
  fi
done <<<"$CLAUDE_DIRS"
for f in "$HOME/.pi/agent/extensions/jg-rm-guard.ts" "$HOME/.config/opencode/plugins/jg-delete-guard.js" "$FMH/state/delete-guard.check.sh"; do
  [ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
done
if [ -e "$FMH/state/delete-guard.check-trust" ]; then echo "remove: $FMH/state/delete-guard.check-trust"; [ "$DRY" -eq 1 ] || rm -f -- "$FMH/state/delete-guard.check-trust"; fi
if [ -x "$FMH/bin/jg-check-unregister.sh" ]; then [ "$DRY" -eq 1 ] || env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-unregister.sh" delete-guard; fi
for f in guard.mjs check.sh home jg-guard-host; do [ ! -e "$DEST/$f" ] || { echo "remove: $DEST/$f"; [ "$DRY" -eq 1 ] || rm -f -- "$DEST/$f"; }; done
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
