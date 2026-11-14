#!/usr/bin/env bash
# done-done journey: a Recon's draft, critic verdict and revision have one owner. The real jg-machine.sh lints the recon table and lists its moves;
# the behavior test (tests/jg-machine-recon.test.sh) drives draft, verdict with gaps, revise and accept through the real bin/jg-recon-handoff.sh
# and shows that a verdict for an older report hash is refused.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
jm="$root/bin/jg-machine.sh"
rc=0
{
  bash "$jm" check recon || rc=1
  bash "$jm" events recon || rc=1
  bash "$root/tests/jg-machine-recon.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway home with a Recon task folder holding a report.md",
 "steps": ["lint the recon table and its enum", "record the draft with the owner script", "answer it with a verdict for an older hash and see it refused", "record a verdict with gaps, then a revision", "record a verdict with no gaps and see the draft accepted"],
 "result": "the table lints with 3 states and 4 moves, the record ends accepted, critic.md holds the gate's Round lines, and a stale verdict closed nothing"}
JSON
exit "$rc"
