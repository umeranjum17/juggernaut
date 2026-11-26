# Host memory shared sampler

Host memory shared sampler: run `done-done run core-host-memory-shared-test` or `done-done run -- bash core/host-memory/tests/jg-host-memory-shared.test.sh`.
The real lifecycle entry registers three fixture homes and the guard reads a distinct available-memory value on every fixture meminfo open.
The journey proves that all three homes record the same measurement in consecutive intervals and only the home whose thresholds classify it as ALERT receives a wake.
It also proves a home whose watcher stops is dropped and the last home to stop ends the sampler.
`done-done run jg-jev-mem-guard` drives the real guard over changing fixture pressure and proves diagnostics and history use the collector's measurement while admission checks current pressure.
`bash tests/jg-supervise-daemon-single.test.sh` proves a second supervise daemon for one home refuses and leaves the first alone.
