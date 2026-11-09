# Watcher handling confirmation

Watcher handling confirmation: run `done-done run -- bash tests/jg-watch-arm-handling-delivered.test.sh`; the real `jg-watch-arm.sh --handling-delivered` runs over a disposable home and the log shows an acknowledged generation answering 3 (superseded) even with an exited successor, a live successor still confirming (0), and a dead successor, a foreign lock, an absent marker and an unreadable marker each still answering 1.
