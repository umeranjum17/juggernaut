#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs are literal
# Keep Claude Code off Fable for every session that reads this config dir's user settings. Sonnet is allowed. Every Fable
# form ends on Haiku or is refused, never on another model:
#   env.ANTHROPIC_DEFAULT_FABLE_MODEL = claude-haiku-5-5
#     the fable alias (--model fable, agent "model: fable") resolves to Haiku;
#   hooks.UserPromptSubmit and hooks.PreToolUse (Agent|Task) run refuse-model.sh
#     a full id such as claude-fable-5-1 (--model, ANTHROPIC_MODEL, settings "model", an Agent call's model) is refused
#     before any request is sent, unless the session's JG_TASK_ID is in allow-tasks (refuse-model.sh owns that list).
# The ban is a host's own choice, not a default: a host that never installed the guard is left alone unless --install
# names it, and a host that did is brought up to date, so jg-host-wiring.sh refreshes an install and never starts one.
# An earlier version also mapped env.ANTHROPIC_DEFAULT_SONNET_MODEL to Haiku; wiring deletes that key when it still
# holds claude-haiku-5-5, so a rewire upgrades an old install.
# refuse-model.sh is copied into the install folder below (--where prints the hook's path there; every other script asks
# it), beside allow-tasks, which is never written or removed here. Settings are edited at key level with a backup; only these keys are printed, never the file,
# other keys, or credentials (never read or touched).
# Not covered: a launch with --setting-sources that leaves out "user"; user settings do not load there at all.
# Usage: wiring.sh [--dry-run] [--install] [--config-dir <dir>]   (default ${CLAUDE_CONFIG_DIR:-~/.claude})
#        wiring.sh --where                                         the installed hook's path
# unwiring.sh removes exactly the guard's keys, hook entries and executable.
set -euo pipefail
DRY=0 INSTALL=0 WHERE=0 DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --install) INSTALL=1 ;;
    --where) WHERE=1 ;;
    --config-dir) DIR=${2:?--config-dir needs a path}; shift ;;
    *) echo "usage: wiring.sh [--dry-run] [--install] [--config-dir <dir>] | --where" >&2; exit 2 ;;
  esac
  shift
done
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/refuse-model.sh
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-claude-model-guard
HOOK=$DEST/refuse-model.sh
[ "$WHERE" -eq 0 ] || { printf '%s\n' "$HOOK"; exit 0; }
if [ "$INSTALL" -eq 0 ] && [ ! -e "$HOOK" ]; then
  echo "not installed: $HOOK (this host runs no Fable ban; wiring.sh --install adds it)"
  exit 0
fi
[ -d "$DIR" ] || { echo "wiring.sh: no Claude config dir at $DIR" >&2; exit 1; }
F=$DIR/settings.json
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
{ [ -s "$F" ] && cat "$F" || echo '{}'; } > "$TMP/old.json"
jq -e 'type == "object"' "$TMP/old.json" >/dev/null || { echo "wiring.sh: $F is not a JSON object; nothing changed" >&2; exit 1; }

drop='map(select(any(.hooks[]?; .command == $c) | not))'
jq --arg h claude-haiku-5-5 --arg c "$HOOK" "
  if .env.ANTHROPIC_DEFAULT_SONNET_MODEL == \$h then del(.env.ANTHROPIC_DEFAULT_SONNET_MODEL) else . end
  | .env.ANTHROPIC_DEFAULT_FABLE_MODEL = \$h
  | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [] | $drop) + [{hooks: [{type: \"command\", command: \$c}]}])
  | .hooks.PreToolUse = ((.hooks.PreToolUse // [] | $drop) + [{matcher: \"Agent|Task\", hooks: [{type: \"command\", command: \$c}]}])" \
  "$TMP/old.json" > "$TMP/new.json"

view='{ANTHROPIC_DEFAULT_SONNET_MODEL: .env.ANTHROPIC_DEFAULT_SONNET_MODEL, ANTHROPIC_DEFAULT_FABLE_MODEL: .env.ANTHROPIC_DEFAULT_FABLE_MODEL,
  guard_hooks: [.hooks // {} | to_entries[] | select(any(.value[]?.hooks[]?; .command == $c)) | .key]}'
hook_ok=1
cmp -s "$SRC" "$HOOK" || hook_ok=0
if [ "$hook_ok" -eq 1 ] && jq -e --slurpfile o "$TMP/old.json" '. == $o[0]' "$TMP/new.json" >/dev/null; then
  echo "unchanged: $F $(jq -c --arg c "$HOOK" "$view" "$TMP/new.json")"
  exit 0
fi
[ "$hook_ok" -eq 1 ] || echo "$HOOK: install from $SRC"
echo "$F: $(jq -c --arg c "$HOOK" "$view" "$TMP/old.json") -> $(jq -c --arg c "$HOOK" "$view" "$TMP/new.json")"
[ "$DRY" -eq 0 ] || { echo "dry run: nothing written"; exit 0; }
[ "$hook_ok" -eq 1 ] || { mkdir -p "$DEST"; install -m 755 "$SRC" "$HOOK"; }
STAMP=$(date +%s)
cp "$TMP/new.json" "$F.tmp-$STAMP"
if [ -e "$F" ]; then
  cp -p "$F" "$F.bak-claude-model-guard-$STAMP" && chmod --reference="$F" "$F.tmp-$STAMP"
  echo "backup: $F.bak-claude-model-guard-$STAMP"
fi
mv "$F.tmp-$STAMP" "$F"
echo "written: $F"
