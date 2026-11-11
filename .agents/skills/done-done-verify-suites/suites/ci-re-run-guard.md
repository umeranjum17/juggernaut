# CI re-run guard

CI re-run guard: run `done-done run ci-rerun-refusal` (`bash journeys/ci-rerun-refusal.sh`); the real `bin/jg-ci-rerun.sh` over the real backlog and a recorded forge proves a red run is refused with no ticket and with a ticket that has no `root-cause:` line, re-run once the line exists, a green run re-run without a ticket (screen: none).
