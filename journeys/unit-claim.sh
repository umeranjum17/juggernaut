#!/usr/bin/env bash
# The machine's four long-running services belong to Main: a session start that
# finds them serving another home claims them, a dead or foreign one is named,
# and a Squad Lead home is refused. One lab user manager, never the real one.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
bash "$root/tests/jg-unit-claim.test.sh" > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a throwaway HOME and a lab systemctl where jg-sentinel, jg-wake-engine, jg-wake-watcher and jg-router are installed, active, and serve another home",
 "steps": ["open a session start in the home whose own copy has those four units and read its HOME ROLE section", "run bin/jg-unit-claim.sh status over a unit that is dead and one that serves another home", "open a Squad Lead home and run bin/jg-stack.sh up and bin/jg-sentinel.sh unit there", "run the same claim from a checkout that is not this home's own copy"],
 "result": "the session's home serves all four units and gets their alerts; a dead or foreign unit is named with no command to run; a Squad Lead home is refused with the reason Main owns them; a foreign checkout changes nothing"}
JSON
exit "$rc"
