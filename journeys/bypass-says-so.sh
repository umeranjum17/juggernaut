#!/usr/bin/env bash
# done-done journey: a bypassed change says so wherever it is shown. The behavior test (tests/jg-bypass-says-so.test.sh) runs the real
# pull request check, the real release, the real live-claim check and the board card in a fixture home with a bypassed ticket.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-bypass-says-so.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home with a bypassed ticket, an ordinary ticket and the callers that show a change",
 "steps": ["the pull request of a bypassed ticket gets a green proof status that reads bypassed: no proof ran, with the word id", "a release of three tickets lists the one that was bypassed", "the live-claim check prints not proven: bypassed by the owner for it and for no other ticket", "the board card shows the mark unproved"],
 "result": "a bypassed change is marked in the proof status, the release body, the report and the board; an ordinary ticket and a forged record are not"}
JSON
exit "$rc"
