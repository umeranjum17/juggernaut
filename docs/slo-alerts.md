# SLO alerts for failed pipelines and slow choke points

A failed pipeline and a slow choke point must announce themselves.
Tonight's measurement found them by hand: pull requests done but unmerged for one to two hours, lanes idle for 40 to 110 minutes, and red checks nobody picked up.
`bin/jg-slo-alerts.sh` carries rules that raise those alerts themselves.

The shape is the stack report's: the numbers are Prometheus-shaped metrics, every rule and every limit is configuration, Alertmanager's own `for`, grouping, repeat interval and inhibition decide when a notification exists, and each rule has a test that fires it in a lab and one that proves it stays quiet inside its limit.
Part 1 carried the pipeline rules; this part adds the lane, runner-queue and release-branch rules, with the lane count and idle-lane fix.

## The rules

`defaults/slo-alerts.json`, which a home overrides at `config/slo-alerts.json`.
A limit is a number in the unit a reviewer thinks in; a rule fires when the value is **greater than** the limit and it has held for that many `for-minutes`.

| Rule | Metric | Limit | Urgency | Number read from |
| --- | --- | --- | --- | --- |
| `pr-red` | `jg_slo_pr_red_seconds` | 30 minutes | batch | the pull request's reported checks and the head that went red, one forge read per pull request |
| `done-merge` | `jg_slo_done_unmerged_seconds` | 30 minutes | batch | the task's newest `done [at=...]` line while it is still in flight |
| `worker-idle` | `jg_slo_worker_idle_seconds` | 25 minutes | batch | the newer of the lane's status file and its last commit, skipped while the lane's own pane reports busy |
| `ready-work` | `jg_slo_ready_work_items` | 1 item (for 5 minutes) | batch | the ready backlog beside the open lanes against the lane target |
| `runner-queue` | `jg_slo_ci_queued` | 20 jobs (for 10 minutes) | batch | GitHub's own queued run count, one small read per repo |
| `release-waiting` | `jg_slo_release_waiting_seconds` | 60 minutes | **blocker** | the version branch's open pull requests: all green, none a draft, oldest update time |

Both lane rules read the live pane state `bin/jg-fleet-heartbeat.sh` reads (`bin/jg-busy-lib.sh`'s semantic busy record), so a busy pane is working even when its status log is old, a busy pane is never an idle worker, and a lane count is never capped by the lane target.
Two pairs are inhibited: a red pull request mutes the idle-worker alert for the same owner, and a waiting release branch mutes the per-pull-request done-to-merged alert.
The alert that names the cause is the one that reaches a channel; the ones it explains stay quiet.

## The numbers

`collect` writes one sample set from the records the fleet already keeps, so no rule invents a measurement.
A home that sets `prometheus-url` evaluates the same rules against that server instead, which is what makes a limit reviewable against history.
The forge readers (a pull request's checks, the queued run count, the release branch) run at most once per `forge-interval-minutes`, so a poll tick never becomes a GitHub sweep.
`bin/jg-metrics-shadow.sh` exports the same gauges through node_exporter's textfile collector, so Prometheus has the series the rules name.

## Routing

The owner is a label on every sample, so routing needs no second question.

1. **The owning lead first, always.** One wake in the home that owns the lane.
2. **Main only when the lead does not act.** Past `escalate-to-main-minutes` a Squad Lead home appends the escalation to the parent channel its charter names, and a Main home queues a second, louder row.
3. **The captain channel as a digest.** A batch alert joins one digest published as a single line per digest interval; a blocker is published at once with its link.

Urgency is the `blocker`/`batch` word the rule carries, and `defaults/wake-routing` decides the cost: `slo-blocker-*` wakes at once, `slo-main-*` wakes as an escalation, and `slo-*` is a batched row that rides the next wake of any kind.

## Operating it

```sh
bin/jg-slo-alerts.sh show            # every rule, its limit, its urgency and the inhibition in force
bin/jg-slo-alerts.sh collect         # one sample set from this home's own records
bin/jg-slo-alerts.sh eval            # the notifications that are due now, one JSON line each
bin/jg-slo-alerts.sh tick            # what the watcher runs: evaluate, queue, escalate, digest
```

`mode` is the one switch: `live` records, wakes and publishes, `shadow` records and prints what it would send, and `off` does nothing.
The watcher runs one `tick` per poll, at most once per `eval-interval-seconds`.
State lives in `state/.slo-alerts/`: one record per instance, the last sample set, the digest and the forge interval stamp.

## The lab

`tests/jg-slo-alerts.test.sh` writes the sample set itself, so nothing starts a service or reaches GitHub.
It proves that the rules and limits come from configuration and that moving a limit moves the alert; that each rule fires over its limit and stays quiet at it; that instances sharing the group-by labels are one notification; that a still-firing group re-notifies only at the repeat interval; that inhibition mutes the target for the same owner and no other; that the lead is told first, Main only past the escalation window through the parent channel, a blocker reaches the captain at once and the batch alerts ride one digest line; that `mode off` queues and publishes nothing; and that `collect` measures its numbers from the records that own them, including a free lane beside a ready item and a busy pane that is never called idle.

## What it does not do

- It does not run Alertmanager. The shapes are Alertmanager's and the same configuration carries the limits, but the evaluation is this repository's code, so the feature works with no server and can be proven in a lab.
- It does not repair what it reports: the alert is the alarm, and the existing recovery paths own the fix.
- It does not read another home's records. Each home evaluates its own lanes and reports upward through its parent channel.
