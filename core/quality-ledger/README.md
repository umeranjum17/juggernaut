# quality-ledger

The quality reader: one table, for one window of one home, of how often a task wrote `done`
again, how often proof passed its first check, how large a launch brief is, and who sends the
lead the most notifications. It reads records the home already keeps. It is read-only and
nothing else reads it; deleting this folder removes it.

```
core/quality-ledger/quality.sh [--home <dir>] [--since <time>] [--until <time>] [--routing <file>]
```

`<time>` is epoch seconds or an ISO time ending in `Z`. `--home` defaults to `$JG_HOME`.
`--until` defaults to now and `--since` to a day before it, so a bare run is the last day.
Exit 0 when it printed, 2 on bad input (no home, a bad or reversed time). A record that is
absent prints `no record: <path> is absent` for its sections and the rest still print.

## What it prints

| Section | Line | Definition |
|---|---|---|
| repeat done | repeat done | `done` status lines in the window minus the tasks that wrote one; a repeat is a `done` after an earlier `done` of the same task |
| | tasks with 2+ done | tasks whose `done` lines in the window number two or more, of the tasks with any |
| | follow a lead message | repeats with a lead message to that task between the two `done` lines (consecutive pairs) |
| proof | proof first-check | targets whose first check in `data/checks-gate.log` inside the window passed |
| | form errors | targets whose first check failed with a form error: no command in `proof:`, a missing evidence file, no `## Checks` block, or an empty Checks line |
| brief size | brief median | median bytes of `data/*/brief.md` last written inside the window, and of its `# Task` section (text up to the next `# ` heading, so its `##` subsections count). A file with no `# Task` section is left out and counted |
| notifications | rows, per day | `wake` rows in the window, and their count per UTC day |
| | top senders | the five senders with most rows; a `.turn-ended` suffix is dropped and a check script shows as its file name |
| | digest rows | rows whose text opens `check: wake-digest` |
| | turn-ended rows after a status line | `.turn-ended` signal rows that follow a `done`, `needs-decision`, `blocked`, `failed` or `paused` line of the same task within 120 seconds |
| | rows wake at once | rows whose class by the routing rule table is `now`, by kind (a signal by the `[status=...]` word in its text) |

Percentages are whole numbers, rounded half up. Counts and medians over 999 use a comma.

## Reading it correctly

- **One home.** It reads `state/chat.jsonl`, `data/checks-gate.log` and `data/*/brief.md` of the home
  it is given. Every task of that home counts, whatever its project.
- **Window.** A row counts when its time is inside `[since, until]`. A status line before `since` is
  read only as context, to find the status line that came just before a notification.
- **Brief time is the file's last write.** A launch brief that is rewritten (a relaunch rewrites it)
  moves to the later window and leaves the earlier one. A window already past can therefore read
  differently a day later: a rerun of an old window counts a rewritten brief only if its new time is
  still inside. The other records are append-only and do not drift.
- **Rule table, not the router.** `rows wake at once` reads `defaults/wake-routing` (first match wins,
  no match is `now`), the home's `config/wake-routing`, or `JG_WAKE_ROUTING`, or `--routing`. A rule with an
  `@condition` reads live state and is skipped, so a row's class is the table's reading, not the
  router's decision at that minute. `core/wake` owns the live decision.
- **Cause is not shown.** A repeat that follows a lead message is not proved to be caused by it.

## Layout

- `quality.sh` - the entry point; checks `python3` and runs `quality.py`.
- `quality.py` - arguments, one read of each record, and the table.
- `records.py` - the three readers (message log, proof-check log, briefs). They write nothing.
- `measures.py` - the measures as pure functions over what the readers returned.
- `routing.py` - reads the rule table.
- `tests/quality.test.sh` - the real reader over a fixture home: each measure, the window edges and the exit-2 paths.

## Proof on the live home (9 Nov 2026)

Each run used `--until 2026-11-09T14:45:00Z` on the supervising home and read the 10 MB message log once in about one second.

| `--since` | Printed |
|---|---|
| `2026-10-31T07:58:00Z` | 47% repeat done (459 of 976), 249 of 517 tasks wrote done twice or more, 9,246 notification rows |
| `2026-10-14T00:00:00Z` | 76% proof first-check (915 of 1,204 targets), 15% form errors (182) |
| `2026-11-08T00:00:00Z` | 13 digest rows, 390 turn-ended rows after a status line (of 563), 721 rows wake at once |
| `2026-11-03T00:00:00Z` | 32,842-byte brief median over 402 briefs; the Task part is 1,562 bytes (5%) |

The brief row is 32,860 bytes over 405 briefs in the report that sized this slice. Three of those
briefs were rewritten after 14:45Z that day, so their file times left the window; the report's own
counting method run on the files today prints the same 402 and 32,842.
