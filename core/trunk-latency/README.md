# trunk-latency

Every local-trunk landing gets one row with its measured minutes from the lane's done line to the landing.
A landing over the five-minute target raises one alert that names the stage that held it.

`latency.sh check <jg-home>` is the watcher check, and `bin/jg-trunk.sh` runs it at the end of every landing, so a landing writes its row at once.
The check stays as the backstop that fills rows still missing.
It reads only records that already exist, and it writes `data/trunk-latency.tsv`.

## The row

The check writes one row for each row of `data/trunk-landings.tsv` that has no row yet, keyed by task and commit.

| Field | What it holds | Where it is read |
|---|---|---|
| `task`, `commit`, `landed` | the landing row | `data/trunk-landings.tsv` |
| `ready` (recorded) | the lane's last done epoch, written as `done=<epoch>` on the landing's proofs row while the status file still exists; it is read before the message log | `data/trunk-landing-proofs.tsv` |
| `head` | the lane head that landed | the receipt of the landing's proof row, in full from the landing records |
| `first_done`, `ready` | the first and the last `done [at=<epoch>]` line of the lane, after its previous landing and at or before this one | `state/chat.jsonl`, and `state/<task>.status` while it exists |
| `gate_start` | the start of the worker's first sealed done-done run at the head | `data/<task>/.done-done/runs/*.json` |
| `launch` | the start of the landing that landed it | `data/jg-trunk-landing/<task>.<head>.launch-*.log`, or `batch.launch-*.log` for a stack |
| `minutes` | `ready` to `landed`, rounded | |
| `stage`, `gate_secs` | the stage that held the most seconds, and the gate's seconds | `data/trunk-landing-proofs.tsv` |
| `load` | the one-minute host load, for a landing at most 10 minutes old | `/proc/loadavg` |
| `queue_secs`, `landing_secs` | the seconds of the queue and of the landing step (start lock, rebase, admission); with `gate_secs` they are the seconds of each step. Both are empty when the landing start is not on record | `ready`, `launch`, `landed` and `gate_secs` above |
| `queue_why` | why the lane waited: `behind <lane>`, `behind attempt of <lane>`, `slot full`, `verify running`, `host load`, `first seen +N s`, or `not recorded` for a queue row the lander wrote no reason for | `data/jg-trunk-landing/<task>.<head>.queue-why`, written by `core/trunk-landing/queue-why.sh` at the landing start |

`ready` and `minutes` are the numbers of table T of the plan's `measure.py`, so both readers give one number for one landing.
A landed lane's status file is removed at cleanup, so the done lines come from the message log.
A landing with no done line on record gets a row with an empty `ready`: it is counted, not dropped.

`gate_start` is the first record of a test run bound to the head.
The light gate a worker runs before it writes no record, so the coding-done clock starts at the sealed run.

The stages:

- `queue`: from the done line to the landing start. The row and the alert name the reason: another lane's landing ended in that window (`behind <lane>`), another lane's attempt ended refused (`behind attempt of <lane>`), or nothing was ahead and the lander first saw the lane more than 60 s after its done line (`first seen +N s`).
- `landing`: from the start to the gate (start lock, rebase, admission).
- `gate`: the lint and the changed tests.
- `before-gate`: the landing start is not on record, so the time before the gate is not split.

## The alert

A landing over `JG_MERGE_LATENCY_LIMIT_MINUTES` (default 5, the limit `core/merge-on-green` reads too) prints one line, which becomes a check wake.
The line names the minutes, the stage and that stage's minutes.

A landing more than an hour old when its row is written gets no alert.
That happens on the first run in a home and after the check was off; the run prints one line that counts those rows and how many were over the limit.

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check, writes the shim `state/trunk-latency.check.sh`, and registers it with `bin/jg-check-register.sh`.
`unwiring.sh [--dry-run] <jg-home>` unregisters it and removes the installed command; the rows stay.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`latency.sh lint <jg-home> [<since epoch>]` exits 1 and names each queue row whose reason is empty or `not recorded`; `bash tests/jg-trunk-queue-why.test.sh` drives the real lander to a `slot full` row and proves the lint and the header migration.

`bash tests/jg-trunk-latency.test.sh` replays the landings of 9 and 10 Nov against a fixture home.
