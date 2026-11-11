# A full pool defers a start

Run `done-done run -- bash -c 'bash tests/jg-pool-full.test.sh > "$DONE_DONE_EVIDENCE_ROOT/pool-full.log" 2>&1'` with the pinned Beads test binaries in `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT`.
The real spawn and delivery tick use a simulated full Treehouse pool and a recording cleanup to prove the queued start is deferred, holders are reported, and the unforced sweep is asked to clean a landed lane (screen: none).
