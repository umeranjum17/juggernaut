#!/usr/bin/env bash
# done-done journey: the ten live fleet checks (tests/live/). tests/jg-live-checks.test.sh runs each check script on a lab home as the
# tick runs it: once green, then with the fault of 12 Nov made in the lab. The journey records that run and its step record.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
RUN=${DONE_DONE_RUN_ID:-live-checks}
bash "$REPO/tests/jg-live-checks.test.sh" > "$OUT/$RUN.log" 2>&1 || { cat "$OUT/$RUN.log"; exit 1; }
cat > "$OUT/steps.json" <<JSON
{"target": {"version": "$(git -C "$REPO" rev-parse --short HEAD)"},
 "start": "a lab home with no fault",
 "steps": ["run each of the ten live checks on the lab home: each prints one PASS row",
           "make the fault of 12 Nov in the lab: a looping gh, a stale lock, a failing model turn, a ticket left beside a free lane, an invalid plan, an unread steer, a loaded host, a stranded release, a landed lane that keeps its agent, a lead home cut off from Main's key",
           "run each check again: each prints one RED row inside its time limit"],
 "result": "$(tail -n 1 "$OUT/$RUN.log")"}
JSON
