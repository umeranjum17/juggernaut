# Stops without a watcher

Run `done-done run -- bash -c 'set -e; { bash tests/jg-stop-coverage.test.sh; bash tests/jg-stops.test.sh; } > "$(printenv DONE_DONE_EVIDENCE_ROOT)/stops.log" 2>&1'` from the repository root.
The coverage journey checks listed and unlisted alarms, and the fixture drives the delivery tick with a stop, checks its timer, repeat and clear ledger, then kills the stop process during a real fixture landing and checks that the landing completes.
The coverage journey also lists each source waiver and proves that removing it makes the check name the uncovered source.
