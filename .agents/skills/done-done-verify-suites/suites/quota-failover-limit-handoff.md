# Quota failover limit handoff

[Quota failover limit handoff](../features/quota-failover-limit-handoff.md): run `bash quota-failover/tests/quota-failover-e2e.sh` (passes 3 and 8); for a live check, a guarded `/tmp` lab worker on a low account stops on the usage limit, one quota-failover pass moves it to another account in the same worktree, and it continues the same work.
