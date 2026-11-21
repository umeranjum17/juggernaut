---
status: accepted
date: 2026-11-22
decision-makers: the captain
kind: hosting
muster: <ticket id>
---
# Host the bot on one small server

## Context and problem
The bot must be reachable all day for one team. The captain answered R1Q3 "keep it on one small server for now".

## Considered options
- One small rented server running Node, deployed by the project's release step. (chosen)
- Serverless functions, with a hosted database.
- A computer at the team's office.

## Decision
We host the bot on one small server, because it matches the one-file store of record 0002 and costs least to run
and reason about.

## Consequences
- Good: one place to look; the release record names the server and the version running there.
- Bad: one server is one point of failure; acceptable for one team, revisit with a superseding record before a
  second team joins.

## Confirmation
Each release record names the server and the version; the done-done receipts of the objective journeys are taken on
that released build.
