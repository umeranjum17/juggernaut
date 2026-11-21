---
status: approved
muster: <ticket id>
---
# Vision: help desk bot

## Press release (one paragraph)
2026-12-15. Small teams that answer the same customer questions every day can now let a bot answer the ones their
help pages already cover, with the page it used shown under every answer. When the bot does not know, it hands the
question to a person with the reason, and nothing is lost between the two. "I stopped answering the password question
forty times a week, and the hard questions reach me with the context already there." - a support lead in the pilot.

## Who it is for (job stories)
- When a user asks a question our help pages answer, I want the bot to answer with the page it used, so the user
  can trust the answer and read more.
- When the bot cannot answer, I want the question handed to a person with the reason, so the user does not repeat
  themselves.
- When a solved problem comes back within a week, I want the user to reopen the same conversation, so the history
  stays in one place.

## End state
A user asks, gets a cited answer or reaches a person, and the conversation ends resolved. Every answer shows its
source. No question waits without an owner: it is with the bot, with a person, or resolved. A user can say how
well a resolved conversation went, and that score is kept with it.

## Time budget (appetite)
Two weeks of agent time for the first charter. Work that does not fit is cut, not extended.

## No-gos
- No answer without a source: the bot never answers from general knowledge.
- No voice, email or phone channels in this charter.
- No ranking across several answer sources yet.

## Open risks (rabbit holes)
- Help pages that contradict each other - the bot cites the one it used; ranking is a no-go for now.
- People who never close a handoff - the agent inbox shows the oldest open handoff first (next charter).

## FAQ
- **Can the bot answer without a help page?** No. An answer with no source is refused.
- **What happens when a person takes over?** The conversation is handed off with the reason; the person closes the
  handoff, and the conversation is resolved.
- **Can I change my rating?** No; reopening clears it, and you can rate again after the next resolve.
- **Can a user come back later?** Yes, within 7 days of resolve the same conversation reopens; after that, a new one
  starts.

## Decisions
- 2026-11-22 R1Q1: "TypeScript, one language with the widget" (revision 1)
- 2026-11-22 R1Q3: "keep it on one small server for now" (revision 1)
- 2026-11-23 R2Q2: "a week is enough for reopen" (revision 1)
- 2026-12-20 R1Q1 (rating muster): "keep the score on the conversation" (revision 1)
