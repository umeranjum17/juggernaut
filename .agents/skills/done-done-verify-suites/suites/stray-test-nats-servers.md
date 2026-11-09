# Stray test nats-servers

Stray test nats-servers: run `done-done run stray-nats-reap` (`bash journeys/stray-nats-reap.sh`, which runs `tests/jg-stray-nats-reap.test.sh`, then `bin/jg-stray-nats-reap.sh` with no flags on this machine); fake servers prove a dry run stops nothing, `--stop` stops only old servers whose config or store path is inside the allowlist, and a real home's bus server is skipped. The live step only lists; the stop is run by the lead.
