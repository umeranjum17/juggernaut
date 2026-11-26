---
title: Rate a resolved conversation
slug: rate-a-conversation
status: planned          # spec-docs lifecycle: planned | in-progress | implemented | tested | archived
created: 2026-12-20
updated: 2026-12-20
owner: the captain
links:
  - ../changes/rate-a-conversation.md
  - ../adr/0004-store-the-rating-on-the-conversation.md
muster: <ticket id of the rating feature muster>
---
# Spec: Rate a resolved conversation

## Context
A feature muster at full depth on the help desk bot after its first release. The base is the released 1.0.0 commit.

## Problem
The team cannot tell which answers helped.

## Solution (user view)
After a conversation is resolved, the user gives it a score from 1 to 5, once. Reopening clears the score.

## Objectives (proof first)
| Journey id | Kind | Key example (given, when, then) | On the base | On the changed build |
|---|---|---|---|---|
| rate-after-resolve | new | given a resolved conversation, when the user rates it 5, then the rating is kept on it | fails with `assert: rating saved` | passes |
| rate-before-resolve-refused | new | given an open conversation, when the user rates it, then it is refused and no rating is stored | fails with `assert: rating before resolve refused` | passes |
| rating-out-of-range-refused | new | given a resolved conversation, when the user rates it 6, then it is refused | fails with `assert: rating 6 refused` | passes |
| second-rating-refused | new | given a rated conversation, when the user rates it again, then it is refused and the first rating stays | fails with `assert: first rating` | passes |
| reopen-clears-rating | new | given a rated conversation, when it is reopened, then it has no rating | fails with `assert: rated` | passes |
| user-confirms-resolved | preserve | given an answered conversation, when the user confirms, then it is resolved | passes | passes |
| reopen-within-a-week | preserve | given a conversation resolved 6 days ago, when the user reopens it, then it awaits an answer | passes | passes |

## Files to change
- `src/domain/conversation.ts`, `src/cli.ts`

## Test list
- The five new journeys and the two preserve journeys above.

## Out of scope
- Showing ratings in reports.

## Verification
- [ ] Every journey in the Objectives table passes on the released build (done-done receipt on the landed commit).

## Revisions
- 2026-12-20 first approved version
