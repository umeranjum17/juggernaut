---
status: accepted
date: 2026-11-22
decision-makers: the captain
kind: storage
muster: <ticket id>
---
# Keep conversations in one store file on the host

## Context and problem
Conversations must survive between commands and restarts. The first charter serves one team from one host, with one
writer at a time and under ten thousand conversations.

## Considered options
- One JSON store file on the host, written whole after each command. (chosen)
- SQLite on the host.
- Postgres as a separate service.

## Decision
We keep conversations in one store file on the host, because one host and one writer need nothing more, and the
domain objects stay free of any database code.

## Consequences
- Good: no service to run; a store is a file a test can make and delete.
- Bad: two writers at once would lose an update; a second host needs a new record that supersedes this one (SQLite
  or Postgres).

## Confirmation
The journey `follow-up-question` reads back, in a second command, what the first command stored; a second writer is
a no-go in `docs/vision.md` until a superseding record is accepted.
