# A proved head stays proved when the fleet moves to another account

A proved head stays proved when the fleet moves to another account: run `done-done run -- bash tests/jg-trunk-proof-account.test.sh`; it saves a proof under account A, runs the real `bin/jg-trunk.sh` landing check under account B, and shows the proof admitted, the lane landed, and the landing row naming both accounts, while the worker's own done under account B is still refused (screen: none).
