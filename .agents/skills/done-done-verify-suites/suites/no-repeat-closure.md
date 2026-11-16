# No-repeat closure gate

Run `JG_BEADS_TEST_BD=$(command -v bd) JG_BEADS_TEST_DOLT=$(command -v dolt) bash tests/jg-closure-gate.test.sh` on a disposable Beads store.
The real backlog close refuses a labelled fix when source history is missing and leaves an unlabelled close unchanged.
The interval evaluator accepts a complete record and refuses early closure and an unresolved interval.
Run `bash core/merge-on-green/tests/backlog-shipped-reconcile.test.sh` with the same environment to check pending-close retry and shipped-close behavior.
