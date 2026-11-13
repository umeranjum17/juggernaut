# Copies follow the lane limit

Run `done-done run -- bash -c 'bash tests/jg-pool-reserve.test.sh > "$DONE_DONE_EVIDENCE_ROOT/pool-reserve.log" 2>&1'` with the pinned Beads test binaries in `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT`.
The real spawn over a fixture home with a lane limit of 2 and a stand-in Treehouse shows that an ordinary lane is deferred once two copies are leased, a red-fix lane may use the two reserved copies and is deferred at the cap of 4, and a home with no lane limit is left to the pool's own limit (screen: none).
