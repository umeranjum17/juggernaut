# spawn

The spawn path's decisions are Go. `cmd/jg-spawn-core` answers what `bin/jg-spawn.sh` used to work
out inline: the launch flags a harness receives (`--model`, and the effort level mapped onto each
harness's own flag, omitted where the harness cannot take it) and the checks that keep a ship brief
and the spawn's own flags in agreement (branch, mode, upstream consent, forge, `--yolo on` on a
gerrit project, and the two "less than the standing posture" notices), and `intake` answers how the
spawn's own arguments are read: the flag grammar and every refusal that needs nothing but the
arguments. `bin/jg-spawn-core.sh` builds
it on first use into the home's state directory; `bin/jg-spawn.sh` calls it where the shell bodies
were, and those bodies are deleted. Everything with a side effect stays in the shell for now.

A machine without a Go toolchain and without a built binary stops the spawn with exit 2 and names
what is missing, so a missing core is never read as an answer.

## Port plan

`bin/jg-spawn.sh` is about 6,100 lines and ports one slice at a time, each switched live only after
a parity replay of the shell it deletes against the Go that replaces it.

1. Done. Launch flags (`model-flag`, `effort-flag`, `rigor-rank`) and the brief/spawn delivery
   agreement (`delivery-agree`, `delivery-notices`).
2. Done. Argument parsing and the refusals that need only the arguments (`intake`): the flag
   grammar, empty and missing values, the effort vocabulary, the squad_lead-only traceparent,
   what a `--relaunch` may not restate, and what a ship, scout or squad_lead may carry (mode,
   yolo, branch prefix, base branch, upstream consent). The account pool's `--account` check
   runs between the first refusals and the rest, so the rest comes back as `INTAKE_REFUSAL` and the
   spawn raises it right after that check. The refusals that read the harness, the model list, the
   backend or an account pin need configuration and stay with the effects for now.
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

- **Intake:** the block cut from `bin/jg-spawn.sh` at the base commit (argument loop, empty-value,
  traceparent and effort checks, the account `--account` check, the relaunch and contract refusals)
  against the block now in the script, run in the same shell harness. 44,255 argument vectors: the
  task records of this home turned into the request that made them, with each flag dropped or
  swapped; every invocation the repo's tests and docs show; a single-axis sweep of every flag over
  every shape (ship, scout, squad_lead, relaunch) in both `--flag v` and `--flag=v` spellings and with
  or without a ship base; a pairwise sweep; the account flag in nine shapes with and without the
  control relaunch marker; every mode, yolo and consent value together; every ordering of four flags;
  and seeded random sequences. Each case compares the eval-ed variables, the exit code and the full
  stderr, byte for byte. All 73 distinct refusals are reached.

A control run with a corrupted Go side (the gerrit refusal removed) must fail the replay.
`tests/jg-spawn-core.test.sh` keeps the interesting shapes as an end-to-end suite.
