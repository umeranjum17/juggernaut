#!/usr/bin/env bash
# quality.sh - the quality reader: a table of repeated `done`, first-check proof, brief size
# and notification volume for one window, from the records a home already keeps.
#
# Usage: quality.sh [--home <dir>] [--since <time>] [--until <time>] [--routing <file>]
#   <time> is epoch seconds or an ISO time ending in Z. The default window is the day before --until,
#   and --until is now. --home defaults to $JG_HOME.
#
# Read-only: it writes nothing. Exit 0 when it printed; 2 on bad input. README.md owns each measure.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
command -v python3 >/dev/null 2>&1 || { echo "quality.sh: python3 is not installed" >&2; exit 2; }
exec python3 -B "$here/quality.py" "$@"
