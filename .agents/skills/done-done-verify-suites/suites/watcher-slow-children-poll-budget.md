# Watcher slow children poll budget

Watcher slow children poll budget: run `done-done run -- bash tests/jg-watch-poll-fork-budget.test.sh`; the real `bin/jg-watch.sh` runs 10 cycles in a throwaway home against counting stubs, and the comms-feed export, the escalation tick and the inactive-outcome scan each start on the first cycle and then every 4th cycle, never more than 4 times in 10 (screen: none).
