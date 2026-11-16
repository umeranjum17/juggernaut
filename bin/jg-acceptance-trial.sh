#!/usr/bin/env bash
# Measure the fleet-throughput acceptance trial (report section 11) from the trial record and the ask records. Reads only.
# Usage: jg-acceptance-trial.sh [--trial <file>] [--now <epoch>] [--json]
# Exit: 0 every criterion this check measures holds, 1 FAIL, 2 PENDING (before the deadline, no bound broken), 64 usage.
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JG_HOME=${JG_HOME:-$(cd "$DIR/.." && pwd -P)}
export JG_HOME JG_DATA_OVERRIDE="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
exec python3 "$DIR/jg-acceptance-trial.py" "$@"
