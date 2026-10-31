# Juggernaut portable test shards

`bin/jg-test-run.sh` owns portable lane composition and execution.
`bin/jg-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [jg-test-isolation-proof.md](jg-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

Both hint tables were refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/juggernaut/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/juggernaut/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/juggernaut/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/juggernaut/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/juggernaut/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `JG_TEST_END` log markers, with the two version/platform exceptions below.
All artifact records were cross-checked against the corresponding job's markers.
This covers all 24 parallel and 201 serial members; an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

Two serial-5 jobs were cancelled at their 30-minute cap and uploaded no artifact.
Their completed log markers supplement the complete runs, but a cancelled job's wall time is only a lower bound and its unfinished or never-started scripts have no completed sample.
A failed script's duration is excluded even when its lane uploaded an artifact.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

The serial hint table was refreshed on 2026-10-29 from the portable serial artifacts of five Ubuntu CI runs: [40834047706](https://github.com/umeranjum17/juggernaut/actions/runs/40834047706), [40836566918](https://github.com/umeranjum17/juggernaut/actions/runs/40836566918), [40838305188](https://github.com/umeranjum17/juggernaut/actions/runs/40838305188), [40843475618](https://github.com/umeranjum17/juggernaut/actions/runs/40843475618) (its one failed script excluded), and [40844984644](https://github.com/umeranjum17/juggernaut/actions/runs/40844984644).
The measured maxima pack four shards to about 1520 s and five to about 1215 s against the 1200 s target, so the lane runs six shards; the largest is the single script `tests/jg-supervision-host.test.sh` at 1162449 ms.
The complete local host suite remains available through `JG_SUPERVISION_HOST_PART=all bash tests/jg-supervision-host.test.sh`.
The 2026-10-07 polytoken adapter tests carry provisional local measurements instead - 21090 ms for `tests/jg-polytoken-harness.test.sh` and the 103 ms live-guard skip for `tests/jg-polytoken-signals-live-e2e.test.sh`, both measured on the adapter-verification macOS host - until the next CI refresh replaces them with Ubuntu measurements, because they postdate the 2026-09-30 baseline.
The 2026-10-30 `tests/jg-design-gate-first-draft.test.sh` carries its provisional local measurement of 680 ms from `bin/jg-test-run.sh --json` on the Linux workspace host for the same reason, and the next CI refresh replaces it with an Ubuntu measurement.
The 2026-10-30 hints for the fourteen scripts that had none (the ones the coverage guard listed) carry provisional local measurements from one serial `bin/jg-test-run.sh --json` run on the Linux workspace host, the largest being 14071 ms for `tests/jg-tmp-sweep.test.sh`; the next CI refresh replaces them with Ubuntu measurements.
The session-start hint retains its pre-optimization maximum until CI measures the shorter fixture-only home-summary bound; do not discount a local speedup from CI packing weights.
`tests/jg-board-gate.test.sh` (437 ms) postdates that refresh and carries a provisional local measurement until the next CI refresh replaces it, so the no-hint coverage guard keeps its margin.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`bin/jg-test-run.sh`](../bin/jg-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the three-tier timeout policy in [Timeouts](#timeouts) below.

Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `jg-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, Squad Lead lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/juggernaut/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/juggernaut/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/jg-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/behavior.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/jg-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/jg-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/jg-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
The longest script, `tests/jg-watcher-lock.test.sh`, is the indivisible floor for this layout.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
The baseline watch-triage samples range from 944375 to 1074843 ms, while each observed completed portable job adds at most 30 seconds beyond its summed scripts in these runs.
Even so, maxima from five runs do not establish a P95 or guarantee future headroom.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/jg-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R kunchenguid/juggernaut --dir "/tmp/jg-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/jg-serial/*/jg-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/jg-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/jg-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/jg-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/behavior.yml` owns the exact artifact names and aggregation wiring, and its `timing` job downloads and combines them.

## Lint partitions and end-to-end latency

`bin/jg-lint.sh` owns two canonical CI partitions, each attempting full source-aware ShellCheck analysis and running workflow validation and backend-purity checks.
CI requires its per-root bounds, so an unenforceable deadline or address-space limit refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/jg-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay, but the watcher-lock floor alone exceeds that objective.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The layout uses ten long-lived Linux jobs (six serial, two parallel, Herdr, two lint), plus short checks and macOS; the heavy ten run in `behavior.yml` and only the two lint partitions plus the short checks gate a pull request, so insufficient shared account capacity can still delay a merge's backstop.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/jg-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one three-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | coverage guard, repo invariants, shell syntax, smoke, fast evals, required verdict | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, portable serial shards, macOS stock Bash, timing aggregate | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps every ordinary test and lint lane on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |
| Eval | fast evals | 10 minutes | The set is seconds long; the bound leaves room for the runner's npm install of tasks-axi before the tripwire is reached. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values for the pull request gate, and [`.github/workflows/behavior.yml`](../.github/workflows/behavior.yml) holds them for the nightly and post-merge suite.
Each names a job's tier beside its `timeout-minutes`.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
