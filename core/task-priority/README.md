# task-priority

A new backlog task must carry a priority 0-3 and a target release, so every open item can be published as a ticket on the sign-off board.

- `bin/jg-task-priority-check.sh <tasks-axi command> [args...]` checks `add`/`create` only (other commands exit 0).
  Priority comes from `--priority 0-3`; missing or out of range exits 1 with `task-priority: ... pass --priority 0|1|2|3`.
  The target release is a `release: <name>` line in `--body` or `--body-file`; absent means `later`, so only the priority can refuse.
  Stdout is `release: <name>`, the resolved release.
- `wiring.sh [--dry-run]` copies the check to `${XDG_DATA_HOME:-~/.local/share}/jg-task-priority/check.sh`.
- Fork seam (slice 2, not in this feature): `bin/jg-tasks-axi.sh add` and the row creation in `bin/jg-captain-hold.sh hold`
  call that path with the tasks-axi arguments when it is installed, and do nothing when it is not. Existing rows are never checked.
- Test: `tests/task-priority.test.sh` runs the real installer and check in a throwaway `XDG_DATA_HOME`.
