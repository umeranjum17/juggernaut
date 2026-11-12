# Busy beat

Busy beat: run `bash tests/jg-busy-beat.test.sh`; it proves `jg_busy_beat_from_verdict` in `bin/jg-busy-lib.sh` through the real watcher caller `jg_busy_classify_meta`, a real busy record from `bin/jg-busy-event.sh`, and the real `bin/jg-beat.sh`.
A Pi agent (busy record) and a Codex agent (Herdr native busy reading) write the same beat lines in `state/beats/<task-id>` as a Claude agent's hooks: a turn start, a tool-batch beat at most every 30 seconds, one Stop, one SessionEnd; an unknown reading and a Claude lane write nothing (screen: none).
