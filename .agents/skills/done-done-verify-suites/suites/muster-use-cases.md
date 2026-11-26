# Muster use-case catalogue

Run `done-done run muster-use-cases` from the repository root.
The run saves output from the [catalogue integration test](../../../../tests/jg-muster-use-cases.test.sh) and the existing Muster regressions in `muster.log`.
The fixture approves a complete pack, then submits its plan with valid, missing and dangling catalogue links to the real verifier.
