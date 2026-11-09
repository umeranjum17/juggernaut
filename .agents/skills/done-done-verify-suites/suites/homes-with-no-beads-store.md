# Homes with no Beads store

Homes with no Beads store: run `done-done run -- bash core/tickets-sync/tests/no-store-quiet.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real sync, stale check and clean-up read only the lead home that has a store, raise no wake for Main or a lead with no `config/beads-dir` or a blank one, note each such home once in `state/tickets-sync/progress.log` (again after it loses a store it had), and it fails when a storeless home is read, woken on or noted every pass.
