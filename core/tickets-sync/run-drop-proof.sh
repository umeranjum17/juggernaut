#!/usr/bin/env bash
# Run the pre-Beads drop on a real Beads store under done-done: the plan changes nothing, --apply closes each earlier row with
# the captain's note, owner decisions stay open, a second run finds nothing to drop.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
bash "$root/core/tickets-sync/tests/drop.test.sh" > "$evidence/drop.log" 2>&1
rc=$?
cat "$evidence/drop.log"
[ "$rc" -eq 0 ] || exit "$rc"
grep -q '^PASS: a second run' "$evidence/drop.log" || { echo 'FAIL: the drop test did not reach its last PASS (no Beads store?)' >&2; exit 1; }
cat > "$evidence/steps.json" <<JSON
{"target":{"version":"$(git -C "$root" rev-parse HEAD)"},
 "start":"A throwaway home has a real Beads store with four open rows (two plain, an owner ask, a captain hold) and a board with two tickets no row answers to (one plain, one asked by the captain).",
 "steps":["Run the drop as a plan for a date after every row and read the counts.","Check the plan changed no row.","Run the drop for today's date and check no row counts as earlier.","Run the drop with --apply.","Check each earlier row carries the note and the board-only ticket is done.","Check the owner ask, the captain hold and the asked board ticket are unchanged.","Run the drop again."],
 "result":"The plan counts every open ticket and changes none, --apply closes only the plain rows and the plain board ticket with the captain's note, owner decisions stay open, and a second run finds nothing to drop."}
JSON
