# trunk-latency

Every local-trunk landing keeps its measured minutes from the lane's done line to the landing on its ticket.
A landing over the five-minute target raises one alert that names the stage that held it.

## The timing

`latency.sh measure <jg-home> <task> <commit>` prints one landing's timing as a JSON object, and `bin/jg-trunk.sh` puts it in the payload of the ticket's `land` event (`jg-backlog.sh trace record ... --payload`) at the end of every landing.
The ticket's row holds the two times, `ready_at` and `landed_at`; the event's payload holds the rest.
Nothing is written to `data/trunk-latency.tsv` any more; the rows already there stay on disk, unread. `ledger-rows.sh <home> [<since> [<until>]]` turns the ledger's landings back into rows of the old columns, and the goal meter, the bottlenecks report and the landing-release feed read those rows; the `land` payload carries the lane head for them.

| Payload key | What it holds | Where it is measured from |
|---|---|---|
| `trunk` | the trunk branch | the lander |
| `ready` | the lane's last done epoch | `done=<epoch>` on the landing's row of `data/trunk-landing-proofs.tsv`, written while the status file still exists; else the lane's last `done [at=<epoch>]` line in `state/chat.jsonl` or `state/<task>.status` |
| `stage`, `gate_s` | the stage that held the most seconds, and the gate's seconds | `data/trunk-landing-proofs.tsv` |
| `queue_s`, `landing_s` | the seconds of the queue and of the landing step (start lock, rebase, admission); with `gate_s` they add up to the seconds from ready to landed. Both are null when the landing start is not on record | `ready`, the landing start and the landing row |
| `queue_why` | why the lane waited: `behind <lane>`, `behind attempt of <lane>`, `slot full`, `verify running`, `host load`, `first seen +N s`, or `not recorded` for a queue stage the lander wrote no reason for | `data/jg-trunk-landing/<task>.<head>.queue-why`, written by `core/trunk-landing/queue-why.sh` at the landing start |
| `load` | the one-minute host load, for a landing at most 10 minutes old | `/proc/loadavg` |

The landing start is `data/jg-trunk-landing/<task>.<head>.launch-*.log`, or `batch.launch-*.log` for a stack.

The stages:

- `queue`: from the done line to the landing start. The payload names the reason: another lane's landing ended in that window (`behind <lane>`), another lane's attempt ended refused (`behind attempt of <lane>`), or nothing was ahead and the lander first saw the lane more than 60 s after its done line (`first seen +N s`).
- `landing`: from the start to the gate (start lock, rebase, admission).
- `gate`: the lint and the changed tests.
- `before-gate`: the landing start is not on record, so the time before the gate is not split.

## The alert

`latency.sh check <jg-home>` is the watcher check, and `bin/jg-trunk.sh` runs it at the end of every landing.
For each landing of the last hour that it has not read, it reads the ticket's `ready_at` and the `land` event of that commit (`jg-backlog.sh trace landing <task> <commit>`).
A landing whose event is not there yet is read again on the next run.
A landing over `JG_MERGE_LATENCY_LIMIT_MINUTES` (default 5, the limit `core/merge-on-green` reads too) raises one `slow-delivery` alert through `bin/jg-alert.sh`.
Its note names the minutes, the stage from the payload and that stage's minutes.
A landing more than an hour old is not read.

## The summary

`latency.sh summary --tsv <file> [--from <epoch> --to <epoch>] [--stall-gap 1800]` reads a latency tsv (the old `data/trunk-latency.tsv` columns, or the rows `ledger-rows.sh` prints) and writes nothing.
It prints the landings in the window, the median and p90 minutes from ready and from the first done line to the landing, the re-done lanes (ready later than the first done line) by UTC day with the five largest, and the stall line: the gaps of `--stall-gap` seconds or more between landings that two or more lanes waited through, with their lane-hours and share of all waiting lane-hours. It needs `gawk` for the UTC day.

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check, writes the shim `state/trunk-latency.check.sh`, and registers it with `bin/jg-check-register.sh`.
`unwiring.sh [--dry-run] <jg-home>` unregisters it and removes the installed command; the rows stay.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`bash tests/jg-trunk-latency.test.sh` replays the landings of 9 and 10 Nov against a fixture home with a real Beads store: it records each landing as the ticket's `land` event, and proves the one alert, the limit, the late and the old landing, the wiring, and that no tsv is written.
`bash tests/jg-trunk-queue-why.test.sh` drives the real lander to a `slot full` wait and reads it from the measured timing.
