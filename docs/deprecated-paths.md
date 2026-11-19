# Deprecated paths

The migration to the OPA policies and the Go cores replaced part of the older shell system.
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

## Not listed, with the reason

- `addons/` is already refused by `bin/jg-retired-catalog-check.sh`.
- The `ntfy` delivery path was removed (#573, #579, #588, #591, #593). Only the refusal list in `bin/jg-stack.sh` names it.
- The wake queue file, leases and the escalation timers moved to the bus and were deleted in place, so no old file remains.
- `bin/fm-*` are rename shims for homes not yet migrated. They are not part of the bus migration.
