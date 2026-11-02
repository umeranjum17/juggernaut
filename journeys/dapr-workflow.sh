#!/usr/bin/env bash
# The wait ladder as a Dapr workflow: a real scheduler, sidecar and worker in a throwaway home, a workflow instance that fires its rungs on real timers, and the owner's clear that stops one.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
bash "$root/tests/jg-dapr-workflow.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway home with free ports, a private tool prefix and no service installed",
 "steps": ["run bin/jg-dapr-workflow.sh up", "start a wait episode with a 2s owner timer and a 4s escalation timer", "read the episode until both rungs fired and read the wake queue", "clear a second episode before its timer", "run bin/jg-dapr-workflow.sh install against a stub service manager"],
 "result": "the owner rung fires no earlier than 2s and the escalation to Main no earlier than 4s, each queued as one wake; the cleared episode completes and delivers nothing; the install writes the detached argv as units and refuses another home's units"}
JSON
exit "$rc"
