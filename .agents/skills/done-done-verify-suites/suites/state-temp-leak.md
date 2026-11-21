# State folder temp-file leak

State temp files never pile up: run `done-done run -- bash tests/jg-home-summary-refresh-async.test.sh` and `done-done run -- bash tests/jg-afk-telegram.test.sh` with the logs written into `$DONE_DONE_EVIDENCE_ROOT`; a summary refresh whose worker is killed with SIGKILL leaves its `.home-summary.json.*` and `.home-summary-error.*` files (T4 asserts the leak is real), the next refresh removes them, and a return's leftover `.afk-return-*` temp files go on the next `jg-afk-return.sh begin` while a file it does not own stays (screen: none).
