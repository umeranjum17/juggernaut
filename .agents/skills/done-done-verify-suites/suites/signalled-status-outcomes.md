# Every signalled status outcome

Source: `bin/jg-wake-drain.sh`, `bin/jg-wake-status-lib.sh`, and [the transition table](../../../../core/machines/tables/wake-status.tsv).
Run `done-done run signalled-status-outcomes` on isolated synthetic homes; `tests/jg-wake-next.test.sh` drives the real CLI and daemon handoff and captures `six-signals.log`, `outcomes.log`, and `steps.json`.
Drive `bin/jg-wake.sh next` with six signalled status files, with a report buried before later working lines, and with done, failed, PR, landed, blocked and needs-decision lines.
Capture the complete presentation, every outcome id, and the acknowledgement refusal with all queue rows retained.
Repeat through `bin/jg-wake-next.sh` and require every pending line and the same ids to replay.
Record a mixture of relay references and classification reasons through the drain's outcome commands; leave one outcome open and require acknowledgement to refuse, then handle it and require acknowledgement and its replay to succeed.
Require unknown ids, blank dispositions, foreign-home ids and foreign-actor ids to refuse.
After acknowledgement, append fresh lines and signal again; require only the new span to appear and require a fresh disposition for its outcome.
Also cover an append between presentation and acknowledgement, file rotation and an older cutoff.
Interrupted-output and branch-grant fault injection remain outside this journey; existing actor eligibility and cursor suites own those integration boundaries.
Save the real transcript, queue states and steps.json under done-done's evidence directory.
