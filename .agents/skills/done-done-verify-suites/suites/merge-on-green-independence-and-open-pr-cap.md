# Merge-on-green independence and open-PR cap

Merge-on-green independence and open-PR cap: run `bash core/merge-on-green/tests/merge-on-green.test.sh` (or `done-done run -- bash core/merge-on-green/tests/merge-on-green.test.sh` with the log in `$DONE_DONE_EVIDENCE_ROOT`); passes (q) and (r) prove a green PR merges in the same sweep while a sibling PR is red and untouched, and that a repo over `config/open-pr-cap` (default 8) raises one alert per count, with the cap raised by config, a bad config falling back to 8, a drop under the cap forgetting it, and a forge failure silent.
