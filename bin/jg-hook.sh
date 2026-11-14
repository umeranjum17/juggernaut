#!/usr/bin/env bash
# jg-hook.sh - the one hook dispatcher for a spawned Claude agent.
#
# Usage: jg-hook.sh <event> <state-dir> <task-id>      (the hook payload arrives on stdin)
#
# bin/jg-spawn.sh wires this once for each Claude Code event it names. The dispatcher runs every
# executable script of core/hooks/<event>.d/ in name order with JG_HOOK_EVENT, JG_HOOK_STATE,
# JG_HOOK_ID and JG_HOOK_PAYLOAD set. A script that fails is reported on stderr and never stops the
# next one. It always exits 0, because a hook must never break the agent's own lifecycle.
# The beat script is the first user: it writes state/beats/<task-id> (bin/jg-beat.sh).
set -u
[ $# -eq 3 ] || { sed -n '2,10p' "$0" >&2; exit 0; }
event=$1 state=$2 id=$3
case $event in ''|*[!A-Za-z0-9]*) exit 0 ;; esac
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
payload=
[ -t 0 ] || payload=$(cat 2>/dev/null) || payload=
export JG_HOOK_EVENT=$event JG_HOOK_STATE=$state JG_HOOK_ID=$id JG_HOOK_PAYLOAD=$payload
for s in "$root/core/hooks/$event.d"/*; do
  [ -x "$s" ] || continue
  "$s" || echo "jg-hook: $event: ${s##*/} failed" >&2
done
exit 0
