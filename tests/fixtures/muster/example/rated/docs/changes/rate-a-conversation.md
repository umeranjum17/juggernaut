---
status: approved   # draft | approved | delivered
muster: <ticket id of the rating feature muster>
depth: full
base: help desk bot 1.0.0
---
# Change pack: rate a resolved conversation

What this feature changes in the agreed documents, as a delta, so nobody re-reads the whole pack. Format adapted from
OpenSpec's change folders (ADDED, MODIFIED, REMOVED). The gate compares every line below with the real difference
between the documents before and after.

## Objects changed
| Object | Behaviour added | Behaviour changed | Invariants added or changed |
|---|---|---|---|
| Conversation | `rate(score)` | `reopen()` clears the rating | ADDED: only a resolved conversation can be rated; ADDED: a rating is a whole number from 1 to 5; ADDED: a conversation is rated once per resolve |

## State machine changes
| Object | Transition (from -> to) | ADDED, MODIFIED or REMOVED | Trigger | Guard | Journey |
|---|---|---|---|---|---|
| Conversation | resolved -> resolved | ADDED | rate | the score is 1 to 5 and the conversation is not rated yet | rate-after-resolve |
| Conversation | resolved -> awaiting_answer | MODIFIED (effect: the rating is cleared) | reopen | within 7 days of resolve | reopen-clears-rating |

## Glossary changes
| Term | ADDED, MODIFIED or REMOVED | New meaning |
|---|---|---|
| Rating | ADDED | The user's score from 1 to 5 for one resolved conversation. Reopening the conversation clears it. |
| Conversation | MODIFIED | Owns, added: only a resolved conversation can be rated, once per resolve, from 1 to 5; reopen clears the rating. |

## Vision changes
- End state, added: "A user can say how well a resolved conversation went, and that score is kept with it."
- FAQ, added: "**Can I change my rating?** No; reopening clears it, and you can rate again after the next resolve."

## Decisions (real ADRs, never idea notes)
- New: [ADR 0004](../adr/0004-store-the-rating-on-the-conversation.md) store the rating on the conversation (accepted).
- Superseded: none.

## Screens changed
None: the rating is a command; the widget screen for it is in the next charter.

## Objectives
- rate-after-resolve (new)
- rate-before-resolve-refused (new)
- rating-out-of-range-refused (new)
- second-rating-refused (new)
- reopen-clears-rating (new)
- user-confirms-resolved (preserve)
- reopen-within-a-week (preserve)

## Charter
| Milestone | A user can now | Proven by journeys | Tickets |
|---|---|---|---|
| F1 rating | rate a resolved conversation once, and rate again after a reopen | rate-after-resolve, rate-before-resolve-refused, rating-out-of-range-refused, second-rating-refused, reopen-clears-rating | R1, R2 |

| Batch | Starts after | Tickets in parallel |
|---|---|---|
| B1 | - (pack approval) | R1 |
| B2 | B1 | R2 |

| Ticket | Title (2 to 7 plain words) | Batch | Depends on | Objects and states it touches | Journeys |
|---|---|---|---|---|---|
| R1 | Conversation can be rated | B1 | - | Conversation: resolved | rate-after-resolve, rate-before-resolve-refused, rating-out-of-range-refused, second-rating-refused |
| R2 | Reopen clears the rating | B2 | R1 | Conversation: resolved -> awaiting_answer | reopen-clears-rating |

## Changelog
- Added: A user can rate a resolved conversation from 1 to 5.
- Changed: Reopening a conversation clears its rating.
