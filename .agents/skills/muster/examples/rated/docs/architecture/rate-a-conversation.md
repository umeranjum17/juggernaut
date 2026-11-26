---
status: approved
date: 2026-12-20
muster: <ticket id of the rating feature muster>
---
# Technical design: rate a resolved conversation

## Context
The change pack `docs/changes/rate-a-conversation.md` lists what changes; decision 0004 places the rating.

## Goals and non-goals
- Goals: one score per resolve; reopen clears it.
- Non-goals: reports, comments with the score.

## Guide level (how a user or another developer sees it)
A new command `rate <conversation> <score>` prints the state, or `refused: <rule>`.

## Reference level (how it works)
- `Conversation.rate(score)` checks the three new invariants; `reopen()` sets the rating back to none.
- The store keeps the rating with the conversation (decision 0004).

## Design review checklist (the captain's SOLID and DDD concern)
- One reason to change: the rating rules sit in `conversation.ts` with the other thread rules.
- Dependencies point toward the domain: the command line calls `rate`; the domain imports nothing new.
- No new bounded context.

## Alternatives considered
- A ratings list owned by a reporting service: decision 0004, option 2.

## Drawbacks
- Reports read whole conversations (decision 0004).

## Unresolved questions
None.
