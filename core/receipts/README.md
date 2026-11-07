# receipts

The completion-receipt publisher and acceptance helpers run from this feature;
the fork optionally sources them from `bin/jg-dod-lib.sh`.
The publisher reads fork libraries from `$JG_FORK_BIN`, else `$JG_HOME/bin`.

The fork's done-acceptance hook delegates to `jg_receipts_accept_done`.
Its local merge and both PR merge paths delegate to `jg_dod_receipt_accept`.
The feature owns brief rendering, receipt inheritance, promotion and publishing; `policy/gate/receipt.rego` decides whether a receipt is accepted, and `jg_dod_receipt_accept` reads the task record and the receipt file into facts and prints the message for the reason it gives.
A task bound to a pull request that was closed without merging may take a receipt for another open pull request of the same repository only when `git cherry` shows every commit the closed one carried has a patch-equivalent in the candidate head (`jg_receipts_superseded_copy_ok`); `tests/receipt-superseded-copy.test.sh` proves both directions.
`jg_receipts_pr_candidate` is the receipt-candidate hook `bin/jg-pr-check.sh` calls: for a pull request outside the worktree's origin repository, or while the merge path records it (`JG_PR_CHECK_MERGE=1`), it prints the verified PR head, otherwise nothing, so the worker HEAD stands. A lane that holds several pull requests therefore lands each with the receipt for its own head and name; the receipt file holds one at a time, so publish the next before landing it (`tests/receipt-multi-pr-lane.test.sh`). It prints nothing when the head is unverified and always exits 0.

`tests/receipts-hook-e2e.sh` (set `JG_TEST_FORK`) copies the real fork scripts,
runs its done-acceptance, local-delivery, and PR-merge integration journeys with
the feature loaded, then checks the helpers, the PR candidate hook through the real `jg-pr-check.sh`, and absent-add-on behavior.
`run-proof.sh` runs that journey under done-done (`receipts-pr-candidate`).

## Layout

- `bin/jg-run-receipt.sh` — publishes the completion receipt for one task's
  current candidate into `state/<id>.run-receipt.json`, embedding the
  evidence file's contents in the receipt. It sources `jg-dod-lib.sh`,
  `jg-wake-lib.sh` and `jg-backlog-transition-lib.sh` from its own directory
  and serializes publication with the task control lock; those sibling
  libraries did not move, so the moved copy only runs with the fork tree
  around it (see the proof below).

## Frozen contract

- CLI: `JG_HOME=<supervising-home> jg-run-receipt.sh <task-id> PASS|FAIL
  <evidence-file> [candidate-repo]`; the candidate repo defaults to the
  current directory and `JG_HOME` must be set explicitly. `--help` prints
  usage and exits 0.
- Receipt: `state/<id>.run-receipt.json` with schema 1 fields
  `{schema:1, task, mode, spawn_gen, head, pr, verdict, at, evidence}`, where
  `head` is the candidate repo's HEAD commit, `pr` is the pull request the
  receipt covers (`JG_RECEIPT_PR`, which an export and a one-shot command
  prefix both set, else the candidate's open pull request, the recorded
  branch's open pull request, or the task record's `pr=`), `at` is Unix time,
  and `evidence` is the evidence file's full contents (it must be nonempty;
  the file is embedded, never stored as a pointer).
- Guards: PASS requires a clean candidate tree, and the task meta must carry
  a ship delivery mode (`local-only`, `direct-PR` or `no-mistakes`). A
  `JG_RECEIPT_PR` that is set but names nothing is refused and published
  nowhere: acceptance compares that field with the recorded `pr=`, so an
  empty one blocks a lane that did everything right.
- Exit codes: 0 on publication (prints
  `receipt: <id> <VERDICT> head=<sha>`), 2 on usage errors (bad arguments,
  bad task id, verdict not PASS or FAIL), 1 on runtime failures (task
  metadata or evidence missing, `jq` unavailable, spawn-generation or
  atomic-transition failure, wrong mode, dirty tree on PASS, a
  `JG_RECEIPT_PR` that names no pull request).

## Provenance against the fork

Every moved file was compared byte for byte against its fork source at
`umeranjum17/juggernaut@0689b4b9d9ab3594f846cfe07c400edfa58244bf` at move time;
the mode is `100755` on both sides. One deliberate contract change since then
is recorded here, and the fork needs the same change the next time it syncs:

| moved file | fork source | sha256 | divergence |
|---|---|---|---|
| `receipts/bin/jg-run-receipt.sh` | `bin/jg-run-receipt.sh` | `5a40caf469d85a268e1c7410a8fb8d7201519eda2147c8f3dab55c1dfb5e563a` | the pull request is read through the script's own environment, the candidate's open pull request, the recorded branch's open pull request and the record's `pr=`, and a `JG_RECEIPT_PR` set but naming nothing is refused instead of recorded empty |

Treat any further diff against the fork file as a contract change, not a
refactor.

## Side-by-side proof (re-run before the hook swaps the dispatched path)

1. Unpack the fork tree at the commit above into two scratch roots:
   `git -C <fork> archive 0689b4b9d9ab3594f846cfe07c400edfa58244bf | tar -x -C <rootA>`,
   then `cp -a <rootA>/. <rootB>/`.
2. In `rootB` only, overwrite `bin/jg-run-receipt.sh` with the moved file;
   `diff -r <rootA> <rootB>` must show only the publisher, with the divergence
   recorded in the table above, and its sha256 and mode must match that row.
3. Run `tests/jg-dod-lib.test.sh` in the fork scratch tree (it exercises
   receipt publication and acceptance; `jg-dod-lib.sh` itself stays in the
   fork and is NOT moved); one PASS proves the moved publisher still runs
   against the fork libraries.
4. Run the repo CI gate (shellcheck plus syntax check over every feature
   script) on the PR head.

A task holds one receipt slot, `state/<id>.run-receipt.json`. The publisher also keeps the newest receipt for each head it published as `state/<id>.run-receipt.<head>.json`. `jg_dod_receipt_accept` and `merge-on-green.sh` call `bin/jg-receipt-restore.sh` to put the receipt for the head being merged back into the slot, so a lane with several pull requests needs no hand republish before each one. Acceptance still judges the restored receipt by its own rules.
