---
status: approved   # draft | discussion | approved | abandoned (after Oxide RFD states)
date: 2026-11-22
muster: <ticket id>
---
# Design: help desk bot

## Context
A brand-new project; the pack's vision, glossary and domain model are the input. Decisions 0001-0003 fix the stack,
the storage and the hosting.

## Goals and non-goals
- Goals: cited answers; a handoff with its reason; resolve and reopen within a week.
- Non-goals: voice, email or phone; ranking several answer sources; more than one host.

## Guide level (how a user or another developer sees it)
A client (the chat widget later, the command line now) sends commands: start, answer, receive, handoff, accept,
close-handoff, resolve, reopen. Each prints the new state, or `refused: <rule>` in the glossary's words.

## Reference level (how it works)
- Domain model: `docs/domain/model.md`. Conversation is the aggregate root; Handoff lives inside it.
- Each command loads the store, calls one domain method, and writes the store whole (decision 0002).
- C4 context: user and agent -> bot -> store file. Container: one Node process on one server (decision 0003).

## Design review checklist (the captain's SOLID and DDD concern)
- One reason to change per module: `conversation.ts` (thread rules), `handoff.ts` (handoff rules), `cli.ts`
  (reading commands and printing results), `errors.ts` (the refusal type).
- Dependencies point toward the domain: `cli.ts` imports the domain; the domain imports no command line, file or
  network code.
- One bounded context (support conversations): one glossary section, one folder `src/domain/`.

## Alternatives considered
- A ticket system with a bot bolted on: refused in R1Q2; the bot's thread is the product.

## Drawbacks
- The whole store is rewritten after each command; fine for one team (decision 0002).

## Unresolved questions
None.
