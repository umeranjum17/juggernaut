---
title: Help desk bot, first charter
slug: helpdesk
status: planned          # spec-docs lifecycle: planned | in-progress | implemented | tested | archived
created: 2026-11-22
updated: 2026-11-22
owner: the captain
links:
  - ../vision.md
  - ../domain/model.md
  - ../charter.md
muster: <ticket id>
---
# Spec: Help desk bot, first charter

The frontmatter is the global spec-docs skill's schema (title, slug, status, created, updated, owner, links) plus one
`muster` line; the spec-docs skill renders `helpdesk.html` beside this file and regenerates `index.html`. The pack
approval hashes this file with `status`, `updated` and the `## Revisions` section left out, so a status move keeps the
approval while a changed objective needs a fresh one.

## Context
A brand-new project. The base for every objective is the skeleton commit: the toolchain and a command line that
starts and knows no command.

## Problem
Small teams answer the same questions every day, and hard questions lose their context when a person takes over.

## Solution (user view)
A user asks; the bot answers with a cited source, or hands the question to an agent with the reason; the
conversation ends resolved and can be reopened within a week.

## Objectives (proof first)
Each row is one done-done journey in `.done-done.yaml`, named by its id. On the skeleton every row fails on its named
assertion; on the built charter every row passes.

| Journey id | Kind | Key example (given, when, then) | On the base | On the changed build |
|---|---|---|---|---|
| first-question-gets-answer | new | given a new question, when the bot answers with a source, then the conversation is answered | fails with `assert: conversation started` | passes |
| follow-up-question | new | given an answered conversation, when the user asks again, then it awaits an answer | fails with `assert: conversation started` | passes |
| answer-without-source-refused | new | given a question, when an answer cites no source, then it is refused and nothing changes | fails with `assert: conversation started` | passes |
| bot-hands-off-unknown | new | given a question, when the bot hands off with a reason, then a handoff waits for an agent | fails with `assert: conversation started` | passes |
| handoff-without-reason-refused | new | given a question, when a handoff has no reason, then it is refused and nothing changes | fails with `assert: conversation started` | passes |
| agent-closes-handoff | new | given a handoff, when an agent accepts and closes it, then the conversation is resolved | fails with `assert: conversation started` | passes |
| closed-handoff-cannot-be-accepted | new | given a closed handoff, when another agent accepts it, then it is refused and stays closed | fails with `assert: conversation started` | passes |
| second-handoff-refused | new | given an open handoff, when a second handoff is asked, then it is refused | fails with `assert: conversation started` | passes |
| user-confirms-resolved | new | given an answered conversation, when the user confirms, then it is resolved | fails with `assert: conversation started` | passes |
| answer-after-resolve-refused | new | given a resolved conversation, when the bot answers, then it is refused and stays resolved | fails with `assert: conversation started` | passes |
| reopen-within-a-week | new | given a conversation resolved 6 days ago, when the user reopens it, then it awaits an answer | fails with `assert: conversation started` | passes |
| reopen-after-a-week-refused | new | given a conversation resolved 8 days ago, when the user reopens it, then it is refused and stays resolved | fails with `assert: conversation started` | passes |

Kinds: **new** behaviour must run on the base and fail on its named assertion; **preserve** behaviour must pass on both.
A journey that cannot start (missing prerequisite) exits 77 and is reported as a setup error, never as the expected failure.

## Files to change
- `src/domain/conversation.ts`, `src/domain/handoff.ts`, `src/domain/errors.ts`, `src/cli.ts`

## Test list
- The twelve journeys above, through the command line only; no unit tests.

## Out of scope
- The chat widget and the agent inbox screens (next charter, built to `docs/design/visual-direction.md`).

## Verification
- [ ] Every journey in the Objectives table passes on the released build (done-done receipt on the landed commit).

## Revisions
- 2026-11-22 first approved version (left out of the approval hash; an objective change still needs a fresh approval)
