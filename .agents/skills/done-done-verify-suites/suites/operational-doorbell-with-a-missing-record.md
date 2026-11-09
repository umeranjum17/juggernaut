# Operational doorbell with a missing record

Operational doorbell with a missing record: run `bash tests/jg-doorbell-missing-record.test.sh` (or `done-done run -- bash tests/jg-doorbell-missing-record.test.sh` with the log and a `steps.json` written into `$DONE_DONE_EVIDENCE_ROOT`); a real tmux pane running `cat` proves a ring for a missing record is answered `record-missing` and never typed, a record removed between typing and Enter is cleared and not submitted, and a live record is delivered (screen: none).
