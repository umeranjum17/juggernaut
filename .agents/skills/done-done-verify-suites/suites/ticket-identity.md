# Ticket identity

Ticket identity: run `done-done run -- bash core/tickets-sync/tests/ticket-identity.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT` (it needs `JG_BEADS_TEST_BD`, `JG_BEADS_TEST_DOLT` and `JG_TEST_FORK=<checkout>`).
It files migrated rows whose store id is their board ticket, rows of a lead home and a lead's open copy of a main row on real Beads stores, seeds the board as the old sync left it, and runs the installed checks with real sign-off-axi.
One run of main's poll gives every disagreeing ticket of every home its row's state, the stale check goes from six lines to none, no twin ticket appears, a lead's step write reaches its ticket, the lead's poll, stale check and clean-up write nothing, and a refused clean-up card is named by sign-off's refusal rather than its archived-answer warning; it fails on the sync before the fix (screen: none).
