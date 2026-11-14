#!/usr/bin/env bash
# done-done journey: the outcome ledger. The real bin/jg-outcome-ledger.sh builds the ledger from a fixture home's trunk records, its
# bypass records and its git clone (tests/jg-outcome-ledger.test.sh drives it and saves the rows it printed as ledger.tsv).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
echo "journey run $(git -C "$root" rev-parse HEAD) ${RUN_ID:-run}" > "$out"
bash "$root/tests/jg-outcome-ledger.test.sh" >> "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the real jg-outcome-ledger.sh command in a fixture home with trunk records, bypass records and a git project",
 "steps": ["build the ledger from the fixture records", "show a landing built, landed, in use and released", "show a release that is only raised", "show a bypass and an unverified bypass record", "show a revert and mark the reverted commit", "show a duplicate landing and mark it", "build it again and get the same rows", "remove a source record and see it named with exit 2"],
 "result": "each case shows the right stage and flag, and a missing source record is named on stderr"}
JSON
exit "$rc"
