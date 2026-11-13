#!/usr/bin/env bash
# jg status: the ticket, its stage, the wait and the unread steers, then the next step.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
jg_cli_context
statusf=$JG_CLI_STATE/$JG_CLI_TASK.status
last=''; [ -s "$statusf" ] && last=$(tail -n1 "$statusf")
stage=$(JG_CREW_STATE_NO_FORGE=1 timeout 30 "$JG_CLI_TOOLS/bin/jg-crew-state.sh" "$JG_CLI_TASK" 2>&1 | head -n1)
n=$(jg_cli_unread | grep -c .)
case "$last" in paused*|blocked*) wait=$last ;; *) wait=none ;; esac
printf 'ticket: %s · %s · %s · branch %s\n' "$JG_CLI_TASK" "$(jg_cli_meta_get kind)" "$(jg_cli_meta_get mode)" "$(jg_cli_meta_get branch)"
printf 'stage: %s\n' "${stage:-state: unknown}"
printf 'last: %s\n' "${last:-none}"
printf 'wait: %s\n' "$wait"
printf 'inbox: %s unread\n' "$n"
if [ "$n" -gt 0 ]; then echo "Next: jg inbox"
elif [ "$wait" != none ]; then echo "Next: jg progress <text> when the wait clears"
else echo "Next: keep working; jg done when ready"; fi
