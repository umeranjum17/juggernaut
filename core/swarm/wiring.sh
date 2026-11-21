#!/usr/bin/env bash
# Install or update the swarm watcher check in one juggernaut home. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
# Writes the home's state/swarm.check.sh (mode 700): it runs the home's bin/jg-swarm-words.sh, then execs its
# bin/jg-swarm-check.sh check. Registers the check with the home's bin/jg-check-register.sh; a registration the
# register script refuses puts the old shim back.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-check-register.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SHIM=$FMH/state/swarm.check.sh
TEXT=$(printf '#!/usr/bin/env bash\n%q %q\nexec %q check %q\n' "$FMH/bin/jg-swarm-words.sh" "$FMH" "$FMH/bin/jg-swarm-check.sh" "$FMH")
[ -d "$FMH/state" ] && [ ! -L "$FMH/state" ] || { echo "swarm: refused: $FMH has no state directory" >&2; exit 1; }
if [ -L "$SHIM" ] || { [ -e "$SHIM" ] && [ ! -f "$SHIM" ]; }; then
  echo "swarm: refused: $SHIM is not a regular file; move it aside and run this again" >&2; exit 1
fi
if [ "$DRY" -eq 1 ]; then
  printf 'would write: %s:\n%s\n' "$SHIM" "$TEXT" | sed '2,$s/^/  /'
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-check-register.sh swarm"
  echo "dry run: nothing written"
  exit 0
fi
backup=''
[ ! -f "$SHIM" ] || { backup=$(mktemp "$FMH/state/.jg-swarm.XXXXXX"); cp -p "$SHIM" "$backup"; }
trap '[ -z "$backup" ] || rm -f -- "$backup"' EXIT
printf '%s\n' "$TEXT" > "$SHIM"
chmod 700 "$SHIM"
if ! env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" swarm; then
  if [ -n "$backup" ]; then cp -p "$backup" "$SHIM"; else rm -f -- "$SHIM"; fi
  echo "swarm: refused: the check could not be registered; the home's previous wiring is back" >&2; exit 1
fi
echo "swarm: wired $FMH"
