#!/usr/bin/env bash
# Verify owner-guard installation for one Juggernaut home. Usage: doctor.sh <jg-home>
set -euo pipefail
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo 'usage: doctor.sh <jg-home>' >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
GUARD=$DATA/jg-owner-guard/owner-guard
HOOKS=$DATA/jg-owner-guard/hooks
fail=0
if [ ! -x "$GUARD" ]; then
  echo "owner-guard doctor: $FMH is missing executable $GUARD" >&2
  fail=1
fi
CURRENT=$(git config --global --get --type=path core.hooksPath 2>/dev/null || true)
if [ "$CURRENT" != "$HOOKS" ]; then
  if [ -z "$CURRENT" ]; then
    echo "owner-guard doctor: $FMH has unset global core.hooksPath (expected $HOOKS)" >&2
  else
    echo "owner-guard doctor: $FMH global core.hooksPath is $CURRENT (expected $HOOKS)" >&2
  fi
  fail=1
fi
if [ "$fail" -ne 0 ]; then
  echo "recovery: owner-guard/wiring.sh $FMH" >&2
  exit 1
fi
echo "owner-guard doctor: $FMH is installed"
