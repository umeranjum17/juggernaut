# Alert recipient authority and actor routing

Run the [alert suite](../suites/alert.md) for recipient-authority and actor-routing integration coverage and their safety boundary.
The feature is part of `done-done run alert`.

The same suite proves action closure and the deadline: an acknowledgement never takes the alert's deadline, an unrelated done line or a rotated queue row never closes it, and `bin/jg-alert.sh resolve` refuses without source-clear proof (`tests/jg-alert.d/19-the-deadline-and-the-proof.sh`; report section 5.2, ban B10).

It also installs and runs the registered check from outside the repo to prove the named home raises the undelivered alert once per new message (`core/undelivered-alert/undelivered-alert.sh`, `core/undelivered-alert/wiring.sh`, `core/undelivered-alert/tests/undelivered-alert.test.sh`).

Sources: `bin/jg-alert.sh`, `bin/jg-alert-authority-lib.sh`, `core/machines/tables/alert.tsv`, `core/machines/alert.states`, `core/item-store/alertrules.py`, `core/item-store/schema.sql`, `tests/jg-alert.test.sh`, `tests/jg-alert.d/17-authority.sh`, `tests/jg-alert.d/18-routing.sh`, `tests/jg-alert.d/19-the-deadline-and-the-proof.sh`, `bin/jg-parent-channel-lib.sh`, `journeys/alert.sh`.
Security producer integrations: `bin/jg-watch.sh`, `core/delete-guard/check.sh`, `core/guard-host/cmd/jg-guard-host/delete.go`, `core/key-in-env-check/key-in-env-check`, `core/owner-guard/scan-check`.
