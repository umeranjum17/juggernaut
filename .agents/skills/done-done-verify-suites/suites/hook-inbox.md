# Hook inbox

Hook inbox: run `JG_BEADS_TEST_BD=$(which bd) JG_BEADS_TEST_DOLT=$(which dolt) done-done run hook-inbox` (`bash tests/jg-hook-inbox.test.sh`); it spawns a real Claude lane, sends real steers through `bin/jg-send.sh`, and runs the wired Stop and PostToolBatch hook commands with their payload on stdin through `bin/jg-hook.sh` and `core/hooks/inbox.sh`.
A steer waiting at a tool batch comes back as additional context and at turn end as a Stop block, in numeric order; it moves to `handled/`, the delivery record gets the `read` word with the hook event as pointer, the message machine reads it as `read`, an empty inbox prints nothing, and the agent's `jg-delivery.sh handled` claim ends it (screen: none).
