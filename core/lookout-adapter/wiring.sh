#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# wiring.sh [--dry-run]: replace the legacy dashboard service with Lookout.
#   (default)    start the new command on a spare port, check it with curl, then stop the old unit and start the new one.
#   --dry-run    print every step and the unit; change nothing.
# The legacy dashboard is removed, so installation cannot roll back to it.
# Settings (environment): JG_HOME (default ~/juggernaut), PORT (default 4390),
# BIND (default: this host's tailnet address), SPARE_PORT (default 4395).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mode=apply
for arg in "$@"; do case $arg in --dry-run) mode=dry ;; *) echo "usage: wiring.sh [--dry-run]" >&2; exit 2 ;; esac; done
JG_HOME=${JG_HOME:-$HOME/juggernaut} PORT=${PORT:-4390} SPARE_PORT=${SPARE_PORT:-4395}
OLD="jg-dashboard.service fm-dashboard.service fm-dashboard-lookout.service" NEW=jg-dashboard-lookout.service
unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
BIND=${BIND:-$(tailscale ip -4 | head -1)}
run() { echo "+ $*"; case $mode in *dry) ;; *) "$@" ;; esac; }
unit() {
  cat <<U
[Unit]
Description=Juggernaut fleet dashboard: Lookout on the adapter (tailnet only)
After=tailscaled.service network-online.target

[Service]
Environment=JG_HOME=$JG_HOME PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$here/fleet-serve --bind $BIND --port $PORT
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=default.target
U
}

echo "== unit $unit_dir/$NEW"; unit
echo "== 1. spare port: the unit's own command on $BIND:$SPARE_PORT, checked before anything is stopped"
probe=jg-dashboard-lookout-probe
run systemd-run --user --collect --unit "$probe" --setenv=JG_HOME="$JG_HOME" "$here/fleet-serve" --bind "$BIND" --port "$SPARE_PORT"
if [ "$mode" = apply ]; then
  trap 'systemctl --user stop "$probe" 2>/dev/null || true' EXIT
  for _ in $(seq 100); do curl -fs "http://$BIND:$SPARE_PORT/api/fleet" -o /dev/null && break; sleep 0.3; done
  curl -fs "http://$BIND:$SPARE_PORT/api/fleet" | python3 -c 'import json, sys; d = json.load(sys.stdin); assert d["fleet"]["lanes"], "no lanes"' || { echo "install: the spare port does not serve the fleet; nothing was changed" >&2; exit 1; }
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$BIND:$SPARE_PORT/tickets")" = 301 ] || { echo "install: /tickets does not redirect to sign-off; nothing was changed" >&2; exit 1; }
  systemctl --user stop "$probe"; trap - EXIT
else
  echo "+ curl http://$BIND:$SPARE_PORT/api/fleet (must list lanes) and /tickets (must answer 301), then stop $probe"
fi
echo "== 2. swap"
if [ "$mode" = apply ]; then mkdir -p "$unit_dir"; unit > "$unit_dir/$NEW"; else echo "+ write $unit_dir/$NEW"; fi
run systemctl --user daemon-reload
# A home never installed under a name has no such unit, and fm-* names are what a pre-rename home still runs on this port.
for old in $OLD; do run systemctl --user disable --now "$old" || true; done
run systemctl --user enable --now "$NEW"
echo "== legacy dashboard rollback is unavailable"
