# Ticket checks

Run `done-done run -- node journeys/tickets-beads-checks.mjs` with real Python on PATH and a registered task TMPDIR outside every Git tree.
The [feature](../features/tickets-beads-checks.md) describes the isolated real-product journey, registration, 2,553-ticket timing, source preservation, repeat polls and historical cleanup safeguards.
The run captures timing, registration, command logs, source/projection comparisons, resulting cards/state and steps in its sealed evidence directory.

Also run the existing adapter/read and cleanup integration journeys through done-done:
`bash tests/jg-ticket-adapter.test.sh`, `bash tests/jg-beads-read.test.sh`, `bash core/tickets-sync/tests/cleanup-acts.test.sh` and `bash core/tickets-sync/tests/cleanup-keeps-question.test.sh`.
Capture their output under done-done's evidence directory.
