# quota-axi-pool

## User outcome

Dispatch `quota-axi --json` reports every registered Claude and Codex account: `default` is the worker with the most room, Main's own login is a separate reserved `main` row, and the quota wake and Lookout dashboard read the same view. Install over an existing foreign `~/.local/bin/quota-axi` symlink records its resolved target as upstream and restores that link on uninstall.

## Drive

`bash quota-axi-pool/tests/quota-axi-pool.test.sh` or `done-done run quota-axi-pool` (`bash quota-axi-pool/run-proof.sh`). Fixture Umer A/B, stub upstream ambient 11%; temp-HOME install over a fake foreign symlink (never real `~/.local/bin`); no login copy, no network.

`bash quota-axi-pool/tests/quota-axi-pool-recursion.test.sh` proves the wrapper cannot recurse through its own pick: the wrapper installed the way `install.sh` installs it, first on PATH, a stub upstream that records its callers, a stand-in pool tool that records its own invocation and exits. The Claude accounts reader must reach the upstream without the wrapper delegating, `JG_QUOTA_AXI_POOL_DEPTH=1` must send the wrapper straight upstream without delegating, and the same call without the variable must delegate carrying depth 1 (the control that makes the guard assertion mean something). No network, no login folder.

## Capture

`result.log` and `steps.json` under `$DONE_DONE_EVIDENCE_ROOT` (screen: none). Assert default=A=70 beside B=40 and reserved Main=5; the quota wake healthy, then exhausted when every worker is drained; Lookout lists all three accounts; ambient with no registered accounts and no pool; refuse with no upstream; install records resolved upstream and original link target; reinstall keeps them; uninstall restores the original link. For the recursion journey, assert the reader's run finishes, calls the upstream once and the pool tool never, and that the depth guard is what stopped the delegated call.
