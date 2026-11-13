#!/usr/bin/env bash
# jg wait <who> <reason> <text> [--until <YYYY-MM-DDTHH:MMZ>]: declare the one kind of wait.
# The guard refuses a who or reason outside core/machines/ticket-wait*.states.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
usage='usage: jg wait <who> <reason> <job and completion condition> [--until <YYYY-MM-DDTHH:MMZ>]'
[ $# -ge 3 ] || jg_cli_die "$usage"
who=$1 reason=$2; shift 2
text=''
until_at=''
while [ $# -gt 0 ]; do
  case $1 in
    --until) [ $# -ge 2 ] || jg_cli_die "$usage"; until_at=$2; shift 2 ;;
    *) text="${text:+$text }$1"; shift ;;
  esac
done
[ -n "$text" ] || jg_cli_die "$usage"
[ -z "$until_at" ] || text="$text until $until_at"
jg_cli_context
jg_cli_status_append paused "$text" "wait=$who" "reason=$reason" || exit 1
echo "wait declared for $JG_CLI_TASK: $who owes the next move ($reason). Next: end the turn; jg progress when it clears"
