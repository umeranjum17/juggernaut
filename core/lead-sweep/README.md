# lead-sweep

Every watcher beat sweeps the landed lanes of its own home and cleans them up, with no model turn.

`lead-sweep.sh check <jg-home>` is the watcher check.
It prints one line when a lane is cleaned up and one line when a cleanup is refused.

## What is swept

A lane (kind ship or scout) whose latest status line is `done`, and that has landed:

- Ship: its branch head is on the trunk (`state/trunk-tip-<project>`, or the clone's default branch), or its recorded GitHub pull request is merged.
  The forge is asked at most every 10 minutes per lane (`JG_LEAD_SWEEP_PR_MIN`).
- Recon: its report `data/<id>/report.md` exists.

A lane that is still working, a lead, and a lane a landing is running for are never touched.

## Cleanup

The sweep runs `bin/jg-teardown.sh <id>` and never passes `--force`.
The teardown owns the landed-work test and every gate, so a lane with unlanded work, or a Recon whose report, captain-call inventory or depth gate fails, is refused and stays.
A refusal is kept in `data/lead-sweep/<id>.reported` and printed once; the same reason on the next beat prints nothing, and a new reason prints again.

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check, writes the shim `state/lead-sweep.check.sh`, and registers it with `bin/jg-check-register.sh`.
`unwiring.sh [--dry-run] <jg-home>` unregisters it and removes the installed command; that is the rollback.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`bash lead-sweep/tests/lead-sweep.test.sh` runs the whole journey against a fixture home with real git clones, a recording teardown and a forge stub.
