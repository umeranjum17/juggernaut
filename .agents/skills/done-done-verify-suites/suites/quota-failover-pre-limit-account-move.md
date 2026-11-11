# Quota failover pre-limit account move

[Quota failover pre-limit account move](../features/quota-failover-prelimit.md): run `bash quota-failover/tests/quota-failover-e2e.sh`; passes 11 to 13 prove an idle working worker leaves an account at or below 15% once, while busy workers, healthy accounts and stale readings stay and Codex only wakes the home.
