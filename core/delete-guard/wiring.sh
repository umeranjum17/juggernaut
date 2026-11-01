#!/usr/bin/env bash
# Install or update the fleet delete guard for this user and register its watcher check in one juggernaut home.
# The decision is the Go guard host at core/guard-host, built here into the install dir; installing needs go on PATH (or JG_GUARD_HOST_GO). guard.mjs is only the JavaScript entry its pi and OpenCode adapters import.
# Idempotent: rerun it to update. Usage: wiring.sh [--dry-run] <jg-home>
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
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-delete-guard
STAMP=$(date +%s)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
# Every Claude config folder: ~/.claude and each Claude account folder in the muxr registry the account pool launches
# workers with (CLAUDE_CONFIG_DIR), whose settings.json replaces ~/.claude's. Rerun after adding an account.
REG=${JG_CLAUDE_ACCOUNTS_REGISTRY:-$HOME/.muxr/plans/accounts-v1.json}
CLAUDE_DIRS=$( { echo "$HOME/.claude"; [ ! -e "$REG" ] || jq -r '.accounts[] | select(.provider == "claude") | .folder' "$REG" || echo "warning: cannot read $REG; only ~/.claude is covered" >&2; } | awk '!seen[$0]++')

# put <target> <candidate> [jq-path]: replace target with candidate after a backup; prints the diff (JSON: only jq-path).
put() {
  local target=$1 new=$2 view=${3:-} old="$TMP/old"
  if [ -e "$target" ] && cmp -s "$target" "$new"; then echo "unchanged: $target"; return; fi
  if [ -n "$view" ]; then
    jq "$view" "$target" > "$old" 2>/dev/null || : > "$old"
    diff -u --label "$target (before) $view" --label "$target (after) $view" "$old" <(jq "$view" "$new") || true
  else
    diff -u --label "$target (before)" --label "$target (after)" "$target" "$new" 2>/dev/null || [ -e "$target" ] || echo "new: $target"
  fi
  [ "$DRY" -eq 0 ] || return 0
  mkdir -p "$(dirname "$target")"
  if [ -e "$target" ]; then cp -p "$target" "$target.bak-delete-guard-$STAMP" && cp -p "$target" "$target.tmp-$STAMP"; fi
  cat "$new" > "$target.tmp-$STAMP" && mv "$target.tmp-$STAMP" "$target"
}

# hook <settings.json> <runtime>: merge one PreToolUse Bash entry, dropping any older guard entry.
# Not Codex: upstream launches Codex operators with hooks off, and a new user hook trips its trust modal.
hook() {
  local file=$1 cmd="node '$DEST/guard.mjs' --runtime $2"
  [ -d "$(dirname "$file")" ] || { echo "skipped: $file (runtime not installed)"; return; }
  # shellcheck disable=SC2016 # $cmd is a jq variable
  { [ -s "$file" ] && cat "$file" || echo '{}'; } | jq --arg cmd "$cmd" '
    .hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks |= map(select((.command // "") | contains("jg-delete-guard/guard.mjs") | not)) | select(.hooks | length > 0)]
      + [{matcher: "Bash", hooks: [{type: "command", command: $cmd, timeout: 10}]}])' > "$TMP/$2.json"
  put "$file" "$TMP/$2.json" .hooks.PreToolUse
}

cp "$SRC/guard.mjs" "$TMP/guard.mjs"
printf '%s\n' "$FMH" > "$TMP/home"
# The decision is the Go guard host's, built here so the installed guard needs no toolchain
# later. A build failure refuses loudly: a guard that cannot run must never be installed.
GO=${JG_GUARD_HOST_GO:-go}
command -v "$GO" >/dev/null 2>&1 || { echo "delete-guard: refused: no Go toolchain on PATH (set JG_GUARD_HOST_GO, or install go); nothing installed. This refusal is final." >&2; exit 1; }
( cd "$SRC/../guard-host" && "$GO" build -o "$TMP/jg-guard-host" ./cmd/jg-guard-host ) || { echo "delete-guard: refused: the guard host did not build; nothing installed" >&2; exit 1; }
for f in guard.mjs home jg-guard-host; do put "$DEST/$f" "$TMP/$f"; done
[ "$DRY" -eq 1 ] || chmod 755 "$DEST/jg-guard-host"
put "$DEST/check.sh" "$SRC/check.sh"
[ "$DRY" -eq 1 ] || chmod 755 "$DEST/check.sh"

for a in pi-extension.ts opencode-plugin.js; do sed "s|__GUARD__|$DEST/guard.mjs|" "$SRC/$a" > "$TMP/$a"; done
if [ -d "$HOME/.pi/agent" ]; then put "$HOME/.pi/agent/extensions/jg-rm-guard.ts" "$TMP/pi-extension.ts"; else echo "skipped: pi (not installed)"; fi
if [ -d "$HOME/.config/opencode" ]; then put "$HOME/.config/opencode/plugins/jg-delete-guard.js" "$TMP/opencode-plugin.js"; else echo "skipped: opencode (not installed)"; fi
while read -r d; do hook "$d/settings.json" claude; done <<<"$CLAUDE_DIRS"

printf '#!/usr/bin/env bash\nexec %q %q\n' "$DEST/check.sh" "$FMH" > "$TMP/check"
put "$FMH/state/delete-guard.check.sh" "$TMP/check"
[ "$DRY" -eq 0 ] || { echo "dry run: nothing written; would run $FMH/bin/jg-check-register.sh delete-guard"; exit 0; }
chmod 700 "$FMH/state/delete-guard.check.sh" && JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" delete-guard
