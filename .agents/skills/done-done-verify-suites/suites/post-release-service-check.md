# Post-release service check

Post-release service check: run `done-done run live-services` (`bash journeys/live-services.sh`, which runs `tests/jg-live-claim.test.sh`); fake probes take dapr down and the check exits 1 naming them, a recorded `live:` claim is rewritten as merged-not-released, and with all up it stands. The transcript ends with the real `bin/jg-live-services.sh` on this machine: one UP/DOWN line per service with pid or unit status, and the wake engine and router named as not in the design (screen: none).
