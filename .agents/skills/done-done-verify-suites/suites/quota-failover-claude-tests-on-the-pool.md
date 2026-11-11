# Quota failover Claude tests on the pool

Quota failover Claude tests on the pool: run `bash quota-failover/tests/quota-failover-e2e.sh`; passes 14 and 15 prove a Claude route test that names no account runs on the pool's pick (or its last good pick when the pick fails) and never on the default login.
