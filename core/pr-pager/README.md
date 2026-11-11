# pr-pager

Every open pull request pages the lead that answers for it until it merges or closes, with no model turn.

`pager.sh check <jg-home>` is the watcher check.
Each page is one printed line, which the watcher turns into a check wake in that home's queue.

## Who answers for a repository

`bin/jg-pr-owner.sh` owns one record: Main's `data/pr-owners.tsv`, one `<owner/repo><TAB><lead id>` line per repository.
A repository with no line belongs to Main, so no pull request is without a home.
A lead home reads the record through its parent binding; `bin/jg-pr-owner.sh mine <owner/repo>` says whether this home answers for a repository.
A home never pages for a repository another home answers for, and drops any episode it kept for one.

## What a page says

The address, the age, the commit count, and the next step read from `bin/jg-pr-state.sh`:

- `red check "<name>": fix its cause and push; never re-run or waive it`
- `conflict: rebase on the base branch and push`
- `draft: mark it ready for review`
- `no checks yet: push, or start the checks`
- `green: merge it`

The first page comes when the pull request is 15 minutes old (`JG_PR_PAGER_FIRST_MIN`).
The next ones come every `pr-page-minutes` (trunk policy, default 60) while it stays open.
After 6 pages in a row with the same next step, a lead home appends one `note` to its parent channel so Main hears of it; Main's own pages go no further.
A page never calls `bin/jg-captain-say.sh`: the owner is not paged.

## A due release

A local-trunk project whose trunk holds `release-after-commits` unreleased commits (default 10), or whose oldest one is past `release-after-hours`, and which has no open pull request from its trunk branch, is paged the same way (episode `release`).
This is the rule of `jg-trunk.sh due` plus the commit count; it is read here without taking the trunk lock or touching the clone's guard.

## Episodes

One file per pull request at `state/.pr-pager/<owner__repo>/<number|release>`: `since pages same last mainpaged step`.
It ends when the pull request leaves the open list.
A forge failure keeps every episode and is retried next sweep.
The episodes are not in `state/.waiting-timers/`: that ladder walks task records, and its readers count each file there as an open lane wait.

## Why the red-CI ticket filed nothing for pull request 813

`merge-on-green.sh` runs `red-ci-ticket.sh` last, after the stale alarm, the ready batch and the stranded sweep, and gives it only what is left of one 30-second check limit (`JG_RED_CI_LIMIT`, `DEADLINE = start + 24 s`).
The script checks that limit before every repository and stops silently when it has passed, with no filing and no memory folder.
Home data showed exactly that: no `red-ci-ticket` folder, no ticket for the red runs.
The pager covers the open pull request half of that gap: its own check, its own limit, and a red check reaches the lead every hour by name.
The default-branch half stays starved; that is a follow-up (give the step its own check).

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check, writes `state/pr-pager.check.sh`, and registers it.
`unwiring.sh [--dry-run] <jg-home>` is the rollback.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`tests/jg-pr-pager.test.sh` (about 3 s).
