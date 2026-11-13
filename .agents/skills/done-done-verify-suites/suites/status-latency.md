# Status latency

Status latency: run `done-done run status-latency` (which runs `bash tests/jg-status-latency.test.sh` and writes its output into `$DONE_DONE_EVIDENCE_ROOT`); the real watcher runs on a throwaway home, a real failed status line wakes its owner inside 60 s and gets one row with the measured seconds and no alert, a done-class line with no wake after 200 s raises one `undelivered` alert and one row, a second tick adds nothing, and a line the watcher wakes 300 s late gets a row with the real delay and an alert that names it (screen: none).
