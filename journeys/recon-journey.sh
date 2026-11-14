#!/usr/bin/env bash
# done-done journey: a deep Recon goes from its first draft to its cleanup through the real commands (rank 5a proof).
# The behavior test (tests/jg-recon-journey.test.sh) drives bin/jg-brief.sh, bin/jg-recon-handoff.sh, bin/jg-recon-gate.sh and core/lead-sweep/lead-sweep.sh over a throwaway home.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-recon-journey.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway home with a deep Recon: the real scaffold, sources, claims, checks and a 13-section report, no critic yet",
 "steps": ["see the depth gate refuse the report with no critic", "submit the draft, restart, and assign the one separate critic once", "answer with a stale verdict and a verdict from another ticket and see both refused", "record the critic's verdict with gaps, then the researcher's revision", "assign the same critic to the new hash and record its closing verdict", "run the depth gate on the accepted report and on the critic ticket", "relay the draft, leave a steer in the inbox, and run the lead sweep before and after the quiet hour", "see cleanup run once and the report survive"],
 "result": "a stale verdict and an old relay receipt close nothing, a pending steer keeps the Recon, the gate passes the exact accepted hash, the sweep cleans it up once after the quiet hour, and the report is still there"}
JSON
exit "$rc"
