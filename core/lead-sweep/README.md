# lead-sweep

Every watcher beat sweeps the landed lanes of its own home and cleans them up, with no model turn.

`lead-sweep.sh check <jg-home>` is the watcher check.
It prints one line when a lane is cleaned up and one line when a cleanup is refused.

## What is swept

A lane (kind ship or scout) whose latest status line is `done` or `resolved` (an answered lane), and that has landed:

- Ship: its branch head is on the trunk (`state/trunk-tip-<project>`, or the clone's default branch), or its recorded GitHub pull request is merged.
  The forge is asked at most every 10 minutes per lane (`JG_LEAD_SWEEP_PR_MIN`).
- Recon: its report `data/<id>/report.md` exists.

A `resolved` lane that has not landed is left alone and reported once; a `done` lane that has not landed is waiting for its landing and prints nothing.
A lane that is still working, a lead, and a lane a landing is running for are never touched.

## Other ends of a lane

Each is acted on once and never forced (limits: `JG_LEAD_SWEEP_PARK_H`, `JG_LEAD_SWEEP_PARK_EMPTY_H`, `JG_LEAD_SWEEP_START_MIN`):

- Done, not landed: the agent ends at once (`bin/jg-control.sh <id> exit`). The copy, branch and ticket stay for the landing.
  A done lane with a PASS receipt at its branch head is ended sooner, by the delivery tick (`core/lane-end/stop-at-built.sh`); this sweep is the fallback.
- Parked: a ship lane whose last line is paused, blocked or needs-decision for 24 hours (2 hours when its branch has no commit of its own) has its agent ended and its clean copy given back (`jg-teardown.sh <id> --park`). The branch, ticket and records stay.
- Never started: a ship lane with no status line 30 minutes after its record was written is relaunched once with a note, then parked if it still has none.
- Agent gone: a lane whose agent is dead or missing, whatever its last line, is cleaned up once its work has landed.

A step that fails prints one alert per lane and reason, like a refused cleanup.

## Cleanup

The sweep runs `bin/jg-teardown.sh <id>` and never passes `--force`.
The teardown owns the landed-work test and every gate, so a lane with unlanded work, or a Recon whose report, captain-call inventory or depth gate fails, is refused and stays.
A refusal is kept in `data/lead-sweep/<id>.reported` and printed once; the same reason on the next beat prints nothing, and a new reason prints again.

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check, writes the shim `state/lead-sweep.check.sh`, and registers it with `bin/jg-check-register.sh`.
`unwiring.sh [--dry-run] <jg-home>` unregisters it and removes the installed command; that is the rollback.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`bash tests/jg-lead-sweep-end-states.test.sh` runs the end-state journey (resolved lanes); `bash core/lead-sweep/tests/lead-sweep.test.sh` runs the whole journey against a fixture home with real git clones, a recording teardown and a forge stub.
