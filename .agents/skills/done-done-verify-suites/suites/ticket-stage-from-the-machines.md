# Ticket stage from the machines

Ticket stage from the machines: run `done-done run -- bash core/tickets-sync/tests/stage-from-machines.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; real task and delivery observers read generated lane records and a refusal and a revert read rework, finished lanes read ready-to-land, landed lanes read in-homes-off and in-use, an untouched item reads queued, and it fails when a stage word comes from a status verb or a percent (screen: none).
