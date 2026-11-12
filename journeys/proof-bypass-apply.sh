#!/usr/bin/env bash
# done-done journey: a ticket under the owner's bypass is passed over proving. The behavior test (tests/jg-proof-bypass-apply.test.sh)
# runs the real delivery tick, the real bypass apply step, the real jg-trunk.sh proof gate and the real landing check in a fixture home.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-proof-bypass-apply.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the real delivery tick, bypass apply step, proof gate and landing check in a fixture home with a standing bypass",
 "steps": ["a lane that reports done under a bypass gets the move bypass, bypassed_at and a record for its exact commit, with no done-done run", "the landing takes the record and the lane lands", "a lane outside the scope, a ended bypass and a forged record are proved as before", "a rebase writes the record again for the new commit", "the worker's done is accepted only while a bypass stands"],
 "result": "the bypassed lane lands with a record naming commit, scope and word; every lane outside the bypass is still refused for missing proof"}
JSON
exit "$rc"
