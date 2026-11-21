---
status: accepted
date: 2026-12-20
decision-makers: the captain
kind: feature
muster: <ticket id of the rating feature muster>
---
# Store the rating on the conversation

## Context and problem
Users can now rate a resolved conversation (glossary: **Rating**). We must decide where the score lives, so that a
reopen clears it and a conversation is rated once per resolve.

## Considered options
- A `rating` field on **Conversation**, set only through `rate(score)`. (chosen)
- A separate ratings list keyed by conversation id, written by a reporting service.

## Decision
We store the rating on Conversation, because "rated once per resolve, cleared on reopen" is a Conversation
invariant, and the object that enforces a rule owns its data (a rich domain object, not a list another service
edits).

## Consequences
- Good: one object owns the rule; reopen clears the rating in the same command.
- Bad: reports read whole conversations, not a narrow list; acceptable for one team (decision 0002's store),
  revisit with a superseding record when reports need more.

## Confirmation
The journeys `rate-after-resolve` and `reopen-clears-rating` pass, and the secured check finds `rate` in
`src/domain/conversation.ts`.
