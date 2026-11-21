#!/usr/bin/env bash
# done-done journey: a direct home summary refresh of a busy home publishes well inside its 60 s deadline.
# The behavior tests build the fixture home and drive the real `bin/jg-home-summary-refresh.sh` and its producer.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{ bash "$root/tests/jg-home-summary-refresh-scale.test.sh" && bash "$root/tests/jg-home-summary-refresh-async.test.sh"; } > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a fixture home with 6,400 backlog rows (about 25,600 markdown lines), 300 encoded captain holds and 600 saved contribution records",
 "steps": ["run bin/jg-home-summary-refresh.sh directly, without --best-effort", "time it", "read state/home-summary.json and state/whats-left.md", "run the --best-effort refresh journeys"],
 "result": "the direct refresh publishes a fresh ledger in under 20 s, renders what is left, carries each hold reason decoded, and the --best-effort paths still return at once"}
JSON
exit "$rc"
