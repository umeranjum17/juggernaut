# lead-sweep

Every watcher beat sweeps the landed lanes of its own home and cleans them up, with no model turn.

`lead-sweep.sh check <jg-home>` is the watcher check.
It prints one line when a lane is cleaned up and one line when a cleanup is refused.

A cleanup can wait minutes for the project's slot lock (`JG_TEARDOWN_LOCK_WAIT`, default 120 seconds per lane), and a check has 30 seconds.
So the check does not sweep itself: it prints the results of finished jobs, starts `lead-sweep.sh job <jg-home>` detached (one at a time per home), and returns.
The job sweeps the lanes oldest done line first and publishes its lines as `data/lead-sweep/results.<time>` for the next beat.
`lead-sweep.sh run <jg-home>` is one sweep in the foreground.

## What is swept

A lane (kind ship or scout) whose latest status line is `done` or `resolved` (an answered lane), and that has landed:

- Ship: its branch head is on the trunk (`state/trunk-tip-<project>`, or the clone's default branch), or its recorded GitHub pull request is merged.
  The forge is asked at most every 10 minutes per lane (`JG_LEAD_SWEEP_PR_MIN`).
- Recon: its report `data/<id>/report.md` exists.

A `resolved` lane that has not landed is left alone and reported once; a `done` lane that has not landed is waiting for its landing and prints nothing.
A lane that is still working, a lead, and a lane a landing is running for are never touched.

## A lane someone waits for is never ended

A lane whose agent someone waits for is live, whatever its last status line says.
The sweep never ends, parks or cleans up such a lane (`jg_fact_lane_waited` in `bin/jg-facts-lib.sh` is the one reader). Someone waits when:

- an unread steer is in the lane's inbox;
- the lane is a Recon whose draft has an open critic round;
- a steer is newer than the lane's last status line (the worker took it and has not reported since);
- the agent is alive and was started again after the lane ended (its exit record is newer than its last status line).

When the agent of such a lane is already dead or missing, the sweep raises the `worker-stopped` alert (P1, first rung Main, `bin/jg-worker-stop-alert.sh`) at once, once per lane.
`bin/jg-control.sh exit` raises the same alert when it ends a waited-for agent, so an end by Main or the delivery tick is never unseen either.
The lane is swept again after the worker answers: its new status line is newer than the steer.

## Other ends of a lane

Each is acted on once and never forced (limits: `JG_LEAD_SWEEP_PARK_H`, `JG_LEAD_SWEEP_PARK_EMPTY_H`, `JG_LEAD_SWEEP_START_MIN`):

- Done, not landed: the agent ends at once (`bin/jg-control.sh <id> exit`). The copy, branch and ticket stay for the landing.
  A done lane with a PASS receipt at its branch head is ended sooner, by the delivery tick (`core/lane-end/stop-at-built.sh`); this sweep is the fallback.
- Parked: a ship lane whose last line is a declared park (`paused ... reason=parked`) has its agent ended and its clean copy given back on the next beat, with no wait. A ship lane whose last line is any other paused, blocked or needs-decision for 24 hours (2 hours when its branch has no commit of its own) has its agent ended and its clean copy given back (`jg-teardown.sh <id> --park`). The branch, ticket and records stay.
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

`bash tests/jg-lead-sweep-end-states.test.sh` runs the end-state journey (resolved lanes); `bash core/lead-sweep/tests/lead-sweep.test.sh` runs the whole journey against a fixture home with real git clones, a recording teardown and a forge stub. `bash tests/jg-teardown-lock-wait.test.sh` runs the lock-wait journey: a held lock, a dead holder and the sweep job.
