# Concurrent ship admission

Run `done-done run -- bash tests/jg-spawn-same-file.test.sh` with `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT` set to the pinned tools.
The real brief and spawn commands over an isolated fixture project launch two ships whose briefs name the same file, then defer a third ship with exit 75 when the project capacity is full (screen: none).
