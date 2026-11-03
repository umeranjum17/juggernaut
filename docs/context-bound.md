# Bounded context at wake time

This doc is for operators who change how large Main's conversation may grow before a wake turn.

## Why
Main re-reads its whole conversation on every model call.
The escalation token audit (`data/escalation-token-audit/report.md`, section 3) measured a wake at 509k tokens when Main started under 150k, 746k at 150k to 250k, 1,465k at 400k to 600k, and 2,058k over 600k.

## The mechanism
The bound is the harness's own auto-compaction, set in the tracked `.claude/settings.json`: `CLAUDE_CODE_AUTO_COMPACT_WINDOW=183000` and `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=100`.
Claude Code 2.1.316 compacts when the next call's context reaches about `window - 33000`, so this is a 150k ceiling. To move it, set the window to `ceiling + 33000`.
It is the smallest mechanism: no new code decides when to compact, and a hard refusing ceiling would stop a wake.

## The record is kept
- The transcript keeps the full history; a compaction adds a boundary record and a summary and deletes nothing.
- A summary paraphrases the captain. After every `compact`, `bin/jg-sessionstart-run.sh` runs `bin/jg-context-bound.py emit`: the history path and the captain's typed words verbatim (newest 20 messages, 4000 characters each). Wakes are not repeated as the captain's words.
- Each compaction is one line in `state/context-bound.log`.

## Measure it
`bin/jg-context-bound.py turns <transcript>` is the audit's counter.
`done-done run context-bound-at-wake` runs two real Haiku sessions on the same nine ~20k-token captain notes and one wake, without and with the bound, and fails if the bounded wake starts over the ceiling or loses the wake fact, an early captain word, or a note on disk. `tests/jg-context-bound.test.sh` checks the verbatim words offline.

## Limits
- The ceiling applies to every Claude session that loads this project's settings, including workers in worktrees.
- A captain's user settings may define the same keys. Project settings are documented to override them; this was not tested against a real user file.
- The summarisation call is not in the transcript, so the counter omits it (about once per 45 wakes).
