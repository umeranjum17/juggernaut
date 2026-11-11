#!/usr/bin/env bash
# Arm the temp-directory reaper in one juggernaut home: bin/jg-tmp-reaper.sh arm writes the home's
# state/tmp-reaper.check.sh and registers it, so jg-* scratch cannot fill the temp directory. It also arms
# records-reaper (core/tmp-reaper/records.sh check): the files and merged lane branches of a task with no record. Idempotent.
# Usage: wiring.sh [--dry-run] <jg-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/jg-tmp-reaper.sh" ] || { echo "usage: wiring.sh [--dry-run] <jg-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
[ ! -x "$FMH/core/tmp-reaper/records.sh" ] || SELF_DIR=$FMH/core/tmp-reaper  # the home's own copy, so a later update moves the check
if [ "$DRY" -eq 1 ]; then
  echo "would run: env -u JG_STATE_OVERRIDE JG_HOME=$FMH $FMH/bin/jg-tmp-reaper.sh arm"
  echo "would arm: records-reaper (state/records-reaper.check.sh runs $SELF_DIR/records.sh check $FMH)"
  exit 0
fi
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-tmp-reaper.sh" arm
shim=$FMH/state/records-reaper.check.sh
tmp=$(umask 077; mktemp "$FMH/state/.jg-records-reaper.XXXXXX") || { echo "wiring: cannot write the records check" >&2; exit 1; }
{ printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check %q\n' "$FMH" "$SELF_DIR/records.sh" "$FMH" > "$tmp" \
  && chmod 0700 "$tmp" && mv -f -- "$tmp" "$shim"; } || { rm -f -- "$tmp"; echo "wiring: cannot write the records check" >&2; exit 1; }
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" records-reaper >/dev/null || { echo "wiring: cannot register the records check" >&2; exit 1; }
echo "armed: records-reaper"
