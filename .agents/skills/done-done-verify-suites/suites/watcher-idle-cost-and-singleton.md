# Watcher idle cost and singleton

Watcher idle cost and singleton: run `done-done run -- bash tests/jg-watcher-lock.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real watcher in a private idle home keeps its child recorder (the once-a-second ledger of child identities that eviction and lock removal retire from) under 2% of one core over 20 seconds beside 500 extra host processes, and two simultaneous starts leave exactly one live watcher.
The recorder walks only its own tree through the kernel child lists, so its cost no longer grows with the host process table; on the old full-table walk the same case measured 24% (screen: none).
