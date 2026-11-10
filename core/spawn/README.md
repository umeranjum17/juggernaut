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

1. Done. Launch flags (`model-flag`, `effort-flag`) and the brief/spawn delivery
   agreement (`delivery-agree`, `delivery-notices`).
2. Done. Argument parsing and the refusals that need only the arguments (`intake`): the flag
   grammar, empty and missing values, the effort vocabulary, the squad_lead-only traceparent,
   what a `--relaunch` may not restate, and what a ship, scout or squad_lead may carry (mode,
   yolo, branch prefix, base branch, upstream consent). The account pool's `--account` check
   runs between the first refusals and the rest, so the rest comes back as `INTAKE_REFUSAL` and the
   spawn raises it right after that check. The refusals that read the harness, the model list, the
   backend or an account pin need configuration and stay with the effects for now.
3. Done. The pure builders: the Claude `--add-dir` grant (`claude-add-dirs`), the Rovo override
   (`rovo-override`), the OpenCode squad_lead grant file (`opencode-lead-grant`) and per-launch
   session store (`launch-home-token`, `opencode-db`), and the launch environment: the allow-list's
   grammar (`launch-env-names`), the provider-credential strip (`launch-env-strip`) and the
   `env -i` wrap (`launch-env-wrap`). `bin/jg-launch-env-lib.sh` is deleted with them. One small
   difference, in the direction of fewer dependencies: the OpenCode `auth.json` check no longer needs
   `jq` on the machine. One difference is known and left: `jq` reads the non-JSON literal `NaN` in
   `auth.json`, which opencode never writes, and the Go side does not.
4. Done. Launch templates per harness (`launch-template`): the verified launch command with its
   placeholders for each of the fourteen adapters, by kind (a Claude, Codex, OpenCode or Pi
   squad_lead differs from a ship or Recon worker). `bin/jg-spawn.sh` keeps the placeholder
   substitution, which reads the task's own state.
5. Worktree, endpoint and metadata effects: locks, treehouse leases, backend adapters, the task
   record, rollback. Started: the read-only checks a spawn makes before it creates anything are Go,
   `home-validate` (a squad_lead's home is a seeded home of its own, outside the active home and the
   repository, with working directories of its own) and `worktree-isolated` (a worker's directory is
   its own worktree root, not the spawning project and not the primary checkout). Next, each with
   its own replay over recorded records and fixtures: the task record and the relaunch record it
   preserves, the abort and rollback paths, the fresh-worktree base check, then the lock, lease and
   backend-adapter effects.

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

- **Builders:** the shell functions of the base commit (`json_escape`, `shell_quote`, `rovo_config_override_flag`,
  `claude_add_dirs_flag`, `opencode_lead_grant_write`, `spawn_launch_home_token`, `opencode_go_auth_present`,
  `opencode_db_assignment`, the credential-strip library, the `jq` allow-list read and the `env -i`
  block) against the commands that replaced them, 41,094 cases: every effort word against 40 directory
  spellings (symlinks, dot-dot through a link, relative, trailing slash, spaces, quotes, newline,
  unreadable, a file, missing, empty, `//`) for the two task directories and eleven task ids; the
  writing builders over 2,766 directory trees (state, data and code root present, linked, missing or
  a file; a channel directory already there as a file), comparing the output, the exit code and the
  whole resulting tree byte for byte; 16 models against 28 `auth.json` contents under three ways of
  finding the data directory; 7,429 allow-list files; 3,240 environments against allow-lists; and
  240 launch commands. Standard output and exit code are compared byte for byte, and for the strip
  the set of names (the shell's order is its variable table's).

- **Launch templates:** `launch_template()` of the base commit against `launch-template` over the
  fourteen adapters and 16 invalid names against ten kinds, 330 cases, stdout and exit code byte
  for byte. The control, with the Codex hooks flag and the OpenCode question denial removed, fails.

- **Validators:** the base commit's squad_lead home functions and `spawn_worktree_isolated` against the
  wrappers now in the script running the core, 3,203 cases, exit code, stdout and stderr byte for
  byte: 2,426 generated homes (the home, a relative path, a symlink, the filesystem root, the active
  home, the repository, a directory inside or above either, seven marker shapes, the three other
  required entries, and every working directory as a dangling link, a link out, a link in, a link
  chain, a file, missing or unreadable, singly and in pairs) and 777 git states (primary, linked and
  detached worktrees, a worktree of another repository, a bare repository, a submodule, a nested
  repository, a broken `.git` file, subdirectories, links, an unreadable directory, and four git
  environments) against seven spawning projects.

A control run with a corrupted Go side (the gerrit refusal removed) must fail the replay.
`tests/jg-spawn-core.test.sh` keeps the interesting shapes as an end-to-end suite.
