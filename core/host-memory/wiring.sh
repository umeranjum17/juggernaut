#!/usr/bin/env bash
# Install or update the memory gate for this user. Idempotent. Usage: wiring.sh [--dry-run]
# Main's config/jg-mem-gate.sh becomes a shim that execs the installed copy; this script never writes it.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: wiring.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/jg-mem-gate.sh
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/jg-host-memory/jg-mem-gate.sh
ADOPT_SRC=${SRC%/*}/jg-heavy-adopt.sh
ADOPT_DEST=${DEST%/*}/jg-heavy-adopt.sh
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
SERVICE=$CONFIG/jg-heavy-adopt.service
TIMER=$CONFIG/jg-heavy-adopt.timer
if cmp -s "$SRC" "$DEST"; then echo "unchanged: $DEST"
elif [ "$DRY" -eq 1 ]; then echo "would copy: $SRC -> $DEST"
else mkdir -p "${DEST%/*}"; install -m 755 "$SRC" "$DEST"; echo "copied: $SRC -> $DEST"
fi
if [ -f "$ADOPT_SRC" ] && cmp -s "$ADOPT_SRC" "$ADOPT_DEST"; then echo "unchanged: $ADOPT_DEST"
elif [ "$DRY" -eq 1 ]; then echo "would copy: $ADOPT_SRC -> $ADOPT_DEST"
else mkdir -p "${ADOPT_DEST%/*}"; install -m 755 "$ADOPT_SRC" "$ADOPT_DEST"; echo "copied: $ADOPT_SRC -> $ADOPT_DEST"; fi
[ "$DRY" -eq 1 ] || mkdir -p "$CONFIG"
service_content="[Unit]
Description=Move heavy and CPU-intensive pane jobs out of Herdr
[Service]
Type=oneshot
ExecStart=$ADOPT_DEST"
timer_content='[Unit]
Description=Run jg-heavy-adopt every 20 s
[Timer]
OnBootSec=30
OnUnitActiveSec=20
AccuracySec=2
[Install]
WantedBy=timers.target'
for pair in "$SERVICE|$service_content" "$TIMER|$timer_content"; do
  f=${pair%%|*}; content=${pair#*|}
  if [ -f "$f" ] && cmp -s "$f" <(printf '%s\n' "$content"); then echo "unchanged: $f"
  elif [ "$DRY" -eq 1 ]; then echo "would write: $f"
  else printf '%s\n' "$content" >"$f"; echo "wrote: $f"; fi
done
for f in "$CONFIG/jg.slice.d/50-jg-heavy-weight.conf" "$CONFIG/jg-heavy.slice.d/50-jg-heavy-weight.conf"; do
  if [ -f "$f" ] && cmp -s "$f" <(printf '[Slice]\nCPUWeight=20\nIOWeight=20\n'); then echo "unchanged: $f"
  elif [ "$DRY" -eq 1 ]; then echo "would write: $f"
  else mkdir -p "${f%/*}"; printf '[Slice]\nCPUWeight=20\nIOWeight=20\n' >"$f"; echo "wrote: $f"; fi
done
if [ "$DRY" -eq 0 ]; then
  systemctl --user daemon-reload || { echo 'host-memory: systemctl --user daemon-reload failed' >&2; exit 1; }
  systemctl --user disable --now fm-heavy-adopt.timer >/dev/null 2>&1 || true # a pre-rename timer would run the mover twice
  systemctl --user enable --now jg-heavy-adopt.timer || { echo 'host-memory: failed to enable jg-heavy-adopt.timer' >&2; exit 1; }
else echo 'dry run: nothing written'; fi
