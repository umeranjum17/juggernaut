# fleet-stats

The per-model and per-skill fleet statistics readers and their shared library
moved **verbatim** out of the supervising fork into this feature repository.
The statistics remain available as CLI readers; Lookout does not display them.
The per-model reader no longer reads an outcome file: it reads each home's
tickets from Beads (see Layout), and there is no outcome recorder.

## Layout

- `bin/jg-model-stats.sh` — per-model fleet statistics. Read-only: it writes
  nothing and never touches an endpoint.
  It reads this home, then every locally registered home, from each home's
  tickets (`jg-backlog.sh times --json --since`, authoritative: each task's
  times and pull request, and its launches from the spawn's `claim` and
  `handoff` events; see `docs/fleet-ledger.md`), the older sampled
  `data/metrics/lanes.tsv` (only for tasks the tickets predate, marked
  sampled), and `data/metrics/prs.tsv` (time-to-merge, first-pass, rework,
  revert and escape counts). A home whose store cannot be read is named in the
  limitations. It imports `jg_stats_lib` from its own directory, so the reader
  only runs with the library beside it. Test: `tests/jg-model-stats.test.sh`
  on real Beads stores.
- `bin/jg-skill-stats.sh` — per-skill fleet statistics. Read-only. It reads
  `data/metrics/skills.tsv` (absent file
  reports no rows rather than failing) and enumerates each local home's
  skill directories to name skills that were never read. It imports
  `jg_stats_lib` from its own directory like the model reader.
- `bin/jg_stats_lib.py` — the readers' shared library: usage and argument
  parsing, tab-separated file reading, and enumerating this home plus every
  locally registered home. Only the two readers import it; all aggregation
  and output stays in the importing reader.
- `bin/jg-retro-metrics.sh` - the retro metrics (not moved from the fork;
  new here). `definitions` prints one written definition per metric, with
  `first_pass` defined once. `compute --home <dir> --retro <id>` reads
  `data/metrics/prs.tsv` and `daily.tsv`, prints the last N UTC days beside
  the N before, and stores the result as one line in
  `data/metrics/retro-index.jsonl`; `show` reads a stored line back. The
  collectors that fill `prs.tsv` and `daily.tsv` are not in it.
  Test: `tests/retro-metrics.test.sh`.
- `tool-cpu.sh` - which fleet scripts start the mise shim, gh, chromium and shellcheck
  processes that take the most busy cores (H53). It averages a few process-table
  samples, charges each tool process to the nearest `.sh` script above it, and prints
  cores per tool and caller. `--daily` records one sample a UTC day in
  `data/metrics/tool-cpu.tsv`; with `--file-tickets` it files one `tool-cpu-<script>`
  ticket per top caller through `bin/jg-backlog.sh`, none while one is open. The
  header owns usage. Test: `tests/jg-tool-cpu.test.sh`. Nothing runs it on a timer yet.
- `hotfiles.sh` - names each file that 3 or more lanes (tickets) changed in a
  window (default 7 days) with a split proposal; `--post` files one `[feature]`
  board card per file, once. Read-only without `--post`.
  Test: `tests/jg-hotfiles.test.sh`.
- `bottlenecks.sh` - one bottleneck report a day from the landing records: seconds per landing
  step, gate and verify time, queue wait by reason, host load, and the runs, fail rate and cost of each
  test script. `--daily` keeps one report a UTC day in `data/metrics/`; `--file-tickets` files one fix
  ticket, through `core/trunk-landing/quarantine.sh ticket`, for a script whose mean is over its cost
  budget (default 120 s over 3 runs) or that failed over 40 percent of at least 30 runs. Test:
  `tests/jg-fleet-bottlenecks.test.sh`. Nothing runs it on a timer yet.

## Frozen contract (identical to the fork)

- Readers: `JG_HOME=<home> jg-model-stats.sh --json [--now <unix-seconds>]`
  and the same shape for `jg-skill-stats.sh`. Any other flags, a missing
  `--json`, or a non-numeric `--now` exits 2 with usage on stderr.
- Model output schema `jg-model-stats.v1` with keys `at`, `now`,
  `windows [7, 30]`, `models[w]` (one entry per model over the window,
  largest finished first, each with `model`, `name`, `family`, `provider`
  plus `w7`/`w30` stat blocks), `coverage` (`outcome_rows`,
  `sampled_tasks`, `outcome_homes`, `prs_rows`, `lanes_rows`), and
  `limitations`. A task is attributed to the model it ended on; a task whose
  history names more than one model also counts as a switch. Merge rate is
  merged ship tasks over finished ship tasks with a recorded terminal
  outcome; sampled rows never fabricate a verdict.
- Skill output schema `jg-skill-stats.v1` with keys `at`, `now`,
  `windows [7, 30]`, `skills[w]` (read counts per skill, most-read first,
  each with the number of homes it was read in), `by_home[w]`, `zero_read_w7`
  and `zero_read_w30` (only for windows the coverage spans and while no
  remote home is registered), `coverage` (`rows`, `days`, `skills`, `homes`,
  `first_day`, `last_day`), and `limitations`.
- Library location: each reader puts the directory it lives in first on the
  import path and imports `jg_stats_lib` from there; the library must sit
  next to the reader, never elsewhere.
- Task outcome: there is no outcome file and no recorder. The reader derives
  `outcome` from the ticket: `scout` for a Recon, `merged` for a landed or
  released ticket, `closed` for a closed one with a pull request, `cancelled`
  for a closed one with none, and none while it is open.

## Provenance

`jg-skill-stats.sh` and `jg_stats_lib.py` were moved byte for byte from
`umeranjum17/juggernaut@0689b4b9d9ab3594f846cfe07c400edfa58244bf`; treat a diff
against the fork file as a contract change, not a refactor.
`jg-model-stats.sh` was moved the same way and then changed by slice S29 of the
jg-q1b3n plan to read tickets instead of `data/metrics/task-outcomes.tsv`; the
outcome recorder `jg-task-outcome.sh` and its teardown call were deleted then,
and the files already written stay on disk, unread.
