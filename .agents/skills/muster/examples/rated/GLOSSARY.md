# Glossary: help desk bot

One entry per term the product uses, one or two sentences. Code, docs and screens use exactly these words.
Core objects (the ones in `docs/domain/model.md`) come first and say which rules they own.

## Core objects

### Conversation
One user's question thread, from the first message until it is resolved. Owns: an answer cites at least one answer
source; a resolved conversation takes no answer; at most one open handoff; reopen only within 7 days of resolve;
only a resolved conversation can be rated, once per resolve, from 1 to 5; reopen clears the rating.
_Avoid_: ticket, chat, case

### Handoff
The move of a conversation to a person, with the reason the bot could not answer. Owns: a reason is required; a
closed handoff cannot be accepted.
_Avoid_: escalation, transfer

## Other terms

### Message
One turn from the user or the bot inside a conversation.

### Answer source
A document or page the bot may quote; every answer names at least one.
_Avoid_: knowledge, context

### User
The person who asks the question.
_Avoid_: customer, client

### Agent
The person on the support team who accepts a handoff. Never the bot.
_Avoid_: operator, rep

### Rating
The user's score from 1 to 5 for one resolved conversation. Reopening the conversation clears it.
_Avoid_: review, feedback, stars

### Resolve
To end a conversation: the user confirms the answer, or the agent closes the handoff.

## Flagged ambiguities
- "ticket" was used for both a Conversation and a work item of the team; settled as: the user's thread is a
  **Conversation**; "ticket" is never used in the product.
- "agent" was used for both the bot and the person; settled as: the person is the **Agent**; the bot is "the bot".
- Use **technical design** for system architecture and **visual direction** for the picked look.
