#!/usr/bin/env bash
# Compose one closure-proof JSON record from the home's outcome and installation records.
# Usage: jg-closure-proof.sh <ticket>
set -u
[ "$#" -eq 1 ] || { echo 'usage: jg-closure-proof.sh <ticket>' >&2; exit 64; }
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
JG_HOME=${JG_HOME:-$(cd "$DIR/.." && pwd -P)}
export JG_HOME JG_DATA_OVERRIDE="${JG_DATA_OVERRIDE:-$JG_HOME/data}"
exec python3 "$DIR/jg-closure-proof.py" "$1"
