# report-page

No worker draws or writes report content by hand. `bin/jg-report-page.sh build <task-id>` writes a Recon's board page and card from its sources, and `check` refuses what the command did not write.

Sources in `data/<task-id>/`:

- `page.json`: `key`, `title`, `filed`, `filer`, `project`, optional `purpose` and `group`; `drawings` (`label`, `machine`); `counts` (`label`, `ledger`). Text may hold `{{count:<key>}}`.
- `report.md`: the Answer (section 1) becomes the card's `about` and the page text; the table rows of the Implementation plan (section 8) become the plan items.
- `ledger.tsv`: one `key<TAB>value<TAB>source` line per count. A count appears once; a missing key stops the build.
- A drawing comes from the machine's table through `bin/jg-machine.sh events`. Columns follow the distance from the first event; no coordinate is typed.

Outputs in `board-report/`: `page.html` (first line a comment) and `report.json` (field `built_by`). Each holds `jg-report-page sha256=<content hash> inputs=<hash of the sources>`. The build is deterministic: the same sources give the same bytes.

`check` names each file that has no stamp, whose content hash differs (a hand edit), or whose sources changed (stale). `bin/jg-recon-gate.sh` runs it when a Recon has a `board-report/` folder.

A picture that needs design goes through first-draft as its own run; this command draws only a machine.
