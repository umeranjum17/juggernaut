# Deferred wake alert

Deferred wake alert: run `done-done run -- bash tests/jg-sentinel-wake-deferred-alert.test.sh`; the real `bin/jg-sentinel.sh` proves a first deferral opens a quiet episode, an episode that outlasts `JG_SENTINEL_DEFER_ALERT_SECS` sends exactly one captain alert, the same episode never alerts again, and a new episode after a delivered wake alerts once more (screen: none).
