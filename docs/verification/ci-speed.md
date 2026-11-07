# CI speed: measured before and after

Date: 2026-11-02.
Host: GitHub-hosted `ubuntu-latest` runners, repository `umeranjum17/juggernaut`.
This record covers the pull request path of `.github/workflows/ci.yml` before and after the five changes of the CI speed series.
All minutes are medians of successful jobs unless a range is given.
Raw data is the output of `gh run list --workflow CI` and `gh api repos/umeranjum17/juggernaut/actions/runs/<id>/jobs`.

## Before: the last 150 CI runs

The window is 2026-11-01T12:31Z to 2026-11-02T02:45Z.
The table uses the 66 pull request runs created after the area scoping landed (2026-11-01T16:20Z).
Waiting is the time a job spent queued for a runner, setup is checkout and installs, running is everything else.

| Required job | Waiting | Setup | Running | Finished at (from run start) |
| --- | --- | --- | --- | --- |
| Repo invariants | 0.0 | 0.1 | 0.1 | 0.3 |
| Lint (4 shards) | 0.3 | 0.1 | 0.1 | 0.7 (90th percentile 2.5) |
| Shell syntax | 0.3 | 0.1 | 0.0 | 0.5 |
| Smoke | 0.3 | 0.1 | 0.0 | 0.5 |
| Fast evals | 0.3 | 0.1 | 0.0 | 0.6 |
| Bus service | 0.4 | 0.1 | 0.9 | 1.6 |
| Changed tests | 0.3 | 0.1 | 1.4 | 2.2 (90th percentile 6.6) |
| CI required | 2.4 | 0.1 | 0.0 | 2.6 |

A whole pull request run took 3.0 minutes at the median and 6.7 at the 90th percentile.
The runner queue was 0.1 minute on every job, so waiting on hosted runners was never the cost.
Of the 66 runs, 14 failed and 7 were cancelled.
The Changed tests step failed in 13 of the 14.

## After: the series combined

A throwaway branch merged all five changes on top of `release/c-3`.
Three runs of a one-line edit to `bin/jg-ci-required.sh` (it owes every area suite) took 1.8 minutes each:

| Required job | Finished at (from run start) |
| --- | --- |
| Repo invariants | 0.3 |
| Lint (4 shards) | 0.6 |
| Shell syntax | 0.6 |
| Smoke | 0.5 |
| Fast evals | 0.5 |
| Bus service | 1.6 |
| Changed tests (3 shards) | 0.5 to 0.6 |
| CI required | 1.7 |

That edit selects one test, so it does not show what the shards change.
A controlled comparison used one wide change (an edit to `tests/lib.sh`, which selects 138 tests) twice, with one shard and with three:

| Changed tests | Longest job | Whole run |
| --- | --- | --- |
| One shard | 12.2 | 12.6 |
| Three shards | 5.5 | 6.0 |

The wide changes seen before the series (nine runs where Changed tests took three minutes or more) took 5.4 minutes at the median for the job, with a range of 4.8 to 13.7.
The whole run took 7.1 minutes at the median.

## What each change did

- The pre-push hook (`bin/jg-install-pre-push.sh`) targets the 13 red Changed tests runs: it runs the same lint and fast tests before the push.
  It cannot be measured from CI.
- Three Changed tests shards: 12.2 to 5.5 minutes on the same 138-test selection.
- Blobless checkout: the checkout step in the three history jobs went from 5 to 6 seconds to 3 to 4 seconds; the history is 6.6 MB instead of 107 MB.
- Skip-logic test: no minutes.
  It found and closed real holes: a change to `toolchain.versions`, `bin/jg-stack.sh` or the workflow file itself skipped the Bus service and Smoke lanes green.
- Go build cache seeded from the release branch: a cold build is 2.4 seconds locally and 7 seconds on a runner, a warm one 0.15 seconds.
  The first hit shows after the first push that follows the merge.
  The ShellCheck, actionlint, nats and the backlog installs take 0 to 1 second, so they are not cached.

## Limits

- The lane that dominates a typical pull request is now Bus service at 1.6 minutes.
  It now runs on any change under `bin/` or `core/` because the skip-logic test showed it reads them.
- The three shards are not balanced (3.9, 3.9 and 5.5 minutes on the wide change) because the recorded test times that pack them were measured on serial runs.
  Refreshing `portable_serial_weight_hints` from CI would improve it.
- The post-merge Lint (4 shards, 7 to 8 minutes) is unchanged.
  One isolated shard of six heavy scripts runs alone for about seven minutes, so more shards alone do not shorten it.
