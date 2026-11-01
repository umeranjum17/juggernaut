# escalation-optimize

Escalation tuned for tokens: batching, priority and back-off, so a repeating or
unactionable condition stops costing a model turn. All six rules are configuration in
`core/bus/workflows/escalation-optimization.json` (a home overrides it at
`config/escalation-optimization.json`); `bin/jg-escalation-optimize.sh` only reads
facts and applies them. The escalation tick (`bin/jg-escalation-workflows.sh`) asks it
before every owner wake, closes resolved escalations, and sends held rows as digests.

| # | Rule | Config | Test |
|---|------|--------|------|
| 1 | Priority classes `urgent/now/soon/batch/digest/silent`; per-target wakes per hour | `classes`, `priority`, `budget`, `targets` | priority, budget |
| 2 | Exponential back-off with a cap; reset only when the payload changes | `backoff` | backoff |
| 3 | Coalesce by key: one wake per group with a one-line digest | `coalesce` | coalesce |
| 4 | Never climb to a hop that cannot act: parked home, captain hold, declared wait, external wait | `actionability` | actionability |
| 5 | Auto-resolve when the state the escalation was raised about changes | `autoResolve` | auto-resolve |
| 6 | Every escalation carries `evidence=[...]` and `action=[...]` | `envelope` | envelope |

Run the rule proof: `bash core/escalation-optimize/tests/jg-escalation-optimize.test.sh`.
Run the product proof, which drives `decide`, the live `bin/jg-escalation-workflows.sh tick`
and the real wake queue in a disposable home: `bash journeys/escalation-rules-live.sh`
(done-done journey `escalation-rules-live`).
Measure a recorded stream: `jg-escalation-optimize.sh replay <rows>` prints wakes
avoided, tokens saved (a per-wake estimate, not a measurement) and the wait added.

## Prior art

Prometheus Alertmanager (Apache-2.0): `group_by`/`group_wait` (rule 3),
`repeat_interval` (rule 2) and `inhibit_rules` (rule 4) are the reference shapes. Rule
shapes only; no Alertmanager code is used. Other options weighed: PagerDuty event
rules (hosted, closed), Opsgenie routing (hosted, closed), Grafana OnCall (AGPL-3.0,
cannot be embedded), Keep (MIT, a whole platform for one script's job).
