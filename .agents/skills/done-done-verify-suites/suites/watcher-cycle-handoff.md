# Watcher cycle hand-off

Watcher cycle hand-off: run `done-done run jg-watch-handoff` (`bash tests/jg-watch-handoff.test.sh`) and `done-done run jg-supervision-host-hook`.
In throwaway homes with real watchers and arms, a `--take-over` adopts the running watcher instead of stopping it: the lock and beacon never change hands, the beacon stays inside the grace and the supervision read Main's lead check uses never reports the home down across more than one grace, and no cycle row records a taken-over or killed cycle.
An attached arm whose watcher delivered a wake with no successor reports it within the hand-off window, not the confirmation budget that grows with every registered check.
A no-follow arm (the detached Claude Stop-hook start and the sentinel) confirms a live cycle and leaves it to its owner instead of following it as a second arm.
The host group proves the next park adopts the cycle a main-only pass-through left, and that a park stopped mid take-over still leaves one arm on that cycle.
`bin/jg-watch-arm.sh`'s header owns the take-over, no-follow and hand-off window rules (screen: none).
