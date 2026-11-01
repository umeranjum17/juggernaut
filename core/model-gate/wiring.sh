#!/usr/bin/env bash
# jg-compat shim (slice S4, deleted by S10): an old FM_* name still resolves
# here, so an unmigrated shell, unit, pane or record keeps this script working.
for _jg_old in $(compgen -v FM_ 2>/dev/null || true); do
  _jg_new="JG_${_jg_old#FM_}"
  declare -p "$_jg_new" >/dev/null 2>&1 && continue
  export "$_jg_new=${!_jg_old}"
done
unset _jg_old _jg_new 2>/dev/null || true
# Install model-gate for one juggernaut home, or take it away with --remove: the gate on PATH, the allow-list, the
# opencode per-provider whitelist (so an off-list model is not even pickable there) and the fleet check that restores
# that whitelist and warns when an off-list model was used anyway. Idempotent; the allow-list file is never overwritten
# and never deleted. Usage: wiring.sh [--dry-run] [--remove]   (JG_HOME names the home that runs the check)
set -euo pipefail
dry=0 remove=0
for a in "$@"; do case $a in --dry-run) dry=1 ;; --remove) remove=1 ;; *) echo 'usage: wiring.sh [--dry-run] [--remove]' >&2; exit 2 ;; esac; done
JG_HOME=${JG_HOME:?set JG_HOME to the juggernaut home that runs the check}
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/jg-model-gate
share=${XDG_DATA_HOME:-$HOME/.local/share}/jg-model-gate
bin=$share/jg-model-gate
link=$HOME/.local/bin/jg-model-gate
list=${JG_MODEL_GATE_LIST:-$JG_HOME/config/model-allow-list.json}
check=$JG_HOME/state/model-gate.check.sh
say() { printf '%s %s\n' "$1" "$2"; }

if [ "$remove" = 1 ]; then
  "$src" opencode --remove
  if [ -e "$check" ] && [ -x "$JG_HOME/bin/jg-check-unregister.sh" ]; then
    [ "$dry" = 1 ] && say would-run "jg-check-unregister.sh model-gate" \
      || env -u JG_STATE_OVERRIDE JG_HOME="$JG_HOME" "$JG_HOME/bin/jg-check-unregister.sh" model-gate || true
  fi
  for f in "$check" "$link"; do
    [ -e "$f" ] || continue
    [ "$f" != "$link" ] || [ "$(readlink -f "$f")" = "$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")" ] || continue
    [ "$dry" = 1 ] && say would-remove "$f" || { rm -f -- "$f"; say removed "$f"; }
  done
  [ ! -d "$share" ] || { [ "$dry" = 1 ] && say would-remove "$share" || { rm -f -- "$bin"; rmdir -- "$share" 2>/dev/null; say removed "$share"; }; }
  say kept "$list"
  exit 0
fi

if [ -e "$bin" ] && cmp -s "$src" "$bin"; then say unchanged "$bin"; else
  [ "$dry" = 1 ] && say would-write "$bin" || { mkdir -p "$share"; install -m 755 "$src" "$bin"; say wrote "$bin"; }
fi
if [ "$(readlink -f "$link" 2>/dev/null)" = "$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")" ]; then say unchanged "$link"; else
  [ "$dry" = 1 ] && say would-link "$link -> $bin" || { mkdir -p "${link%/*}"; ln -sfn "$bin" "$link"; say linked "$link -> $bin"; }
fi
# One owner for the list: this file, seeded once. Then the provider layer, then the check that restores it and reports.
if [ -e "$list" ]; then say unchanged "$list"; else
  [ "$dry" = 1 ] && say would-write "$list" || { mkdir -p "${list%/*}"; printf '{\n  "ollama-cloud": ["deepseek-v4.1-flash"]\n}\n' > "$list"; say wrote "$list"; }
fi
if [ "$dry" = 1 ]; then "$src" opencode --dry-run; else "$src" opencode; fi
if [ "$dry" = 1 ]; then say would-install "$check"; else
  mkdir -p "$JG_HOME/state"
  install -m 700 "$src" "$check"
  say installed "$check"
  [ ! -x "$JG_HOME/bin/jg-check-register.sh" ] || "$JG_HOME/bin/jg-check-register.sh" model-gate
fi
