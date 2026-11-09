# Quota failover install and live route recovery

[Quota failover install and live route recovery](../features/quota-failover-live-route.md): run `JG_TEST_FORK=<Juggernaut checkout> bash quota-failover/tests/install.test.sh` (install in every active home) and `bash quota-failover/tests/quota-failover-e2e.sh`; for the real product, `JG_CHECKOUT=<Juggernaut checkout> done-done run quota-failover-live-route` moves a real lab worker off a real HTTP 429 route to Claude Haiku through the lab watcher's own pass, and the worker finishes there.
