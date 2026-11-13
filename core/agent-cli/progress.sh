#!/usr/bin/env bash
# jg progress <text>: a beat of work that wakes nobody (status word `progress`).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -gt 0 ] || jg_cli_die "usage: jg progress <what is true now>"
jg_cli_context
jg_cli_status_append progress "$*" || exit 1
echo "progress recorded for $JG_CLI_TASK. Next: keep working; jg done when ready"
