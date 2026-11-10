# Lead ticket publication

Run `done-done run -- bash core/tickets-sync/tests/lead-rows-first.test.sh` with `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT` set to the pinned binaries.
The real parent poll reads isolated Beads homes and publishes new lead tickets while older main rows wait, then finishes the older rows.
Run `bash tests/jg-ticket-writeback.test.sh` with the same environment to prove a lead names its parent poll and a board refusal still reports its cause (screen: none).
