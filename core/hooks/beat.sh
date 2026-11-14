#!/usr/bin/env bash
# beat.sh - the beat hook script: every event dispatcher bin/jg-hook.sh runs links to it.
# Reads JG_HOOK_EVENT, JG_HOOK_STATE, JG_HOOK_ID, JG_HOOK_PAYLOAD; writes the beat line, then
# refreshes the lease of the task's ticket (best effort: a task with no claim has no lease).
set -u
root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)
err=
if [ "$JG_HOOK_EVENT" = StopFailure ] && command -v jq >/dev/null 2>&1; then
  err=$(printf '%s' "${JG_HOOK_PAYLOAD-}" | jq -r '.error // .error_type // "unknown"' 2>/dev/null) || err=unknown
  [ -n "$err" ] || err=unknown
fi
"$root/bin/jg-beat.sh" append "$JG_HOOK_STATE" "$JG_HOOK_ID" "$JG_HOOK_EVENT" ${err:+"$err"} || exit 1

home=$(dirname "$JG_HOOK_STATE")
ticket=$(sed -n 's/^ticket=//p' "$JG_HOOK_STATE/$JG_HOOK_ID.meta" 2>/dev/null | head -n 1)
store=$(tr -d '[:space:]' <"$home/config/beads-dir" 2>/dev/null)
if [ -n "$ticket" ] && [ -n "$store" ] && [ "$JG_HOOK_EVENT" != SessionEnd ]; then
  BEADS_DIR=$store timeout 5 "$root/bin/jg-beads.sh" heartbeat "$ticket" >/dev/null 2>&1 || true
fi
exit 0
