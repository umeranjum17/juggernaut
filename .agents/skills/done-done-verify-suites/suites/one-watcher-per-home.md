# One watcher per home

One watcher per home: run `done-done run -- bash tests/jg-one-watcher-per-home.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; real watchers and arms in a private home show that an arm against a live watcher attaches and starts nothing, that a beat 15 minutes late with the pid alive under a simulated load of 30 attaches with no failure line, that a dead pid with a stale beat is reclaimed, and that the daemon's and the Stop hook's arms together leave one watcher process (screen: none).
