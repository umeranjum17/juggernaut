# Fleet refresh and delivery repair

For `core/lookout-adapter/`, run `done-done run core-lookout-adapter-test` as described in the [Lookout adapter suite](../suites/lookout-adapter.md).
For `core/sentinel/`, `bin/jg-delivery-tick.sh` or `bin/jg-lease-tick.sh`, run `done-done run sentinel-false-restart` as described in the [sentinel suite](../suites/a-repeat-of-the-same-herdr-ids-is-no-restart.md).
For `bin/jg-trunk.sh`, `core/trunk-landing/ticket-trail.sh`, and `core/trunk-landing/trunk-landing.sh`, run `done-done run trunk-landing` to prove [ticket closure and repair from landing receipts](../suites/local-trunk-flow.md).
