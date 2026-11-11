#!/usr/bin/env bash
# Wire the fleet report into a home: write the home's state/fleet-report.check.sh as a one-line shim that runs
# `fleet-report.sh <home> tick` from the home's own core/ (so a fast-forward of the home updates it), and register
# the fleet-report check with the home's bin/jg-check-register.sh. The tick records alerts and the goal-meter row
# and posts the cards, and prints nothing unless a post fails. Idempotent; the old shim is kept as .bak-fleet-report-<stamp>.
# Usage: wiring.sh [--dry-run]  (JG_HOME must name the home that runs it)
set -euo pipefail
dry=0
[ "${1:-}" = --dry-run ] && dry=1
JG_HOME=${JG_HOME:?set JG_HOME to the juggernaut home that runs the check}
tick=$JG_HOME/core/fleet-report/bin/fleet-report.sh
check=$JG_HOME/state/fleet-report.check.sh
shim=$(printf '#!/usr/bin/env bash\nexec bash %q %q tick\n' "$tick" "$JG_HOME")
if [ "$dry" = 1 ]; then
  echo "dry-run: would write $check as a shim to $tick (mode 700) and register the fleet-report check"
  exit 0
fi
[ -f "$tick" ] || { echo "fleet-report wiring: $tick is missing" >&2; exit 1; }
mkdir -p "$JG_HOME/state"
if [ "$(cat "$check" 2>/dev/null)" != "$shim" ]; then
  bak=$check.bak-fleet-report-$(date +%s)
  [ ! -e "$check" ] || { cp -p "$check" "$bak"; echo "backup: $bak"; }
  printf '%s\n' "$shim" > "$check"
fi
chmod 700 "$check"
if [ -x "$JG_HOME/bin/jg-check-register.sh" ]; then
  env -u JG_STATE_OVERRIDE "$JG_HOME/bin/jg-check-register.sh" fleet-report
fi
echo "registered fleet-report: $check runs $tick tick"
