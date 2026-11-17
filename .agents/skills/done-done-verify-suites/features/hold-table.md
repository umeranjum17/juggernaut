# Hold table: owner questions, expiry reconciliation, and call cap

Source: `.done-done.yaml`, `journeys/hold-table.mjs`.

## Drive and capture

Run `done-done run hold-table`.
The committed script drives the app, checks the result and writes captures and steps.json into $DONE_DONE_EVIDENCE_ROOT.

## Checks

Run bash journeys/hold-table.sh unchanged and require success, preserving all five existing checks and the four-state, six-edge hold machine.
Assert the plain Captain order has no gate and no board row, while a real design-pick question has a generated ID, UTC expiry, open unanswered state, and Waiting for you row.
At simulated expiry assert the exact reconciliation message and real request file, then a silent repeat with unchanged request and gate.
With two real questions and cap 1 assert the exact cap message, real alert latch, and no repeated cap alert.
Both questions must remain open, unanswered, and visible on the final board.
Save actual command outputs, file snapshots, commit version, and steps.json under DONE_DONE_EVIDENCE_ROOT; fixture cleanup uses the existing library exit trap.
