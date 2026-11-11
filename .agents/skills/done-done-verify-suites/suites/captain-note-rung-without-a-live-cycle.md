# Captain note rung without a live cycle

Captain note rung without a live cycle: run `done-done run -- bash tests/jg-sentinel-inbox-ring.test.sh`; the real `bin/jg-inbox.sh` and `bin/jg-sentinel.sh ring` over a fixture home prove a queued captain note reaches the primary as a doorbell in about a second when no watcher beacon is fresh, a fresh beacon keeps the ring away, and a repeat ring for the same queued notes waits out the rewake window, where before the note waited for the stale-beacon grace and the next tick (screen: none).
