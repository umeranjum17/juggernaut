#!/usr/bin/env bash
# done-done journey: the release record is read. The real jg-machine.sh lints the release table, and the behavior test
# (tests/jg-machine-release.test.sh) reads a fixture release in each of its six states through the real observers and runs the
# lander's release-stamp step over real commits with Ticket trailers. The lane table (tests/jg-machine-lane-delivery.test.sh)
# holds 12 states and none of the six release states: the release reads belong to the release observer.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
{
  bash "$root/bin/jg-machine.sh" check release || rc=1
  bash "$root/bin/jg-machine.sh" events release
  bash "$root/tests/jg-machine-release.test.sh" || rc=1
  bash "$root/tests/jg-machine-lane-delivery.test.sh" || rc=1
} > "$out" 2>&1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "the shipped release table and observers, with generated landing rows, release rows and stub pull requests",
 "steps": ["lint the release table", "list its events", "read a fixture release in each of its six states and print the release word and the ticket sub-state", "walk the lane table of 12 states, with no release state", "stamp release_opened_at on tickets found by their Ticket trailer, once each"],
 "result": "open, checking, red and ready read delivering.joining; merged and abandoned do not; each carried ticket is stamped once and a refused ticket never stops the release"}
JSON
exit "$rc"
