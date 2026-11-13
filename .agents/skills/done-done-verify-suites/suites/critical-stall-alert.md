# Critical-stall alert

Critical-stall alert: run `done-done run -- bash core/critical-stall/tests/critical-stall.test.sh` (it writes `critical-stall.log` into `$DONE_DONE_EVIDENCE_ROOT`); a fixture home with stub probe, forge and card commands and the real `bin/jg-alert.sh` proves one central `stranded` alert (one lead wake) and one card for a critical row pending 24 h with no recent commit, nothing on the next sweep or after a fresh commit, a no-PR alert, the first-seen clear on live, the stale-PR-alarm card skip, and the wiring round trip.
