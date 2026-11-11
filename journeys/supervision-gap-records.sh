#!/usr/bin/env bash
# Drive the sentinel and watcher journey and bind its output to this run.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/supervision-gap.log
bash "$root/journeys/supervision-gap-integration.sh" > "$out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ -n "${JG_GAP_REPLAY_FILE:-}" ]; then
  set -o pipefail
  if ! JG_HOME="${JG_GAP_REPLAY_HOME:?}" bash "$root/bin/jg-supervision-gap.sh" replay < "$JG_GAP_REPLAY_FILE" |
    awk '/class=unknown-historical/ {n++} END {printf "retained historical replay: %d rows classified unknown-historical\n", n; exit (n != NR || NR == 0)}' >> "$out"; then rc=1; fi
fi
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target":{"version":"$(git -C "$root" rev-parse --short HEAD)"},"start":"isolated homes with stale beats and real watcher and arm processes","steps":["run sentinel with no watcher","hold a real watcher in a check and observe its progress","simulate the child deadline passing","follow a watcher with a real arm then end the watcher","attach an arm and suspend it while its watcher exits","replay 80 historical rows"],"result":"the sentinel records the observed gap class, closes it on recovery, and preserves unknown historical causes"}
JSON
exit "$rc"
