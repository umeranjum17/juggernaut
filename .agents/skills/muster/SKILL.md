---
name: muster
description: Use when the captain invokes /muster (council, survey, skip, light, full or complete) or intake picks a big ask - align on what to build, with question rounds and a checked document pack, before any plan or code.
user-invocable: true
metadata:
  internal: true
---

# /muster

## What it does
Aligns Main and the captain before War Room plans and Blitz builds.
It writes the agreed project documents ("the pack") as the answers settle, checks them with a program, and asks the captain to say yes to that exact checked version.
The `jg muster` commands use Juggernaut's existing machines for rounds, approval and handoff.

Invocation words:
- `/muster <idea>` - triage picks the depth, then the steps below run at that depth.
- `/muster skip|light|full|complete <idea>` - an explicit depth word wins over the picker.
- `/muster council <idea>` (alias `/council`) - several specialist lanes argue first; the captain gets only what they cannot settle.
- `/muster survey` - an existing project: read the code first, draft the glossary, core objects and their state values, record the standards already in use (an existing CONSTRAINTS.md is read into ways of working), propose preserve journeys, and ask only about gaps.

## Where a muster runs
- Main only.
  A Squad Lead home never runs a muster; the work it is routed arrives with a depth already recorded by Main.
- Main may run a muster as a Goal.
  Away mode keeps its rounds open, because only the captain's answers count.
- An empty repository is created and registered by `project-management` first.
  `/muster` starts after that handoff, never inside it, and tests use throwaway projects only.

## Depth
`jg muster depth [--project <name>] <ask>` reads the ask and prints the depth; `jg muster depth record --ticket <id>` writes the one depth line on the ticket (the line's shape is in `formats.md` section 1).
Main may raise a depth at any time with a reason, and lowering one below the rule needs a reason too.
A ticket with no depth line is "not picked yet", never skip.

| Depth | Typical ask | Rounds and questions (targets) |
|---|---|---|
| skip | a fix, a small change, a question, a Recon, a slice of an approved plan | none; the line reads `Muster: skip - <reason>` |
| light | a small feature | 1 round, up to 3 questions; at least one went to the captain, so there is a decision to record |
| full | a big or complex feature | up to 3 rounds, up to 10 questions; council on risk words or his ask |
| complete | a brand-new project | up to 5 rounds, up to 20 questions; council by default |

The numbers are targets, not caps.
What each depth writes is owned by `formats.md` section 7: read it before drafting, and never restate it in a ticket.
Fidelity falls with the depth: complete writes the whole pack, full writes a change pack, light writes a spec section, new terms and one short real decision record.

## States
One machine, the same for every depth; a depth skips the states it does not need.

| State | Who acts | Writes | Moves on when | Goes back when |
|---|---|---|---|---|
| triage | Main: `jg muster depth`, `depth record` | the depth line | depth recorded, no `review` left | the captain changes it |
| council | lens lanes, never gated | merged questions; agreed answers taken as agent; the domain lens's objects, states and events | every lens drafted and merged | never |
| intent | drafter; captain answers | `docs/vision.md` | sections present, one page, no placeholder, no open intent question | a later finding changes who or why |
| lexicon | drafter; domain lens | `GLOSSARY.md` with core objects | every entity and core object is a term | a prototype or code uses a missing word |
| rules | drafter with `prior-art`; captain answers taste calls | `docs/ways-of-working.md` and config | every rule names its check; each fault fails and each allowed use passes | a rule blocks good code |
| terrain | drafter; architecture lens | `docs/domain/model.md`, `docs/use-cases.md`, `docs/architecture/<slug>.md` from `templates/technical-design.md`, real ADRs | the gate's model and ADR clauses pass; no unresolved question unless held | War Room's critic finds an undecided point |
| sand table | first-draft for screens, the prototype skill for flows | `docs/design/visual-direction.md` and the visual design system in root `DESIGN.md` | one pick per design card | a pick contradicts terrain |
| charter | drafter | `docs/charter.md` | every ticket in a batch, no dependency inside a batch or on a later one, every milestone proven by journeys | scope changes |
| objectives | drafter | the spec's Objectives table; journeys | on the base, each new journey fails on its named assertion and each preserve journey passes | a journey cannot be driven |
| check | `jg muster approve ask` runs `jg muster gate` first | the manifest and complete saved copies | the gate passes on the project and again on the saved copies | any refusal: back to the state that owns the clause |
| approval | the captain answers one question | the approvals record | `jg muster approve verify` passes | any pack file changes: a fresh check and ask |
| war room, blitz | War Room, then Blitz | `orders/plan.json` with a muster block | `jg plan blitz start` passes `jg muster verify-plan` | a slice finds a wrong assumption: only that question re-opens |
| secured | done-done and the release record | receipts naming each journey | every objective has a receipt on its landed commit, and the release record says Released or In use | never |

`jg muster status <ticket>` answers "where is this muster".
The base of every objective in a brand-new project is its skeleton commit.

## The round loop
Questions are asked in rounds, one round ticket each, one card per question.
Read [the requirements coverage map](requirements.md) before the first round and [the question standard](questions.md) before posting any card.

1. Read the repository and its docs, then seed the coverage map from what they establish.
2. Compute the frontier from the map: every question whose prerequisites are settled.
   A question that depends on another open one belongs to a later round.
3. Rank by impact times uncertainty, drop what is not asked (see `questions.md`), and keep at most five per round.
   Run a Recon for a fact the repository and docs do not establish and a round needs.
4. Post the round with `jg muster round <ticket>`.
   It records each question's gate id with what the captain saw, in the shape of `formats.md` section 2.
5. Answers arrive through the board or chat and are recorded with `jg muster answer`.
   A reply binds only to the presentation it names; a reply that names no round binds only while one round has been shown.
   `formats.md` section 2 owns every binding rule; follow it, never improvise a reading.
6. Update the coverage map as answers settle and write each answer into its document, such as the spec, glossary or ADR.
7. A change of mind is a correction: `jg muster revise <qid>` adds a revision.
8. `jg muster round-status <ticket>` finds an answer saved with no document written and redoes the write.
9. Recompute the frontier using the map's follow-up and closure rules.
   End the loop only when the map is closed, no required gate is open and the frontier is empty.

Only the captain's own answers count for an irreversible question and for approval.

## The pack, the check and the approval
- Fill each document from `templates/` (placeholders only) and follow `examples/` for a filled one.
  `examples/helpdesk/` is a brand-new help desk bot at complete depth, `examples/skeleton/` is the commit it starts from, and `examples/rated/` is the same project after a rating feature at full depth, with its change pack.
- Write or update the project's [use-case catalogue](templates/use-cases.md) before asking for approval.
  See the [plan verification rules](formats.md#use-case-catalogue) for the links it must carry.
- Every pack at every depth holds at least one real decision record, with a Confirmation; a record missing a part is an idea, and the gate refuses it.
- Every core object has behaviour, invariants each tried by a journey, and a state machine or `Lifecycle: none - <reason>`.
- Settle the [engineering practices](templates/ways-of-working.md#engineering-practices) in the standards pack before approval, including when starting from a survey draft or reusing standards for a feature.
- `jg muster gate` checks the pack at its depth, and a feature against its change pack and the documents before it.
  `jg muster objectives` runs the journeys on the base, `jg muster code` finds each behaviour in its module, and [plan verification](formats.md#5-the-muster-block-of-a-plan-file) checks the handoff.
- `jg muster approve ask <ticket>` runs the gate, saves the pack, writes the manifest and holds one question: "Approve the agreed documents for <project>, version <n>?".
  A changed pack needs a fresh check and a fresh yes.
- The one exception is `jg muster exception ask`, for one ticket only and answered exactly `yes`; `jg muster exception use` spends it.
  A worker never asks or uses it.
- War Room and Blitz refuse to start without a verified approval or that exception.
  Never plan or build around the refusal.

## Council and survey
- Council runs lens lanes through War Room's lane machinery as a separate operation that never needs a pack: `jg muster council <ticket>`, then `jg plan war-room lenses`.
  `next` stops after the lens drafts, and the merge writes the questions back to the round.
  Give the lenses the evidence from the repository read and carry their merged questions into the coverage map when Muster continues to a pack.
- Survey reads the existing project first and asks only about gaps.
  When the pack is missing in an existing project and the depth is full or complete, the line says `survey-first`, and the survey runs before the rounds.

## Spec docs
The feature spec is written in the global spec-docs skill's own schema, plus a `muster:` line.
Each procedure has one caller:
- The drafter runs "Create a spec" at the objectives state.
- Blitz start's worker runs "Update a spec's status" to `in-progress`.
- The closing step sets `implemented` when the last slice lands, and `tested` once the muster is secured.
- A re-opened question runs "Rework an existing spec".
The pack approval leaves a spec's `status` and `updated` lines and its Revisions section out of the hash, so these moves never void the captain's yes.

## Files in this skill
- `questions.md` - the question standard, the one-axis rule and the not-asked list.
- `formats.md` - the frozen machine formats: depth line, round record, manifest, the two owner questions, the plan's muster block, the command contract fragment.
- `templates/` - one file per output, placeholders only.
- `examples/` - one runnable project before and after a feature; run `node journeys/run.ts <id>` inside `helpdesk/` or `rated/`.
- `UPSTREAM`, `UPSTREAM-LICENSE` - the pinned upstream sources and the notices that travel with reused text.
