#!/usr/bin/env bash
# Remove claude-model-guard's settings entries and executable; allow-tasks, the captain's own list, stays.
# Usage: unwiring.sh [--dry-run] [--config-dir <dir>]
set -euo pipefail
DRY=0 DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
while [ "$#" -gt 0 ]; do case "$1" in --dry-run) DRY=1 ;; --config-dir) DIR=${2:?--config-dir needs a path}; shift ;; *) echo 'usage: unwiring.sh [--dry-run] [--config-dir <dir>]' >&2; exit 2 ;; esac; shift; done
HOOK=$(bash "$(dirname "${BASH_SOURCE[0]}")/wiring.sh" --where); DEST=${HOOK%/*}
F=$DIR/settings.json; T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
if [ -s "$F" ]; then
  jq --arg h claude-haiku-5-5 --arg c "$HOOK" 'if .env.ANTHROPIC_DEFAULT_SONNET_MODEL == $h then del(.env.ANTHROPIC_DEFAULT_SONNET_MODEL) else . end | if .env.ANTHROPIC_DEFAULT_FABLE_MODEL == $h then del(.env.ANTHROPIC_DEFAULT_FABLE_MODEL) else . end | if .hooks.UserPromptSubmit then .hooks.UserPromptSubmit |= map(select(any(.hooks[]?; .command == $c) | not)) else . end | if .hooks.PreToolUse then .hooks.PreToolUse |= map(select(any(.hooks[]?; .command == $c) | not)) else . end' "$F" > "$T/settings"
  if ! cmp -s "$F" "$T/settings"; then echo "update: $F"; if [ "$DRY" -eq 0 ]; then stamp=$(date +%s); cp -p "$F" "$F.bak-claude-model-guard-$stamp"; mv "$T/settings" "$F"; fi; fi
fi
[ ! -e "$HOOK" ] || { echo "remove: $HOOK"; [ "$DRY" -eq 1 ] || rm -f -- "$HOOK"; }
[ "$DRY" -eq 1 ] || rmdir "$DEST" 2>/dev/null || true
[ "$DRY" -eq 0 ] || echo 'dry run: nothing written'
