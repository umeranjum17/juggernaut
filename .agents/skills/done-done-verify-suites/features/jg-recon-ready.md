# Recon report relay recovers after an interrupted delivery

Run `done-done run jg-recon-ready` to exercise `bin/jg-delivery-tick.sh` and `core/recon-ready/ready.sh` through `tests/jg-recon-ready.test.sh`.
The fixture writes a finished Recon without starting a delivery tick.
Its board accepts the report card, then the posting command reports a failure before the tick can record the relay.
The next tick finds the card and records the relay.
A third tick confirms one card, one relay, and one post attempt.
The run captures the existing readiness and owner-timer checks alongside the recovery assertions.
