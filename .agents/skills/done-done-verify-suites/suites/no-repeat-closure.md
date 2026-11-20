# No-repeat closure gate

Run `bash tests/jg-closure-gate.test.sh` on a disposable Beads store.
The real backlog close refuses a labelled fix when source history is missing and leaves an unlabelled close unchanged.
The interval evaluator accepts a complete record and refuses early closure and an unresolved interval.
Run `bash core/merge-on-green/tests/backlog-shipped-reconcile.test.sh` with the same environment to check pending-close retry and shipped-close behavior.
