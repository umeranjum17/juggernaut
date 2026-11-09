# Codex squad lead supervised by the always-on daemon

Codex squad lead supervised by the always-on daemon: run `done-done run -- bash tests/jg-turnend-guard.test.sh` with the suite's log written into `$DONE_DONE_EVIDENCE_ROOT`; the real turn-end guard over a squad lead home with a live identity-matched daemon (`state/.lead-daemon`, no away flag) and a fresh beacon lets the turn end idle, a dead daemon, a stale beacon or a marker with no daemon still blocks, and the Codex repair line names `bin/jg-lead-daemon.sh start` instead of a foreground checkpoint (screen: none).
