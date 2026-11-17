# Beads ticket checks

Run `done-done run -- node journeys/tickets-beads-checks.mjs` from the repository root.
Use a registered task TMPDIR outside every Git tree, real Python on PATH, and the pinned installed bd and Dolt (`JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT`).
The journey creates and removes its own isolated HOME, XDG directories, board and real Beads store.
It never installs into a running home or writes to the live fleet.

The journey installs and re-registers sync, stale and cleanup through the supported wiring and registration helpers.
It checks executable permissions, trust hashes and default adapter/store environment.
An actual installed sync check must observe 2,553 unique tickets in less than 20 seconds, excluding fixture setup.
Repeated sync/stale polls must be silent and leave source rows, identities and derived board fields unchanged.
Cleanup must read closed history older than the ordinary seven-day board window, archive a legacy-linked completed question, and preserve active work and owner-gated tickets.

Captures include `registration.json`, `timing.json`, source rows and board projections before/after, command logs, cleanup state, card records and `steps.json`.
Timing describes an isolated real Beads store, not a live fleet measurement.
Screen: none.
