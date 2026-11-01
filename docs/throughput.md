# The throughput measurement

A merged pull request spends most of its life between the worker's done line and the merge, and that time is where the fleet loses hours.
The one-off [measurement that found this](../../BACKLOG.md) lived in discarded scratch scripts, so nobody could re-measure it.
`bin/jg-throughput.sh` is that method as code: it attributes every second of the wait to one stage and ranks the stages by hours lost per day, so the worst bottleneck is the first line a reader sees.

This is part A of the analysis: the measurement and the ranking.
Part B files the ticket per ranked stage, posts the captain digest and opens the lead tickets.

## Sources

| Source | What it gives | Written by |
| --- | --- | --- |
| `state/fleet-ledger.jsonl` | the done line, the merge, and the pull request of a task | the fleet ledger, when a home has `config/fleet-ledger` |
| `data/metrics/task-outcomes.tsv` | each task's start, end, outcome and pull request | `bin/jg-task-outcome.sh` at cleanup |
| `<inputs>/prs.json` | each merged pull request's commits and merge time | `jg-throughput.sh fetch` |
| `<inputs>/runs.json`, `<inputs>/jobs.json` | the workflow runs on a pull request's final commit, with each job's queue wait and runtime | `jg-throughput.sh fetch` |

`fetch` is the only command that talks to GitHub, and it writes those dumps once; a re-measure over the same dumps is free and repeatable.
A lab passes `--inputs <dir>` with the same four names and never reaches the forge.

The measurement needs the done line, which is the one fact a home without the ledger may not hold: cleanup deletes the status log.
A merge with no done line is counted as skipped, never measured from a guessed start.

## The stages

Every second between the done line and the merge lands in exactly one stage, so `rework + final CI + green-to-merged + handoff` is the whole wait.

| Stage | From | To | What it means |
| --- | --- | --- | --- |
| `rework` | the done line | the final commit | work redone after the worker said done |
| `queue` | a job's creation | its start | the runner pool's wait, summed over the final commit's jobs |
| `run` | a job's start | its completion | the CI runtime, summed the same way |
| `green_to_merged` | the last green check | the merge | nobody picking the pull request up |
| `handoff` | whatever is left | | time in which no record was running anything |

`queue` and `run` sit inside the final CI window by construction: they are measured as their own bottlenecks, so the stage sums overlap while the phase attribution does not.

## The ranking

`rank` reports, per stage: hours, hours per day over the window, the pull requests it touched, the median and p90 per pull request, the fix the config names, and the owner that fix belongs to.
The window ends at the newest merge the inputs hold, so a replayed dump measures the same window whatever today is.
A stage under `min-hours-per-day` is measured and marked `ranked: false`: a rounding error never becomes a ticket.

`show` prints the same ranking for a reader.

## Operating it

```sh
bin/jg-throughput.sh fetch                 # the two forge dumps into state/.throughput/inputs
bin/jg-throughput.sh measure               # one record per merged pull request
bin/jg-throughput.sh rank [--json]         # the stages by hours lost
bin/jg-throughput.sh show                  # the ranking for a reader
```

Every threshold, every stage and every proposed fix is `defaults/throughput.json`, which a home overrides at `config/throughput.json`.

## The lab

`tests/jg-throughput.test.sh` writes fixtures whose every timestamp it chooses, so each stage's number is known before the tool runs: it proves the phase arithmetic, the job-hours of queue and runtime, the window, the ranking order, the config-driven threshold and the `show` output.

## What it does not do

- It does not guess a done line. A pull request whose done line was lost at cleanup is counted as skipped and reported as such.
- It does not detect a rebase loop on its own: that needs the pull request's force-push timeline, which this part does not fetch, so such rework falls under the same rework stage.
- It does not file anything. Part B owns the ticket, the captain digest and the lead tickets.
