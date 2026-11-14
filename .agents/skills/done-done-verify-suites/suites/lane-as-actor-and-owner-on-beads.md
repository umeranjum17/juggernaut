# Lane as actor and owner on Beads

Lane as actor and owner on Beads: run `done-done run -- bash tests/jg-beads-native-n8.test.sh` with `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT` naming the pinned builds; on a real store a write made from a lane leaves that lane as the comment author and the actor of the row's events, a start with no lane names the caller's actor or `juggernaut`, a held in-flight row keeps its assignee and reads in flight with no `hold_from`, a held queued row stays queued, and the store's tables, `issues` definition and CHECK rules are unchanged.
