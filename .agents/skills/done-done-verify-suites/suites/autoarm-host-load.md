# Auto-arm under host load

Auto-arm under host load: run `done-done run -- bash tests/jg-autoarm-host-load.test.sh` (it writes its log into `$DONE_DONE_EVIDENCE_ROOT`); with a load-stretched guard grace of 600 s, the real Stop hook defers to a fresh arming claim but takes the next generation and arms when the claim's beat is 200 s old, the watcher's ready-stall pass beats after each of 5 slow captain-hold lookups, and a detached command (no harness in its ancestry) owns the lock of its own live Claude session while another session id or a dead pid does not (screen: none).
