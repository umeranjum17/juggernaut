#!/usr/bin/env bash
# inbox.sh - the inbox hook script: the Stop and PostToolBatch dispatchers (bin/jg-hook.sh) run links to it.
# Reads JG_HOOK_EVENT, JG_HOOK_STATE, JG_HOOK_ID. The agent pulls its steering inbox at each turn end and tool
# batch (bin/jg-task-inbox-lib.sh jg_task_inbox_pull): the waiting steers are handed to the agent in the hook's
# own answer, so a steer is read with no doorbell typed into a busy composer. Nothing waiting prints nothing.
#   Stop           {"decision":"block","reason":<text>}  the agent continues its turn with the steers.
#   PostToolBatch  {"hookSpecificOutput":{"hookEventName":"PostToolBatch","additionalContext":<text>}}
set -u
command -v jq >/dev/null 2>&1 || exit 0
root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)
# shellcheck source=bin/jg-task-inbox-lib.sh
. "$root/bin/jg-task-inbox-lib.sh" || exit 1
text=$(jg_task_inbox_pull "$JG_HOOK_STATE" "$JG_HOOK_ID" "$JG_HOOK_EVENT") || exit 0
[ -n "$text" ] || exit 0
case $JG_HOOK_EVENT in
  Stop) jq -nc --arg r "$text" '{decision:"block",reason:$r}' ;;
  PostToolBatch) jq -nc --arg r "$text" '{hookSpecificOutput:{hookEventName:"PostToolBatch",additionalContext:$r}}' ;;
esac
exit 0
