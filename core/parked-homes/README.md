# parked-homes

When you park a squad lead home, nothing may reach it: no message,
steer, answer, nudge or relaunch, and no config push. Before this feature the
only record of a park was a line in a home data file, which no supervision
producer reads — so a parked home still got config-reread nudges, a pending
reply retry ladder, and quota-failover relaunches onto a new model.

Every supervision producer now gates on **one shared reader**,
`jg_parked_home <id>`, instead of carrying its own copy of the rule.

## The parked-homes file

`<jg-home>/config/parked-homes` — one home id per line; `#` comments and blank
lines are ignored:

```
# Parked homes: no work, nothing merges.
v1design
relayiptv
```

A missing file parks nothing; an unparked home behaves exactly as before.

## Home-id resolution

A task meta belongs to a parked home only when its `kind=squad_lead`. A local
squad lead's `home=` path carries `.jg-squad-lead-home` with the id; a remote
squad lead's home lives on its host, so the recorded task id stands in.
Operator and lead lanes are never parked, whatever their task id spells.

## The gated paths

| Producer | Gate | Skip behavior |
|---|---|---|
| Supervision session (message, steer, answer, nudge — `jg-send.sh`) | after target resolution | one `error:` line, exit 1, nothing delivered or marked |
| Relaunch (`jg-control.sh <id> relaunch`, `jg-remote-squad-lead-relaunch.sh`) | before the launch transaction | one `error:` line, exit 1 |
| Restart pass (`jg-squad-lead-restart.sh`, used by /resupply) | argv filter | one `parked: <id>:` line; no persist request, no restart, no nudge |
| Reconcile nudge (`jg-squad-lead-reconcile.sh`) | per-target | `skipped: <id> parked`; request preserved |
| Config push (`jg-config-push.sh`) | per-home | `squad lead <id>: skipped - its home is parked` |
| Inherited config push (CONFIG_REREAD, both bootstrap loops) | per-home | one skip line; no push, no reread nudge |
| Pending-reply retries and missed-report escalation (`jg_pending_reply_tick`) | per-record | record kept as-is; no recovery resend, no escalation |
| Model-outage alert (`jg_model_outage_tick`) | per-lane | lane never scanned, never alerts |
| Wake-loop check (`squad_lead_wake_stall_tick`) | per-mate | no drain ring, no stalled check; episode markers dropped |
| quota-failover (this repo) | per-task | `note`d once; the stopped parked worker is never moved |

One log line per skip is all a parked home ever produces.

## Layout

- `bin/jg-parked-homes-lib.sh` — the shared reader (source-only, no deps).
- `wiring.sh` — verifies the wiring: this checkout reachable from the home,
  the fork shim present, the parked file readable. It changes nothing.
- `tests/parked-homes-e2e.sh` — the integration test: a fixture fleet of two
  homes, one parked, driven through every gated path above against a real
  juggernaut checkout carrying the fork hooks.

## Wiring (fork hook)

The live producers live in the juggernaut fork, so the gates are one source
line plus one predicate call per producer (fork PR carries the full list; see
`FORK-EXIT.md`). The fork's `bin/jg-parked-homes-lib.sh` is a thin shim: it
sources this directory's reader from `JG_ADDONS_DIR` (default
`$JG_HOME/projects/juggernaut-addons`). When the feature checkout is absent the
shim defines no-op predicates — every gate is a no-op and behavior is exactly
as before, so the fork hook is safe to merge before any home installs the
feature checkout.

`pipeline-quota-failover` is out of scope: it fails over models inside
no-mistakes pipeline calls and never touches a squad lead home. The ff-sweep's
fast-forward of a parked home's checkout is also untouched (a park stops
contact, not the fleet's code convergence); its nudge is gated at
jg-send/bootstrap.
