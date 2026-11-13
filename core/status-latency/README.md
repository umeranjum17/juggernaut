# status-latency

A status line reaches the owner of its lane within a minute.
The check measures the delay from the line to the wake, and raises one alert when it passes two minutes.

The owner is the home that holds the lane: a lead's home for a lead's lane, Main's home otherwise.
`latency.sh check <jg-home>` is the watcher check.
It reads only records that already exist and writes `data/status-latency.tsv`.

## The row

For the newest `done`, `failed`, `blocked` or `needs-decision` line of each live lane, the check writes one row.

| Field | What it holds | Where it is read |
|---|---|---|
| `task`, `line_at`, `word` | the lane, the `[at=<epoch>]` stamp of the line, its first word | `state/<task>.status` |
| `woke_at` | the first wake the watcher raised for that status file at or after the line; empty when none came | `data/wake-ledger.tsv` (kind `signal`) |
| `seconds` | `woke_at` minus `line_at`; empty when no wake came | |

A line with no wake and under the limit is looked at again on the next tick.
A line more than an hour old the first time it is seen is skipped.

## The alert

The limit is `JG_STATUS_LATENCY_LIMIT_SECONDS` (default 120).
A wake over the limit, or no wake once the limit has passed, raises `undelivered` through `bin/jg-alert.sh` at rung 3 (Main), one key for each line.
The owner's own watcher is what failed to wake it, so the alert goes one level up.
The watcher runs this check, so a watcher that is fully stopped is the supervision-down alert's case.

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check and registers it; `unwiring.sh [--dry-run] <jg-home>` removes it and keeps the rows.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`bash tests/jg-status-latency.test.sh` runs the real watcher on a throwaway home and replays a wake inside the limit, no wake, and a late wake.
