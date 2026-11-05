# Report page leads with the Answer

## User outcome

A report page on the board opens with the answer to the owner's ask, in one short sentence, with the evidence below it. A Recon whose page opens with a finding or an example is stopped at cleanup and must repost the page under the same key.

## Drive

Run `done-done run -- bash tests/jg-brief.test.sh` for the scout instructions (the report's first section is the Answer; the picture heading repeats it; the opening check command is named). Run `bin/jg-report-opening-check.sh <report.md> --card <report.json>` on a page: it prints PASS, or REFUSED with the page opening beside the report Answer.

The cleanup journey is `test_scout_report_page_must_open_with_the_answer` in `tests/jg-teardown.test.sh`: a scout with a report page that opens with a finding is refused, and the same page reposted with the Answer in the picture heading is returned.

## Evidence

Capture the check output (REFUSED for the finding, PASS for the Answer) and the exit statuses in done-done's run evidence directory. Use a throwaway card file, never the owner's board.
