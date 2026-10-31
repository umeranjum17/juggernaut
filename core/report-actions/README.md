# report-actions

Agreement with a report starts the work. A report that recommends something ends with this block; this feature owns its schema, button results and routing, and the sign-off lead owns the page look.

```markdown
## Plan
- Add the status, ticket and message reads
## Actions
- **Approve** (recommended): build starts. Owner: axi-lead. First PR due: 2026-02-01.
- **Refine**: your note goes to axi-lead and a new version of this report appears with a diff.
- **Reject**: pick a reason and add a note. This report closes, no build starts, and the reason is saved as an owner rule.
If you do nothing: nothing starts and this report stays open.
```

- `lint <report>` exits 1, naming the first problem, when the block or the plan is unclear. Call it wherever a report is published.
- `approve <report> [--by "<his words>"]` mints one ticket per plan item, hands them to the owning lead when `data/squad_leads.md` registers that owner (else they stay in the main backlog), and prints one line: started, owner, first PR due, ticket ids. `--by` requires his chat words to name the report by link or title and carry agreement, so agreement in chat counts as Approve. A sized slice needs no second approval; merge and spend limits still apply.
- `refine <report> --note "<his note>"` keeps the answered version as `report.v<N>.md`, writes the next one with his note, sends it to the owner, and prints the diff.
- `reject <report> --reason <not-a-problem|wrong-fix|too-risky|not-now|other> [--note "<his note>"]` closes the report, prints no build, and saves his reason as an owner rule.

One answer per version: `<report-dir>/answered` marks it and a refine clears it. Commands resolve from the Juggernaut checkout (`JG_CODE_ROOT`, else three levels above the script); `TASKS_AXI`, `JG_SEND`, `JG_HANDOFF`, `JG_OWNER_RULES` and `JG_DATA_OVERRIDE` override one command or the data directory each. No installer.

Check: `python3 tests/test_report_actions.py` replays approve, refine and reject end to end on the real recorded report in `tests/fixtures/recorded-report.md`, with the outside commands stubbed in the throwaway directory.
