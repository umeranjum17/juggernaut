#!/usr/bin/env bash
# The machine bus after a stack up or update: two homes install the service in a lab and both log in, 21 accounts get caps they fit under, and the 384Mb incident config is refused.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${DONE_DONE_EVIDENCE_ROOT:?}/${DONE_DONE_RUN_ID:-run}.log
( bash "$root/tests/jg-bus-machine-service.test.sh"; rc=$?; bash "$root/tests/jg-stack-owner.test.sh" || rc=1; exit "$rc" ) > "$out" 2>&1
rc=$?
cat "$out"
cat > "$DONE_DONE_EVIDENCE_ROOT/steps.json" <<JSON
{"target": {"version": "$(git -C "$root" rev-parse --short HEAD)"},
 "start": "a lab with its own random port, store directory and a stand-in for the user manager; nothing on port 4222",
 "steps": ["run bin/jg-bus.sh install-service for two homes", "run bin/jg-bus.sh ensure as each home", "a home the owner's registry names, keeping no registry of its own, presents that name and round-trips one message while a name the accounts file does not hold is refused", "add a third home and install again", "join a lab home with no registry of its own and then with JG_BUS_HOMES set", "run bin/jg-bus.sh status with every unit active, one unit stopped and the service manager unreachable", "generate the server config for 21 accounts and start a real server on it", "check the 384Mb incident config with bin/jg-bus.sh check-limits", "run bin/jg-stack.sh up as the owner and as a home that does not own the unit"],
 "result": "both homes authenticate and create their stream, a registered home keeping no registry of its own logs in as the name the accounts file holds and the server refuses nothing while a mismatched name is still refused, the third is loaded by one restart, a lab home is refused by the machine's real registry which stays byte-identical while the registry JG_BUS_HOMES names holds it, status reads each service's own unit state (active units up, a stopped unit down alone, an unreachable manager unknown and never down), the 21-account caps are (21+1) x the reservation and the server starts, and the 384Mb config is refused with the shortfall named; the owner installs and starts dapr, ntfy and the consumer, and a non-owner home installs and starts none of them"}
JSON
exit "$rc"
