# Host memory shared sampler

Host memory shared sampler: run `done-done run -- bash core/host-memory/tests/jg-host-memory-shared.test.sh`; the real lifecycle entry starts the sampler for two fixture homes, and it proves one process serves both and each home records its own samples, a home whose watcher is gone is dropped while the other stays served, and the last home to stop ends the sampler. `bash tests/jg-supervise-daemon-single.test.sh` proves a second supervise daemon for one home refuses and leaves the first alone.
