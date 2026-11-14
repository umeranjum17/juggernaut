# Automatic filers file short titles

A ticket a script files by itself reads as plain words, with the detail in its body: run `done-done run filers-short-titles` (`bash journeys/filers-short-titles.sh`), which runs `bash tests/jg-post-merge-ci-main.test.sh`, `bash tests/jg-trunk-gate.test.sh`, `bash tests/jg-trunk-shard-ticket.test.sh`, `bash core/merge-on-green/tests/red-ci-ticket.test.sh` and `python3 -I core/report-actions/tests/test_report_actions.py`, and with `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT` set, `bash tests/jg-inbox.test.sh`.
Each suite checks the title the filer stored against the title rule (`tests/title-rule-lib.sh`): 2 to 7 words, at most 48 characters, no tag, id, URL or path, with the label in `-l` and the run, test or branch in the body (screen: none).
