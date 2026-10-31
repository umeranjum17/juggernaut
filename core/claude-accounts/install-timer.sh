#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# Install a systemd user timer that runs claude-accounts-quota.sh every 5 minutes for one Juggernaut home, so
# state/claude-accounts.json stays fresh for dispatch. Copies the reader to
# ${XDG_DATA_HOME:-~/.local/share}/jg-claude-accounts/, writes jg-claude-accounts-quota.service and .timer under
# ~/.config/systemd/user/ (the unit carries the installer's PATH so quota-axi and jq resolve), and enables the timer only when a file changed. Reads quota only; touches no login folder.
# Usage: install-timer.sh [--dry-run] <jg-home>      (--dry-run writes nothing)       Undo: uninstall-timer.sh
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: install-timer.sh [--dry-run] <jg-home>" >&2; exit 2; }
HOME_DIR=$(cd "$1" && pwd -P)
SRC=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/bin/claude-accounts-quota.sh
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-claude-accounts/claude-accounts-quota.sh
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
cat > "$TMP/service" <<UNIT
[Unit]
Description=Juggernaut Claude accounts quota reading for $HOME_DIR

[Service]
Type=oneshot
Environment=JG_HOME=$HOME_DIR
Environment=PATH=$PATH
ExecStart=$DEST
UNIT
cat > "$TMP/timer" <<'UNIT'
[Unit]
Description=Read every Claude account's quota every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
changed=0
cmp -s "$SRC" "$DEST" || { echo "$DEST: install from $SRC"; changed=1; }
for u in service timer; do
  cmp -s "$TMP/$u" "$UNITS/jg-claude-accounts-quota.$u" || { echo "$UNITS/jg-claude-accounts-quota.$u:"; sed 's/^/  /' "$TMP/$u"; changed=1; }
done
[ "$changed" -eq 1 ] || { echo "unchanged: jg-claude-accounts-quota.timer"; exit 0; }
[ "$DRY" -eq 0 ] || { echo "dry run: nothing written"; exit 0; }
install -D -m 755 "$SRC" "$DEST"
install -D -m 644 "$TMP/service" "$UNITS/jg-claude-accounts-quota.service"
install -D -m 644 "$TMP/timer" "$UNITS/jg-claude-accounts-quota.timer"
systemctl --user daemon-reload
systemctl --user disable --now fm-claude-accounts-quota.timer >/dev/null 2>&1 || true # a pre-rename timer would read every account twice
systemctl --user enable --now jg-claude-accounts-quota.timer
echo "written and enabled: jg-claude-accounts-quota.timer"
