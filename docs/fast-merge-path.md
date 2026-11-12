# The fast merge path

The captain's target is a finished change merged on main within five minutes of
the worker's `done` line, with no waived check and no skipped required check, so
the required path itself is what had to get fast.
This page is the contract for how it is fast and how the number is measured.
Nothing here relaxes a safety boundary: the merge gate is still the only way a
pull request lands, and nothing is ever reverted.

## 1. The required set is only the fast set

A pull request owes three things, and `.github/workflows/ci.yml` runs exactly
them:

- `Repo invariants` - the seconds-long file comparisons and the coverage proofs.
- `Lint <n>` - the sharded lint over the files the change touched
  (`bin/jg-lint.sh --changed-base <base>`), not over the whole tree.
- `Changed tests <n>` - the suite scripts the change's paths map to
  (`bin/jg-test-run.sh --changed --base <base> --exclude-family real-herdr-gated --max-weight-ms 60000 --shard <n>of8`): a suite whose recorded time is over a minute is named in the log and runs in the post-merge lane instead.
  The selection is split across eight runners at once, by recorded time, so the slowest required lane is about an eighth of the work.

`CI required` is still the one required status check, and `bin/jg-ci-required.sh`
now holds two lane sets: the fast set for a `pull_request` event and the full set
for a `push`.
Four area suites run on every `push` to `main` or `release/**` (the release gate),
and on a pull request only when it touches their area (`bin/jg-ci-scope.sh` owns
the paths): `Bus service` (core/, bin/, defaults/, install, the pinned versions, the bus doc and test helpers),
`Shell syntax` (any `.sh`), and `Smoke` plus `Fast evals` (bin/, core/ or the pinned versions).
A change to `.github/` owes all of them, because the workflow defines the lanes.
An untouched area skips, and `CI required` refuses a touched area whose suite was skipped or did not report.
A skip is only safe if the area covers every file its suite reads, so each of these lanes runs its suite through
`bin/jg-ci-area-reads.sh`, which traces what the suite opens and fails, naming the file, when one is outside the area.
The rest run after the merge instead: the behaviour suite
(`behavior.yml`), and the core journeys (the `core-*` entries of `.done-done.yaml`, tier local).
An unreadable diff still widens the pull request to the full set.

## 2. The proof is keyed to the tree

`bin/jg-local-suite.sh` seals `state/<task>.local-suite` with the tree it proved
as well as the head it ran at.
`bin/jg-pr-merge.sh` accepts that receipt when it proves the live head's tree, so
a body edit, a re-push of identical content, or a squash of the same change never
forces a re-seal: the receipt already names those files.
A receipt that exists and does not prove the tree refuses by name rather than
quietly turning back into a CI wait.

The local trunk lander keeps the same tree key for its full gate.
When that gate fails, it reruns the failing scripts on the trunk tip's tree once, stores the tip's result by tree, and charges the lane only for failures that differ from the tip's.
`docs/trunk-flow.md` owns the rule.

## 3. Green means merged, with no model turn in between

`core/merge-on-green/merge-on-green.sh check <home>` is the deterministic watcher check,
installed once per home by `core/merge-on-green/wiring.sh` and run by the watcher with
no model turn in between, so a green required set is acted on in seconds rather than
on the next supervision cycle.
For every task with a recorded `pr=` and `pr_head=`, it reads the task's resolved state
(`bin/jg-crew-state.sh`):

- a draft, conflicts, a red required check, or a required check that has not
  reported is an ordinary wait: nothing runs and nothing is raised;
- a red run is never answered by a re-run: the same sweep files one root-cause ticket per
  red run id (`[blocker] CI red: <workflow> <job>: find the root cause`, keyed `ci-red-run-<run id>`)
  for the owning lead, and `core/merge-on-green/README.md` "Red-CI ticket" owns the rule;
- each pull request is judged on its own checks alone, so a green pull request into
  a release branch merges even while another pull request into the same branch is
  red, and the release runs its checks on whatever head is current;
- the merge call is acted on, but only under authority the check can name: the
  task's `yolo=on`, or `merge=approved` in its record, which the lead writes after
  the captain says to land that pull request;
- a refused merge raises exactly one alert per task and head, naming the gate's
  own refusal text, and never touches the pull request.

Open pull requests are counted per repository as well.
Over `config/open-pr-cap` (a whole number, default 8) the check raises one alert naming the repository, the count and the cap.
The alert repeats only when the count changes, and a repository back under the cap forgets it.

A pull request still in flight carries one `juggernaut/waiting-for: <what>` line
in the captain-facing report, taken from `bin/jg-pr-state.sh --waiting-for`.

A red CI run is re-run only through `bin/jg-ci-rerun.sh <run id> [--repo <owner/repo>]`.
For a run that ended failure, timed_out or startup_failure it refuses, with a non-zero exit, until the run's
ticket `ci-red-run-<run id>` (filed by the watcher, `core/merge-on-green/README.md` "Red-CI ticket") holds a
body line that starts `root-cause:` and names the cause.
A green, cancelled or running run is re-run as `gh run rerun` would.

## 4. Post-merge failures are fixed forward

A merge into `main` or `release/**` starts the full CI run, and
`bin/jg-post-merge-ci.sh` files exactly one fix-forward item naming the failing
run and queues the wake that reaches its owner.
Nothing is reverted, and no other merge waits on it.

## 5. The number

Every merge the check lands appends one row to `data/merge-latency.tsv`: the
task, the pull request, the `done` epoch, the merge epoch, and the whole minutes
between them.
A merge over `JG_MERGE_LATENCY_LIMIT_MINUTES` (default 5)
raises one alert naming the number.
A five-minute path that silently takes eleven is the failure this row exists to
make visible, so read the recorded minutes rather than any promise about them.

A local-trunk project has no pull request to merge, so its number is the
landing: the check `core/trunk-latency` writes one row per landing to
`data/trunk-latency.tsv` with the minutes from the lane's last `done` line to
its landing row and the stage that held most of them (the queue before the
landing starts, the landing's start lock and rebase, or the gate).
A landing over the same `JG_MERGE_LATENCY_LIMIT_MINUTES` raises one alert that
names that stage.
