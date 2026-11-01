# fleet-report

A scheduled fleet report card for the board, built by script from durable records with no model call.
- `bin/fleet-report.sh <home> [--hours N] [--json]` prints the report: merges per project, open PRs, lanes working against `config/lane-target`, ready items not started, stuck workers by age bucket, captain asks waiting, and alert quality.
- Lanes, ready work, stuck workers and captain asks come from the `jg-flow.v1` reader in `fleet-flow` (or `--flow <file>`).
- Merges come from `data/metrics/task-outcomes.tsv`; name more homes' files in `JG_REPORT_OUTCOMES` to cover every lead.
- `bin/fleet-alerts-ledger.sh <home>` snapshots `state/.wake-queue` into `data/metrics/alerts.tsv` (raised, seq, kind, key, cleared), because the queue forgets a row once handled.
- A false alarm is an alert whose same kind and subject raised again within `JG_REPORT_FALSE_SECS` (default 600) of the previous one clearing or raising.
- Time to clear is the gap between the ledger seeing a row and seeing it gone, so its precision is the call cadence.
- `bin/fleet-report.sh <home> post` publishes a board report card named by `config/fleet-board`; the previous card of that window is dismissed.
- `bin/fleet-report.sh <home> tick` is the scheduled entry: call it from a home check every poll.
  It records alerts, then posts the 4 h card and the 24 h card when their last post is old enough, and stays silent unless a post fails.

## Check
- `bash tests/fleet-report.test.sh` is the host test table over fixture records: window filtering, PR dedupe, stuck buckets, ready and captain counts, alert stems, false alarms, clear time, posting and tick cadence.
