#!/usr/bin/env bash
# done-done journey: where a new lead home starts (H30e). The real core/lane-scale/place.sh with the real fleet.sh verdict, runner registry and ledger on fixture host signals (tests/jg-lane-place.test.sh).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-lane-place.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a home with an own runner, a second own runner and a paid runner, probed ok, and a host with 4 then 28 of 32 cores busy",
 "steps": ["a host with room keeps the home", "a full host picks the first usable runner with a free core, own machines first", "a paid runner needs the ledger cap", "a private repository goes only to a private_ok runner", "seed starts the home through the remote Squad Lead path"],
 "result": "a new lead home starts on a runner host when this host is full, and a private repository stays on owned machines"}
JSON
exit "$rc"
