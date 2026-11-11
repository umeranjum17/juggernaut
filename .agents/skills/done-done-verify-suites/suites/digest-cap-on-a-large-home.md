# Digest cap on a large home

Digest cap on a large home: run `done-done run axi-digest` (its case `test_digest_stays_under_its_cap_with_300_open_decisions` of `tests/jg-session-start.test.sh`); the real session-start command over a home with 320 open decisions and 600-section curated files prints at most 40000 bytes, keeps the lock result, the queued wake and its `WAKE_ACK_REQUIRED` line whole, ends the open decisions in their total and `bin/jg-wake-drain.sh --open-decisions`, and that command prints all 320; the case fails when the caps are lifted (screen: none).
