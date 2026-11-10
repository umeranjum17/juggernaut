# Afk daemon resends its own unsent text

Afk daemon resends its own unsent text: run `done-done run afk-daemon-resend` (it runs `bash tests/jg-supervise-daemon-resend.test.sh` and writes its log into `$DONE_DONE_EVIDENCE_ROOT`); when a swallowed Enter leaves the daemon's own digest typed in the supervisor composer, the next try submits it once with Enter only and the second digest follows as its own line, and text without the daemon's own record is never keyed (screen: none).
