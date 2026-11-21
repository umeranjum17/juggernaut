# report-writer

The captain reads status reports on a phone, so Gemini 4 Neon writes them and a checker refuses a text wall.

- `bin/report-writer.py write <sitrep|spotrep|return> --facts <file|-> [--model <tier>] [--out <file>]` writes the report.
  The facts are the deterministic output of the report's owner: the bearings snapshot for `sitrep` and `spotrep`, the return brief of `bin/jg-afk-return.sh` for `return`.
- The writer is `agy --model gemini-4-neon-medium`, run in an empty folder.
  `--model` or `JG_REPORT_MODEL` picks another Neon tier (`low`, `medium`, `high`, `xhigh`); any other model is refused with exit 2.
  A missing or failing agy stops with exit 3 and its real message; no other model writes the report.
- The sitrep and spotrep format contracts stay in their skills (`.agents/skills/sitrep/SKILL.md`, `.agents/skills/spotrep/SKILL.md`); the writer reads them into the prompt.
- Before the model sees the facts, every local path is scrubbed: a `data/<id>/report.md` becomes "the report of <id>", any other path becomes "(local file)".
- `report-writer.py lint <kind> <report>` lists what makes a report a text wall or a leak, and `write` runs it on every draft.
  It refuses a local path or file name, a link that is not `https`, more than 8 links or 2 on a line, a table or code block, a line over 150 characters, more lines than the kind allows (`sitrep` 40, `spotrep` 15, `return` 45), a report that never says "captain", and a sitrep without its four sections in order.
- A refused draft is written again once with the findings named.
  A second refusal exits 1, prints nothing to stdout and names every finding.
- `report-writer.py render <report> [--title <text>] [--out <file>]` builds one self-contained HTML page for a 390 px phone, with the links as links.
  Publish it as a board report card with `sign-off-axi`; the board link is the one the captain can open.

## Check

- `bash core/report-writer/tests/report-writer.test.sh` is the host table: the real script over a stand-in agy, covering the model pin, the scrub, the rewrite, the refusals, the lint rules and the page.
- `bash core/report-writer/run-proof.sh` runs that table, then writes a real sitrep from the live bearings snapshot with the real agy and Gemini 4 Neon, lints it, renders it and takes a 390 px screenshot with `chrome-devtools-axi`.
