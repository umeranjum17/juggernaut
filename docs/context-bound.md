# Bounded context at wake time

This doc is for operators who change how large Main's conversation may grow before a wake turn.

## Why
Main re-reads its whole conversation on every model call.
The escalation token audit (`data/escalation-token-audit/report.md`, section 3) measured a wake at 509k tokens when Main started under 150k, 746k at 150k to 250k, 1,465k at 400k to 600k, and 2,058k over 600k.

## The mechanism
The bound is the harness's own auto-compaction: `CLAUDE_CODE_AUTO_COMPACT_WINDOW` set to the cap plus 33000, and `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=100`.
Claude Code 2.1.316 compacts when the next call's context reaches about `window - 33000`, so a window of 183000 is a 150k ceiling.
The cap per role is `config/supervisor-context-cap` (docs/configuration.md "Supervisor context cap"; default `lead 150000`, `main off`).
`jg-spawn.sh` writes the lead's cap into its per-launch settings; `bin/jg-context-bound.py apply <role> --home <home>` writes it into a home's local settings, which is how Main joins.
The tracked project settings carry no cap, so a worker is not capped by default.
It is the smallest mechanism: no new code decides when to compact, and a hard refusing ceiling would stop a wake.

## The record is kept
- The transcript keeps the full history; a compaction adds a boundary record and a summary and deletes nothing.
- A summary paraphrases the captain. After every `compact`, `bin/jg-sessionstart-run.sh` runs `bin/jg-context-bound.py emit`: the history path and the captain's typed words verbatim (newest 20 messages, 4000 characters each). Wakes are not repeated as the captain's words.
- Holds, decisions, owner rules and pending asks are exempt: a compaction deletes nothing, and the digest re-run after it (`jg-session-start.sh --reemit`) reads them whole from disk. The cap degrades the context, not these records.
- Each compaction is one line in `state/context-bound.log`.

## Measure it
`bin/jg-context-bound.py turns <transcript>` is the audit's counter.
`done-done run context-bound-at-wake` runs two real Haiku sessions on the same nine ~20k-token captain notes and one wake, without and with the bound, and fails if the bounded wake starts over the ceiling or loses the wake fact, an early captain word, or a note on disk. `tests/jg-context-bound.test.sh` checks the verbatim words offline.

## Pilot (this home, Release c-5 cap)
The 150k cap ran in the pilot home from 2026-11-03T07:34Z to 2026-11-07T12:05Z. Both windows are 4.19 days. Counter: `bin/jg-context-bound.py` record, turn and kind functions.

| | Before | After |
|---|---|---|
| Wake turns | 168 | 674 |
| Wake context at start, median | 312,838 | 127,639 |
| Wake context at start, p95 | 543,537 | 148,024 |
| Input tokens per wake, mean | 1,348,431 | 644,245 |
| Input tokens per active hour | 22.9M | 9.46M |
| Compactions | 1 | 99 |
| Receipts PASS / FAIL | 188 / 5 | 170 / 3 |
| Reverts (`^revert` commits) | 0 | 0 |
| Owner rules written | 14 | 0 |
| Captain corrections | 0 | 0 |

Quality held: no more failed receipts, reverts or corrections, and no dropped dispatched outcome.
Limits: this home gets almost no direct captain words, so the correction signal is weak. Commits fell from 282 to 150 over different active hours, so throughput is confounded. The controlled retention check is `done-done run context-bound-at-wake`.

## Limits
- The ceiling applies to the sessions whose settings carry it: leads by default, Main once `apply` ran. A tracked env block applied to every session from Release c-5 until this change.
- A captain's user settings may define the same keys. Project settings are documented to override them; this was not tested against a real user file.
- The summarisation call is not in the transcript, so the counter omits it (about once per 45 wakes).
