# A finished lane lands with no model awake

Run `done-done run -- bash -c 'set -e; { bash bin/jg-test-run.sh core/sentinel/tests/jg-sentinel-model-relaunch.test.sh core/sentinel/tests/jg-sentinel-one-copy.test.sh core/sentinel/tests/jg-sentinel-false-restart.test.sh; JG_TRUNK_OUTER_ONLY=1 bash tests/jg-trunk-live.test.sh; bash tests/jg-status-kick.test.sh; bash tests/jg-watch-fast-dispatch.test.sh; bash tests/jg-auto-dispatch-batch.test.sh; } >> "$(printenv DONE_DONE_EVIDENCE_ROOT)/no-model-landing.log" 2>&1'`.
The `core/sentinel/bin/jg-sentinel.sh` tests drive the installed and forwarded entries over isolated homes with a stub Herdr.
The `bin/jg-delivery-tick.sh` journey counts one delivery pass for an unchanged home and uses real Git and the watcher to land a missed completion on the due repair sweep.
The `bin/jg-lavish-guard.sh` journey covers status changes, immediate completion and a completion during another pass.
The `bin/jg-watch.sh` journey exercises the per-home repair schedule in `bin/jg-wake-lib.sh`, trusted registration changes and sharing exact GitHub queries with an explicit credential.
The `core/auto-dispatch/dispatch.sh` journey proves the decision lookup is batched and a running pass absorbs periodic requests while other watcher checks proceed.
