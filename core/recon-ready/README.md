# recon-ready

A Recon that passes its gate raises one alert: its report is ready, with the next items.
The owner of the ticket hears it once, within one watcher sweep.

`ready.sh check <jg-home>` is the watcher check.
`wiring.sh [--dry-run] <jg-home>` installs and registers it; it copies `ready.sh` to `~/.local/share/jg-recon-ready/` and writes the home's check shim.

## What it does

- It reads each `state/<task>.meta` of kind `scout` that has `data/<task>/report.md` and a last status line of `done` or `needs-decision`.
- It runs `bin/jg-recon-gate.sh <task>`. A PASS (a recorded bypass prints one) or an exempt quick Recon counts; a refusal prints nothing and is retried next sweep.
- It prints one wake line: the report path, the first Answer line, the first three rows of section 8 (the next items) and the count of open decisions in section 10.
- It records the report's sha256 in `state/recon-ready/<task>`. The same report is never announced twice; a revised report is a new announcement.

## The owner timer

`core/wait-timers/bin/jg-wait-timers-lib.sh` (`jg_wait_timer_quiet`) treats a Recon with a non-empty `state/recon-ready/<task>` as quiet.
It arms no owner timer, because the alert already told the owner.
A Recon with no record keeps its timer.

## Follow-up stated ahead

A Recon ticket body may carry `on-report: triage-build <harness> <model> <effort>`.
`bin/jg-backlog.sh on-report <ticket>` prints the route only when the ticket rests on one of the three records of the captain's yes (`bin/jg-captain-ask-lib.sh`); a typed line alone is never run.
When the report has passed its gate, no open call blocks the ticket (`bin/jg-captain-hold.sh blocking`) and the report lists no open decision, this check files the first slice of section 8 under the ticket and approves it for dispatch on that route.
`core/auto-dispatch` starts it under the lane target and the quota gates, which stay in force.
`state/on-report/<task>` records the slice, so the follow-up runs once; a held call that clears runs it on the next sweep.
Not yet covered: the slice's brief (`data/<slice>/brief.md`) is still written by the lead, so auto-dispatch names a slice with no brief to the lead.

## Proof and rollback

`tests/jg-recon-ready.test.sh` drives the check and the quiet rule; `tests/jg-on-report.test.sh` drives the follow-up.
Rollback: delete the home's `state/recon-ready.check.sh` through `bin/jg-check-unregister.sh recon-ready`; the records in `state/recon-ready/` are only history.
