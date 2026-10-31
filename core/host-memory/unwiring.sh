#!/usr/bin/env bash
# Remove the installed host-memory gate. Usage: unwiring.sh [--dry-run]
set -euo pipefail
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo 'usage: unwiring.sh [--dry-run]' >&2; exit 2; }
f=${XDG_DATA_HOME:-$HOME/.local/share}/jg-host-memory/jg-mem-gate.sh
adopt=${XDG_DATA_HOME:-$HOME/.local/share}/jg-host-memory/jg-heavy-adopt.sh
cpu_state=${XDG_STATE_HOME:-$HOME/.local/state}/jg-host-memory/jg-heavy-adopt.cpu
config=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
reload=0
for unit in jg-heavy-adopt.timer jg-heavy-adopt.service; do
  if [ -e "$config/$unit" ]; then
    echo "remove: $config/$unit"
    if [ "$DRY" -eq 0 ]; then rm -f -- "$config/$unit"; reload=1; fi
  fi
done
if [ "$DRY" -eq 0 ]; then systemctl --user disable --now jg-heavy-adopt.timer >/dev/null 2>&1 || true; fi
[ ! -e "$adopt" ] || { echo "remove: $adopt"; [ "$DRY" -eq 1 ] || rm -f -- "$adopt"; }
[ ! -e "$cpu_state" ] || { echo "remove: $cpu_state"; [ "$DRY" -eq 1 ] || rm -f -- "$cpu_state"; }
[ ! -e "$f" ] || { echo "remove: $f"; [ "$DRY" -eq 1 ] || rm -f -- "$f"; }
for d in "$config/jg.slice.d" "$config/jg-heavy.slice.d"; do
  dropin=$d/50-jg-heavy-weight.conf
  if [ -e "$dropin" ]; then
    echo "remove: $dropin"
    if [ "$DRY" -eq 0 ]; then rm -f -- "$dropin"; reload=1; rmdir "$d" 2>/dev/null || true; fi
  fi
done
if [ "$DRY" -eq 0 ]; then
  rmdir "${f%/*}" 2>/dev/null || true
  [ "$reload" -eq 0 ] || systemctl --user daemon-reload || { echo 'host-memory: systemctl --user daemon-reload failed' >&2; exit 1; }
else echo 'dry run: nothing written'; fi
