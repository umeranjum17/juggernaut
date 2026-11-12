#!/usr/bin/env bash
# Arm the temp-directory reaper in one juggernaut home: bin/jg-tmp-reaper.sh arm writes the home's
# state/tmp-reaper.check.sh and registers it, so jg-* scratch cannot fill the temp directory. It also arms
# records-reaper (core/tmp-reaper/records.sh check): the files and merged lane branches of a task with no record, and
# proc-reaper (core/tmp-reaper/proc.sh check): the processes that bin/jg-run-owned.sh started and whose limit or owner has ended. Idempotent.
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
  for n in records proc; do echo "would arm: $n-reaper (state/$n-reaper.check.sh runs $SELF_DIR/$n.sh check $FMH)"; done
  exit 0
fi
env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-tmp-reaper.sh" arm
arm_check() {  # <records|proc>: write the home's state/<name>-reaper.check.sh and register it
  local name=$1-reaper shim tmp
  shim=$FMH/state/$name.check.sh
  tmp=$(umask 077; mktemp "$FMH/state/.jg-$name.XXXXXX") || { echo "wiring: cannot write the $1 check" >&2; exit 1; }
  { printf '#!/usr/bin/env bash\nexport JG_HOME=%q\nexec %q check %q\n' "$FMH" "$SELF_DIR/$1.sh" "$FMH" > "$tmp" \
    && chmod 0700 "$tmp" && mv -f -- "$tmp" "$shim"; } || { rm -f -- "$tmp"; echo "wiring: cannot write the $1 check" >&2; exit 1; }
  env -u JG_STATE_OVERRIDE JG_HOME="$FMH" "$FMH/bin/jg-check-register.sh" "$name" >/dev/null || { echo "wiring: cannot register the $1 check" >&2; exit 1; }
  echo "armed: $name"
}
arm_check records
arm_check proc
