# A repeat of the same Herdr ids is no restart

A repeat of the same Herdr ids is no restart: run `done-done run sentinel-false-restart` (the journey runs `core/sentinel/tests/jg-sentinel-false-restart.test.sh`); the real `jg-sentinel.sh tick` against a stub `herdr` that names a socket file the test owns proves the first look only records the identity, the same socket ids twice run no recovery pass, a real change reports one restart and runs exactly one pass even when a lane's relaunch fails (where before the old ids came back every tick and the pass ran every minute), a second real change runs one more, and a lane not settled yet continues its own episode without a restart report until it settles (screen: none).

The delivery part of the journey counts actual passes for two fixture homes and proves that idle ticks skip both homes, a status change selects its own home, and a staggered repair catches a missed stop removal.
