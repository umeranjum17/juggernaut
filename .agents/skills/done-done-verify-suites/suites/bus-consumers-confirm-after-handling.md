# Bus consumers confirm after handling

Bus consumers confirm after handling: run `done-done run -- bash tests/jg-wake-engine.test.sh` (and `bash tests/jg-wake-watcher.test.sh`) with the logs written into `$DONE_DONE_EVIDENCE_ROOT`; on a throwaway accounts server the real engine, router and watcher show a failing reply left unacknowledged (`acked=0`) while it is retried, then on `state/bus/router.dead.jsonl` with its cause and closed after the last try, and a handled wake acknowledged only after its render (screen: none).
