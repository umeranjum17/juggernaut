#!/usr/bin/env bash
# Feed the scripted board answer to the real keyed intake.
set -euo pipefail
printf '%s\t%s\t%s\n' "$1" "$2" "$2" |
  "$ROOT/bin/jg-captain-hold.sh" answers --source 'Muster acceptance board fixture'
