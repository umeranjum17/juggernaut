---
status: approved   # draft | approved | delivered
muster: <ticket id>
---
# Mission charter: help desk bot, first charter

What will be delivered by the end of this exercise, in which order, and what runs in parallel. War Room plans the
work orders from this charter; every order names the charter ticket it serves; the build check refuses a plan that
leaves a ticket with no order, breaks a ticket's dependency or a batch's order, or proves no milestone journey.

## Delivered by the end
- A user asks a question and gets an answer that cites a source (first-question-gets-answer, follow-up-question).
- The bot hands an unknown question to an agent, who closes it (bot-hands-off-unknown, agent-closes-handoff).
- A conversation is resolved and can be reopened within a week (user-confirms-resolved, reopen-within-a-week).

## Milestones
| Milestone | A user can now | Proven by journeys | Tickets |
|---|---|---|---|
| M1 walking skeleton | ask and get a cited answer, and ask again | first-question-gets-answer, follow-up-question, answer-without-source-refused | C1, C2 |
| M2 handoff | reach an agent when the bot cannot answer | bot-hands-off-unknown, handoff-without-reason-refused, agent-closes-handoff, closed-handoff-cannot-be-accepted, second-handoff-refused | C3 |
| M3 lifecycle | resolve, and reopen within a week | user-confirms-resolved, answer-after-resolve-refused, reopen-within-a-week, reopen-after-a-week-refused | C4 |

## Batches (tickets that run in parallel)
| Batch | Starts after | Tickets in parallel |
|---|---|---|
| B1 | - (pack approval) | C1, C2 |
| B2 | B1 | C3, C4 |

## Proposed tickets, in order
| Ticket | Title (2 to 7 plain words) | Batch | Depends on | Objects and states it touches | Journeys |
|---|---|---|---|---|---|
| C1 | Conversation answers with sources | B1 | - | Conversation: awaiting_answer, answered | first-question-gets-answer, follow-up-question, answer-without-source-refused |
| C2 | Command line for the bot | B1 | - | none (the public operations) | first-question-gets-answer |
| C3 | Handoff to an agent | B2 | C1 | Handoff: waiting, accepted, closed; Conversation: handed_off | bot-hands-off-unknown, handoff-without-reason-refused, agent-closes-handoff, closed-handoff-cannot-be-accepted, second-handoff-refused |
| C4 | Resolve and reopen | B2 | C1 | Conversation: resolved | user-confirms-resolved, answer-after-resolve-refused, reopen-within-a-week, reopen-after-a-week-refused |

## Out of this charter
- The chat widget and the agent inbox screens; ranking several answer sources; ratings (a later feature muster:
  `docs/changes/rate-a-conversation.md` in the rated example).
