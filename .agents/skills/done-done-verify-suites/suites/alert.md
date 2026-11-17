# Alert table

Alert table: run `done-done run alert` (`bash journeys/alert.sh`, which runs `tests/jg-alert.test.sh`, `tests/jg-task-inbox-alert.test.sh` and `core/undelivered-alert/tests/undelivered-alert.test.sh` and writes its log and `steps.json` into the run's folder); it lints `core/machines/tables/alert.tsv` (5 states, 8 moves), calls the real `bin/jg-alert.sh` in a fixture home, raises a stuck wait in each of the four delivery modes (one P2 alert at rung 2), keeps quiet rows quiet, raises none for a home with `supervision-down` open and releases them when it resolves, gates the fires-at time by the limit of its kind, climbs the ladder to its authority ceiling, repeats at the top three times and then makes the alert stuck with one escalation-stuck recovery, rings each of the new rows (wrong-repo, lock-held, orphan-process, escalation-stuck, fleet-blocked, quota-unused, quota-blind) and the 4 h kind of stranded, drives open, acknowledged, inhibited and resolved, delivers a ring to its holder as one wake (a tick ring is only recorded), and raises `undelivered` once from an unread steer on a dead endpoint (no stale wake) and from a refused captain message; it reads only generated fixtures (screen: none).

Recipient authority: `JG_BEADS_TEST_BD="$(command -v bd)" JG_BEADS_TEST_DOLT="$(command -v dolt)" done-done run -- bash journeys/alert.sh` also drives `tests/jg-alert.d/17-authority.sh` with real pinned Beads gates.
It exhausts team engineering and review alerts, refuses direct and forged owner rungs, rejects missing and stale authority, and preserves the source age and Main recovery.
All four typed security producers and a matching open owner gate publish to the real bus's isolated event journal; a closed gate or old source episode publishes nothing.
The transport points at closed localhost port 1, so this proves publication authority without claiming chat delivery or sending live messages.
Actor routing, action-evidence closure and unified deadlines are outside this authority slice.

For a candidate that changes the producer bindings, seal the alert journey, its presentation and producer regressions, and changed-shell lint together:

```sh
JG_BEADS_TEST_BD="$(command -v bd)" JG_BEADS_TEST_DOLT="$(command -v dolt)" done-done run -- bash -c '
bash journeys/alert.sh && bash tests/jg-machine-diagram.test.sh &&
bash core/key-in-env-check/tests/key-in-env-check-e2e.sh &&
bash core/owner-guard/tests/scan-e2e.sh && bash tests/jg-guard-host.test.sh &&
bash bin/jg-lint.sh bin/jg-alert.sh bin/jg-alert-authority-lib.sh bin/jg-watch.sh core/delete-guard/check.sh core/owner-guard/scan-check tests/jg-alert.test.sh tests/jg-alert.d/07-the-ladder.sh tests/jg-alert.d/13-a-security-producer-raises-one-p0-alert-.sh tests/jg-alert.d/14-h14.sh tests/jg-alert.d/17-authority.sh tests/jg-machine-diagram.test.sh journeys/alert.sh &&
bash bin/jg-doc-audience-check.sh'
```

Set `JG_CAPTAIN_CHANNEL` to a task-owned channel file with `mode shadow` and `dapr-http-url http://127.0.0.1:1` for the producer regressions.
