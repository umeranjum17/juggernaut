# teardown

Task teardown is being ported to Go in slices. `cmd/jg-teardown` answers the landed-work test, the
question teardown must pass before it may discard a worktree: has this work landed? It keeps every
refusal of the shell test it replaces and has no override. `bin/jg-teardown-core.sh` builds it on
first use into the home's state directory, the way the guard host is built. `bin/jg-teardown.sh`
gathers the task's recorded facts (worktree, branch, project, recorded PR and base branch, and the
forge identity `bin/jg-pr-lib.sh` parses from the PR URL), asks the command, and refuses unless it
answers "landed". A command that cannot run exits 2 and teardown refuses with that reason.

## Port plan

`bin/jg-teardown.sh` was 4,083 lines. Each slice switches live only after a parity replay against
the shell it deletes, and deletes that shell in the same change.

1. **This slice.** The landed-work test: the forge proof (GitHub through `gh`, Forgejo through
   `tea api`), the PR lookup by branch, the patch-id containment that survives squash and rebase,
   the default-branch content check, and the default-branch read. 29 shell lines remain in
   `bin/jg-teardown.sh` to marshal the facts the command cannot read from the worktree.
2. The worktree safety check around it: dirty and unpushed reads, the local-only rule, the lock
   retry.
3. Process reaping and the endpoint close.
4. Squad Lead and home removal, and the scratch and Herdr cleanup.

## Parity replay

The replay runs the shell test from the base commit and the Go command over the same recorded
forge answers: every pull request of this repository (433, merged, closed and open, read from the
real forge) against a mirror holding their real heads, in nine situations each (head, parent of the
head, head plus a local commit, no recorded URL, forge unreadable, default branch tip, other base
branch, no origin, GitHub origin with an unreadable forge). A difference in the verdict, the
refusal sentence or the resolved PR URL fails the replay, and a control run with a corrupted Go side
must fail it. `tests/jg-teardown-core.test.sh` keeps the interesting shapes as an end-to-end suite,
and `tests/jg-teardown.test.sh` drives the same test through teardown itself.

## Slices 3 and 4

Slice 3 is `reap`: the process reaping that runs before teardown discards a directory.
It finds every process whose working directory is under the task's roots with one `lsof -a -d cwd` scan, tracks each by its kernel start time, ends it with TERM and then KILL, and repeats up to three passes.
Without `lsof` it falls back to the tmux pane's process group.
A scan that fails, a process that cannot be identified, or processes that remain refuse the teardown.
`--caller-pid` is the teardown script's own pid, which is never a leak.

Slice 4 is the removal validators: `validate-removal`, `validate-child`, `validate-home` and `worktree-registered`.
They answer whether a path is safe to remove, never remove anything, and print the canonical path on success.
`validate-home` carries the Squad Lead registry check (`bin/jg-squad-lead-registry-lib.sh` still owns it for every other caller): entries parse, routes are safe, no home or id is bound twice, and no home contains another.
The shell keeps `safe_rm_rf`, which asks the validator and then removes.

Two behaviours differ from the shell on purpose.
The shell reported a failed scan when the last `lsof` line was the teardown script's own working directory under a root, because a `&&` list returned false at the end of the loop; the command does not.
A core that cannot run refuses the removal with its own sentence.
The parity replays for both slices (generated process, lsof, identity and registry situations, and their corrupted controls) are kept with the task's evidence.
