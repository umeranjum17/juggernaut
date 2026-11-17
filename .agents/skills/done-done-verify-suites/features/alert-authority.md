# Alert recipient authority

Run the [alert suite](../suites/alert.md) for recipient-authority integration coverage and its safety boundary.
The feature is part of `done-done run alert`.

Sources: `bin/jg-alert.sh`, `bin/jg-alert-authority-lib.sh`, `core/machines/styles/alert-table.tsv`, `core/machines/tables/alert.tsv`, `core/machines/alert.states`, `core/machines/bin/alerttable.py`, `tests/jg-alert.test.sh`, `tests/jg-alert.d/17-authority.sh`, `journeys/alert.sh`.
Security producer integrations: `bin/jg-watch.sh`, `core/delete-guard/check.sh`, `core/guard-host/cmd/jg-guard-host/delete.go`, `core/key-in-env-check/key-in-env-check`, `core/owner-guard/scan-check`.
