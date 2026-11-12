# Hook beat

Hook beat: run `bash journeys/hook-beat.sh`; it proves `bin/jg-hook.sh`, `core/hooks/` and `bin/jg-beat.sh` through a real `bin/jg-spawn.sh` of a Claude lane, then runs each wired hook command with its payload on stdin.
A spawned Claude agent appends one timed line to `state/beats/<task-id>` at each turn start, tool batch, turn end, API error (with its error type) and session end, with no model turn; a failing hook exits 0 and writes nothing (screen: none).
