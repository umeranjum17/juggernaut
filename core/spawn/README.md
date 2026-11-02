# spawn

The spawn path's decisions are Go. `cmd/jg-spawn-core` answers what `bin/jg-spawn.sh` used to work
out inline: the launch flags a harness receives (`--model`, and the effort level mapped onto each
harness's own flag, omitted where the harness cannot take it) and the checks that keep a ship brief
and the spawn's own flags in agreement (branch, mode, upstream consent, forge, `--yolo on` on a
gerrit project, and the two "less than the standing posture" notices). `bin/jg-spawn-core.sh` builds
it on first use into the home's state directory; `bin/jg-spawn.sh` calls it where the shell bodies
were, and those bodies are deleted. Everything with a side effect stays in the shell for now.

A machine without a Go toolchain and without a built binary stops the spawn with exit 2 and names
what is missing, so a missing core is never read as an answer.

## Port plan

`bin/jg-spawn.sh` is about 6,100 lines and ports one slice at a time, each switched live only after
a parity replay of the shell it deletes against the Go that replaces it.

1. **This slice.** Launch flags (`model-flag`, `effort-flag`, `rigor-rank`) and the brief/spawn
   delivery agreement (`delivery-agree`, `delivery-notices`).
2. Argument parsing and intake refusals: the flag grammar, `--relaunch` identity rules, the
   harness, model, effort and backend validation, account pins.
3. The remaining pure builders: the Claude `--add-dir` grant, the Rovo override, the OpenCode
   database assignment, the launch environment allow-list.
4. Launch templates per harness.
5. Worktree, endpoint and metadata effects: locks, treehouse leases, backend adapters, the task
   record, rollback.

## Parity replay

The replay lives with the task's evidence, and the command to rerun it is in the PR body. It cuts
the shell functions and the delivery block out of `bin/jg-spawn.sh` at the base commit and runs them
against this command:

- **Launch flags:** every harness (the fourteen verified, plus two invalid names) against every
  recorded and edge model (40) and every effort word, 7,686 rows, byte for byte on stdout, stderr
  and exit code. Pi's `ultra` reaches the same `jg-harness.sh validate-native-effort` on both sides.
- **Delivery agreement:** every brief this home recorded (594), plus single-axis and seeded
  departures from the request each one implies, plus copies of 200 briefs carrying a forge token
  because no recorded brief has one (16,131 cases), comparing the exit code and the full stderr of
  the old block and the new block.

A control run with a corrupted Go side (the gerrit refusal removed) must fail the replay.
`tests/jg-spawn-core.test.sh` keeps the interesting shapes as an end-to-end suite.
