#!/usr/bin/env bash
# done-done journey: lanes spread over more machines under one core budget. The real core/lane-scale/fleet.sh `place` reads fixture process
# lists of the host and of the machines through an ssh stand-in (tests/jg-lane-scale-machines.test.sh), up to 120 machines in one round.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${RUN_ID:-run}.log
rc=0
bash "$root/tests/jg-lane-scale-machines.test.sh" > "$out" 2>&1 || rc=1
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a home with a list of machines and fixture process lists for the host and each machine",
 "steps": ["host has room: it gets the lane", "host full: the machine with most headroom gets it", "a machine that cannot be read is named and skipped", "every machine full: stop", "120 machines are read in one round"],
 "result": "place names the right machine in each case, never guesses an unread one, and reads 120 machines inside one round"}
JSON
exit "$rc"
