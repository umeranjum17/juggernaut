#!/usr/bin/env bash
# done-done journey: a lane with its whole proof lands from a caller whose python3 and node refuse, the way a mise shim does
# when the caller's mise settings point elsewhere ("mise ERROR error parsing config file" refused about ten lanes on
# 10 Nov 2026). The real bin/jg-trunk.sh lands two lanes in a fixture home over real git repositories, its proof check
# running the real core/merge-card receipt: one with an explicit done-done home written with `.` and `..`, one whose sealed
# run sits in the evidence root done-done names relative to the lane (tests/jg-trunk-gate-env.test.sh owns the cases).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
env -u JG_TASK_ID bash "$root/tests/jg-trunk-gate-env.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home with a local-trunk project, and a caller whose python3 and node exit 1 with the mise refusal",
 "steps": ["land a lane from a session whose git hook setting refuses every ref transaction outside the project, and require it green", "give a lane its whole proof (PASS receipt, approved merge-card citing a file, sealed done-done run) with an explicit done-done home, and require the proof check to name no gap and the lane to land from the refusing caller", "give a second lane its whole proof with the sealed run in done-done's lane-relative evidence root, and require the same"],
 "result": "a caller whose mise shims refuse gets the same landing answer as any other: both lanes are on the trunk"}
JSON
exit "$rc"
