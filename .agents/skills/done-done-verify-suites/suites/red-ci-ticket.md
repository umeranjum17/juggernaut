# Red-CI ticket

Red-CI ticket: run `done-done run -- bash core/merge-on-green/tests/red-ci-ticket.test.sh` (log in `$DONE_DONE_EVIDENCE_ROOT`); recorded run lists behind a gh-axi stub prove one root-cause ticket and one `line-red` alert per red run id (run id, URL, failing job, first failing log line), a green or superseded run filing none, a red run on an open PR head filing its own, no repeat on the second poll, and the check running from `merge-on-green.sh check`. Live, read-only up to the add: `core/merge-on-green/red-ci-ticket.sh check <home>`.
