#!/usr/bin/env bash
# Run the fleet backlog tidy on a real Beads store under done-done and record its steps: the plan changes nothing,
# --apply closes with a reason or defers idle rows, a captain ask is never touched, a second run finds nothing to do.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
bash "$root/core/tickets-sync/tests/tidy.test.sh" > "$evidence/tidy.log" 2>&1
rc=$?
cat "$evidence/tidy.log"
[ "$rc" -eq 0 ] || exit "$rc"
grep -q '^PASS: a second run' "$evidence/tidy.log" || { echo 'FAIL: the tidy test did not reach its last PASS (no Beads store?)' >&2; exit 1; }
# One run may drive several proofs (the tickets-truthful journey): a step record already there gains these steps.
cat > "$evidence/steps.tidy.json" <<JSON
{"target":{"version":"$(git -C "$root" rev-parse HEAD)"},
 "start":"A throwaway home has a real Beads store with seven open rows: two with the same title, one whose PR merged, one landed on the local trunk, one idle for 20 days, one wanted, and one captain ask.",
 "steps":["Run the fleet tidy as a plan and read each row's class and evidence.","Check the plan changed no row.","Run the tidy with --apply.","Check each closed row carries its reason and the idle row is held as parked with its reason.","Check the captain ask and the wanted row are unchanged.","Run the tidy again."],
 "result":"The plan names every row with its evidence, --apply closes or defers only the rows the rules name, the captain ask is untouched and a second run finds nothing to do."}
JSON
if [ -f "$evidence/steps.json" ]; then
  jq -s '.[0] + {start: (.[0].start + " " + .[1].start), steps: (.[0].steps + .[1].steps), result: (.[0].result + " " + .[1].result)}' "$evidence/steps.json" "$evidence/steps.tidy.json" > "$evidence/steps.merged.json"
  mv "$evidence/steps.merged.json" "$evidence/steps.json"
else
  cp "$evidence/steps.tidy.json" "$evidence/steps.json"
fi
rm -f "$evidence/steps.tidy.json"
