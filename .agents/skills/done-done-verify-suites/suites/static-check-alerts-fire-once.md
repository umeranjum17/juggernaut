# Static check alerts fire once

Static check alerts fire once: run `bash tests/jg-installed-drift.test.sh` and `bash tests/jg-board-gate.test.sh`, with `bash tests/jg-fleet-heartbeat.test.sh` and `bash tests/jg-pr-pager.test.sh` named by their own suites.
A matching installed copy prints nothing, and an unchanged set of drift findings prints once, with 0 repeats over three further sweeps.
A changed set prints at once, a clean pass clears the record so the drift prints again when it returns, and the long reminder (`JG_INSTALLED_DRIFT_REMIND_SECS`) prints it again.
The board gate reports one unproven merge once under its default long reminder across repeated sweeps (screen: none).
