# Bounded context at wake time

This doc is for operators who change how large Main's conversation may grow before a wake turn.
## Why
Main re-reads its whole conversation on every model call.
The escalation token audit (`data/escalation-token-audit/report.md`, section 3) measured a wake at 509k tokens when Main started under 150k, 746k at 150k to 250k, 1,465k at 400k to 600k, and 2,058k over 600k.
Had all 2,197 wakes of the audited 7.7 days cost the under-150k mean, Main would have spent 1,118M tokens instead of 2,306M.

## The mechanism
The bound is the harness's own auto-compaction, set in the tracked `.claude/settings.json`: `CLAUDE_CODE_AUTO_COMPACT_WINDOW=183000` and `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=100`.
Claude Code 2.1.316 compacts when the next call's context reaches about `window - 33000`, so this is a 150k ceiling.
To move the ceiling, set the window to `ceiling + 33000`.

It is the smallest mechanism: no new code decides when to compact, and `bin/jg-sessionstart-run.sh` already re-emits the digest after a compaction.
A hand-built summary would repeat it, and a hard ceiling that refuses would stop a wake.

## The record is kept
- The session transcript keeps the full history. A compaction adds a `compact_boundary` record and a summary and deletes nothing.
- A summary paraphrases the captain. After every `compact`, `bin/jg-sessionstart-run.sh` runs `bin/jg-context-bound.py emit`.
  It prints the history path and the captain's typed words verbatim (newest 20 messages, 4000 characters each; a cut message points to the file).
  Wakes and other machine text are not repeated as the captain's words.
- Each compaction is one line in `state/context-bound.log`.

## Measure it
`bin/jg-context-bound.py turns <transcript>` is the audit's counter.
`done-done run context-bound-at-wake` runs two real Haiku sessions on the same nine ~20k-token captain notes and one wake, without and with the shipped bound, and fails when the bounded wake starts over the ceiling, loses the wake fact or an early captain word, or loses a note on disk.
The same journey runs the real `bin/jg-sessionstart-run.sh` on a compact payload.

## Limits
- The ceiling applies to every Claude session that loads this project's settings, including workers in Juggernaut worktrees.
- A captain's user settings may define the same keys. Project settings are documented to override them; this was not tested against a real user file.
- The summarisation call is not in the transcript, so the counter omits it (about once per 45 wakes).
