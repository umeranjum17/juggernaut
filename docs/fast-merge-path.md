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
- `Changed tests` - the suite scripts the change's paths map to
  (`bin/jg-test-run.sh --changed --base <base> --exclude-family real-herdr-gated --max-weight-ms 60000`): a suite whose recorded time is over a minute is named in the log and runs in the post-merge lane instead.

`CI required` is still the one required status check, and `bin/jg-ci-required.sh`
now holds two lane sets: the fast set for a `pull_request` event and the full set
for a `push`.
Four area suites run on every `push` to `main` or `release/**` (the release gate),
and on a pull request only when it touches their area (`bin/jg-ci-scope.sh` owns
the paths): `Bus service` (core/bus, bus scripts, install, bootstrap), `Shell syntax`
(any `.sh`), and `Smoke` plus `Fast evals` (bin/ or core/). An untouched area skips,
and `CI required` refuses a touched area whose suite was skipped or did not report.
The rest run after the merge instead: the behaviour suite
(`behavior.yml`), and the core journeys (`core-suites.yml`).
An unreadable diff still widens the pull request to the full set.

## 2. The proof is keyed to the tree

`bin/jg-local-suite.sh` seals `state/<task>.local-suite` with the tree it proved
as well as the head it ran at.
`bin/jg-pr-merge.sh` accepts that receipt when it proves the live head's tree, so
a body edit, a re-push of identical content, or a squash of the same change never
forces a re-seal: the receipt already names those files.
A receipt that exists and does not prove the tree refuses by name rather than
quietly turning back into a CI wait.

## 3. Green means merged, with no model turn in between

`bin/jg-merge-on-green.sh sweep` is the deterministic watcher.
`bin/jg-watch.sh` runs it every `JG_MERGE_ON_GREEN_INTERVAL` seconds (default
20), so a green required set is acted on in seconds rather than on the next
supervision cycle.
For every task with a recorded `pr=`, it asks `bin/jg-pr-state.sh --waiting-for`
what the change is waiting on:

- a draft, conflicts, a red required check, or a required check that has not
  reported is an ordinary wait: nothing runs and nothing is raised;
- the merge call is acted on, but only under authority the sweep can name: the
  project's registered `+yolo` posture, or `bin/jg-merge-on-green.sh approve
  <task-id>`, which the lead records after the captain says to land that pull
  request;
- a refused merge raises exactly one alert per task and head, naming the gate's
  own refusal text, and never touches the pull request.

A pull request still in flight carries one `juggernaut/waiting-for: <what>` line
in the captain-facing report, taken from `bin/jg-pr-state.sh --waiting-for`.

## 4. Post-merge failures are fixed forward

A merge into `main` or `release/**` starts the full CI run, and
`bin/jg-post-merge-ci.sh` files exactly one fix-forward item naming the failing
run and queues the wake that reaches its owner.
Nothing is reverted, and no other merge waits on it.

## 5. The number

Every merge the sweep lands appends one row to `data/merge-latency.tsv`: the
task, the pull request, the `done` epoch, the merge epoch, and the whole minutes
between them.
`bin/jg-merge-on-green.sh latency` prints the rows with the worst and median
minute count, and a merge over `JG_MERGE_LATENCY_LIMIT_MINUTES` (default 5)
raises one alert naming the number.
A five-minute path that silently takes eleven is the failure this row exists to
make visible, so read the recorded minutes rather than any promise about them.
