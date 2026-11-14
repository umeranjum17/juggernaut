# pane-sweep

Every watcher beat closes the bare shells in this home's own Herdr workspace that no record names, with no model turn.

`sweep.sh check <jg-home>` is the watcher check; `sweep.sh run <jg-home>` is the same sweep by hand.
It prints one line per pane it closes, naming the task the spawn map says started that pane, and one line per close that did not work.

## What is closed

A pane is closed only when every test holds, and each test is read again right before the close:

- It is in this home's own workspace (`jg_backend_herdr_workspace_find`). Other workspaces, homes and sessions are never read for closing.
- No `state/*.meta` has `window=<session>:<pane>` for it, and it is not the pane the sweep runs in.
- It holds one lone idle shell and nothing else (`jg_backend_herdr_pane_idle_shell_pid`, the adapter's one idle-shell proof). A pane that runs an agent, or any foreground process, fails it.
- It has been seen like that on every sweep for at least 30 minutes (`JG_PANE_SWEEP_IDLE_S`, default 1800). The first sighting is kept in `data/pane-sweep/seen.tsv`; a pane that fails any test is forgotten at once.

The close is `jg_backend_kill` through `bin/jg-backend.sh`, confirmed by a follow-up read of the pane.
At most 3 panes close per sweep (`JG_PANE_SWEEP_MAX`). Other backends, a stopped session and a missing workspace are read as nothing to sweep.
The owner approved closing empty shells that no work owns on 10 Nov (C-96).

## The producer

`data/copy-tasks.tsv` (written by `bin/jg-spawn.sh`, slice 29) keeps one row per launch: copy, pane, task id, start time.
It is append-only, so a pane that is in it and in no `state/*.meta` is a pane whose lane record is gone.
On 14 Nov, 273 of its 292 panes had no record; most of those panes were closed by their teardown long ago.
The lane that built this check could not list the live default session (a lab lane may not touch it), so the live count and the one cause for each surviving shell are unverified.
Every close line now names the task from that map, so the producer shows in the sweep output; fix that producer where it is ours once a line names it.

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check, writes the shim `state/pane-sweep.check.sh`, and registers it with `bin/jg-check-register.sh`.
`unwiring.sh [--dry-run] <jg-home>` unregisters it and removes the installed command; that is the rollback.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`bash tests/jg-pane-sweep.test.sh` runs the journey in a real isolated Herdr lab session (every call through `bin/jg-herdr-lab.sh`; teardown proves the default session is unchanged).
