# critical-stall

A critical migration row that sits pending with no commit raises one wake to Main and one board card, so a stall is never silent.

`critical-stall.sh check <jg-home>` is the watcher check.
It prints nothing and starts no model turn.
For each row of `bin/jg-critical-path.sh rows` that is not live, it records the time the row was first seen pending in `<home>/data/critical-stall/seen.tsv`.
A row that turns live is dropped from that file.
A home with no `critical=` key in `config/migration-card` has no rows, so the check changes nothing there.

A row is stalled when both are true:

- It has been pending for 24 hours or more.
- It has no pull request, or the newest commit on its pull requests is 24 hours old or more.

`config/critical-stall-hours` (a whole number) replaces the 24.

A stall raises the central `stranded` alert (`bin/jg-alert.sh raise` then `deliver`, subject the row's slug, so it reaches the lead) and one card through `bin/jg-question-card.sh` on the board `config/fleet-board` names.
Each alert is recorded once per row, pull request and newest commit in `data/critical-stall/alerts.jsonl`.
The next sweep raises nothing for the same stall.
A new commit changes the key, so a row that moves and then stalls again alerts again.
A forge failure is silent and retried on the next sweep.

When `stale-pr-alarm` already alerted on the same pull request after its newest commit, the card is skipped and the alert is still raised.
The captain then sees one card for one pull request.

## Wiring

`wiring.sh [--dry-run] <jg-home>` installs the check, writes the shim `state/critical-stall.check.sh`, and registers it with `bin/jg-check-register.sh`.
`unwiring.sh [--dry-run] <jg-home>` unregisters the check and removes the installed command.
`bin/jg-host-wiring.sh` runs the wiring for each home.

## Test

`bash critical-stall/tests/critical-stall.test.sh` runs the whole journey against a fixture home with stub forge, inbox and card commands.
