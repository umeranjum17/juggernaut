# Deprecated paths

The migration to the NATS bus, the Dapr workflows, the OPA policies and the Go cores replaced part of the older shell system.
Most ports deleted the shell they replaced in the same change, so few old paths remain.
This file lists the ones that remain, so an agent does not change a path the stack no longer uses.

A path is listed as deprecated only when its replacement is shipped on this branch line.
"Shipped" means the replacing commits are ancestors of `release/c-10`, and the replacement is the path that runs.
A path whose replacement runs only in shadow, or only on a feature branch, is not deprecated.
Those paths are under "Unconfirmed" with the question that decides them.

## Deprecated

| Path | Replaced by | Replacing change | On a live code path |
| --- | --- | --- | --- |

## Unconfirmed

Do not change these paths without asking, and do not treat them as deprecated yet.

| Path | Question | What is known |
| --- | --- | --- |
| `bin/jg-pending-reply-lib.sh` and its per-waiter record `state/pending-replies/<corr_id>` | Has the Dapr pending-reply workflow taken over from the record file? | `bin/jg-reply-engine.sh`, `bin/jg-reply-bus.sh` and `core/bus/workflows/pending-reply.json` exist, but run in shadow (`docs/reply-shadow.md`). The switch changes #373, #392 and #413 are on `feature/c1-pending-replies` and are not ancestors of `release/c-10`. `bin/jg-migration-live.sh` reports this part as pending. |
| `core/wait-timers/bin/jg-wait-timers-lib.sh` | Do the Dapr escalation workflows now own every rung of the wait ladder? | `bin/jg-escalation-workflows.sh` and `core/bus/workflows/escalation-wait-timers.json` (#360) own the escalation timers. The library still owns the other rungs. |
| `bin/jg-remote-job-lib.sh` and the SSH remote-job path | Has the leaf-node transport replaced the SSH channel? | `bin/jg-bus-leaf.sh` runs in shadow with the SSH path authoritative (`docs/bus-leaf-shadow.md`). |

## Not listed, with the reason

- `addons/` is already refused by `bin/jg-retired-catalog-check.sh`.
- The `ntfy` delivery path was removed (#573, #579, #588, #591, #593). Only the refusal list in `bin/jg-stack.sh` names it.
- The wake queue file, leases and the escalation timers moved to the bus and were deleted in place, so no old file remains.
- `bin/fm-*` are rename shims for homes not yet migrated. They are not part of the bus migration.
