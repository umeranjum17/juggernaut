# Merge-path lint receipt

Merge-path lint receipt: run `done-done run -- bash core/merge-on-green/tests/checks-lint-receipt-lock.test.sh`; the real `checks-lint.sh` and completion-receipt publisher run while a process holds the task control lock, and the log shows the holder's lint finishing in seconds with the PR url in the receipt, a standalone lint keeping `pr` equal to the PR url, and a publisher that does not own the lock still waiting.
