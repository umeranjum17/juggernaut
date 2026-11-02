# herdr

The herdr backend core is Go. `cmd/jg-herdr` makes the decisions and reads the JSON answers that
`bin/backends/herdr.sh` used to leave to jq, awk, cksum and tr. The adapter still runs the `herdr`
client and keeps the function names `bin/jg-backend.sh` and its callers use; each forwards to
`bin/jg-herdr.sh`, which builds the command on first use into the home's state directory. The
command's header lists every subcommand and is the one owner of that contract.

## Port plan

The adapter is 4,400 lines of shell (129 functions, 126 jq calls). It moves in slices, each
switching live only after a parity replay against the shell it deletes.

1. The pure decisions: the release-floor verdict and version comparison, the presentation
   preference, agent names and their checksum variant, and the submit-confirmation budget (done).
2. The readers of herdr's JSON answers that are a field, a list filter or a tri-state: 41 plain
   `// empty` reads, the pane, workspace and tab readers, the client and server status readers,
   the socket path (done).
3. **This slice.** Every `jq -e` program, as `jg-herdr check`: the identity and shape proofs of a
   tab, pane or workspace, the move and order verdicts, the process-info proofs, the focus
   snapshot's tab proof and the projection binding.
4. The `jq -r` and `jq -c` analyses that remain (the focus snapshot, the emptying-close indices,
   the order analysis, the husk and token lookups).
5. The presentation journal and projection recovery.
6. Pane process state, composer and busy-state reads, and the lifecycle: server ensure, create,
   kill, and the event wait.

## Parity replay

`replay.sh <base herdr.sh> <recorded dir>` sources the adapter at the base commit and the ported
adapter in their own shells and calls every function this slice touched, with the same arguments,
over the same answers. A stand-in for the `herdr` client replays a recorded file for the
subcommand it is asked, so no live session is read. The answers are the recorded ones (record them
from a named lab session with `bin/jg-herdr-lab.sh run`, never the live session) plus a set of
malformed and unusual answers for every slot. The two result lists, stdout with trailing newlines
and exit status of each call, must be identical. `--control` corrupts the Go side on purpose and
must fail.

`replay-checks.sh` is the program-level half for slice 3: the base adapter's `jq -e` programs, kept
word for word, run beside each Go check over every recorded and synthetic answer and a set of
argument tuples, on stdout and on jq -e's exit status. A check that never reads true on any
answer fails the replay, because that would prove only its false side. `replay.sh` runs it last;
`REPLAY_ONLY_CHECKS=1` runs it alone. A replay refuses to start inside another replay.
`tests/jg-herdr-go.test.sh` keeps the interesting shapes as an end-to-end suite.
