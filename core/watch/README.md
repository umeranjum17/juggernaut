# watch

The supervisor watcher's window inventory is Go. `cmd/jg-watch-core` answers two questions the
watcher asks on every cycle: which recorded window endpoints it watches, in what order, and what
kind, backend and harness each window answers. `bin/jg-watch-core.sh` builds it on first use into
the user's cache, keyed by the checkout, never into a home or the repository.
`bin/jg-watch.sh` reads one inventory per cycle and its `recorded_windows`, `window_kind`,
`window_backend`, `window_harness` accessors answer from it.
The command's header is the one owner of the field rules.
`bin/jg-backend.sh` keeps its own record readers for the scripts that are not the watcher.

## Port plan

`bin/jg-watch.sh` is the hottest shell path in the fleet: every cycle starts interpreters, and its
behaviour sits half in shell and half in Go. It moves in slices, each switching live only after a
parity replay against the shell it deletes.

1. **This slice.** The window inventory: the watched endpoints and their order, and the kind,
   backend and harness answers. The shell the four accessors held re-walked every
   `state/<id>.meta` record for every answer, forking `grep`, `cut` and a subshell each time; one
   cycle on a twenty-window fleet spent about a hundred and fifty forks on it.
2. The wake queue and inbox observations the watcher still reads in shell.
3. The stale ladder's per-window marker bookkeeping.
4. The signal scan and its seen-marker commits.
5. The due-check driver and the poll wait.

A slice that needs the wake library keeps to the interface `release/c-4` has today; that library
has its own lane.

## Parity replay

`tests/jg-watch-inventory.test.sh` replays a corpus of meta records through the Go command and
through the shell reader it replaced, after every record of the corpus, and requires identical
rows, identical order and identical answers. The corpus covers every rule the deleted shell
applied: an absent `backend=` or `kind=`, an orca `terminal=` target with and without a terminal,
a record naming no window, a repeated target, a `jg-control.sh exit` record newer than, older
than and equal to the spawn generation, a non-numeric exit epoch, a repeated `window=`, a value
holding `=`, an unreadable record, and a window name carrying `:`, `/` and `.`.
Two control runs corrupt one answer and the row order, and the same comparison must reject both.
The same file then runs a real `bin/jg-watch.sh` cycle over a throwaway home with a logging wrapper
around the Go command, and requires the cycle to read its inventory there and deliver its wake.
The corpus is written by the test rather than recorded from a home, because a record names a
project, a worktree and a home path.

Run it with `bash tests/jg-watch-inventory.test.sh`; it skips without a Go toolchain.

## Decisions this slice made

- One inventory per cycle. The deleted accessors re-read the records on every call, so a record
  written mid-cycle by another process could be seen by a later question in the same cycle. The
  watcher now reads once, at the top of the cycle, and every question that cycle answers from that
  snapshot.
- A record that repeats `kind=`, `backend=` or `harness=` was answered by the deleted shell as the
  newline-joined list of every value, because it ran `grep ... | cut` with no last-value rule. The
  Go command answers the last value, the rule `jg_meta_get` already documents for a repeated key,
  because a multi-line answer cannot reach any comparison intact.
- An inventory that cannot be read stops the cycle with `watcher: window inventory read failed`
  instead of reporting an empty fleet. A stopped watcher is visible to its arm and health checks;
  a blind one would look healthy.
- The inventory read writes to a temp file in the state directory and reads that, rather than
  through a command substitution. `watcher_stop_signals` in `bin/jg-watch.sh` owns the reason: a
  stop signal that lands inside a command substitution can be dropped or mis-parsed on a
  supported bash, and a supervision cycle must never survive a stop request.
