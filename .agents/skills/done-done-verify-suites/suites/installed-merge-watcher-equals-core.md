# Installed merge watcher equals core

Installed merge watcher equals core: run `done-done run -- bash -c 'bash tests/jg-update.test.sh && bash core/merge-on-green/tests/merge-on-green-direct-pr.test.sh'`; `bin/jg-update.sh` runs `bin/jg-host-wiring.sh` from the updated checkout (a failing wiring is reported, never fatal), and the merge watcher records `pr=` and `pr_head=` from a worker's `done: PR <url>` line through `bin/jg-pr-check.sh --from-status`, once per distinct last status line, then merges with no lead turn. Fixture homes only; no live `state/`.
