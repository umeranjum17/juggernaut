# The question standard

Read this before posting any card of a muster round.
The method is Matt Pocock's grilling: map the decisions as a design tree, ask the whole frontier in one round, give a recommended answer for each, and word each question so "yes" accepts it.
The ranking is GitHub Spec Kit's clarify: impact times uncertainty.
Spec Kit asks at most five questions per session, one at a time; a muster shows up to five per round together, because the captain answers on the board when he is free, not in a live chat.
Both are MIT-licensed, and their notices are in `UPSTREAM-LICENSE`.

## A good question
Each line is enforced by the card and its gate.

1. One decision, in plain words, 12 words or fewer, ending in "?".
2. A context line: what the user sees today, or the problem.
3. Two to four options that differ on one axis only, each with its consequence: what changes for the user, the cost, and whether it can be undone.
4. The recommended option preselected, with one line of why, worded so "yes" accepts it.
5. A "something else" free-text answer, always.
6. A label: `irreversible`, `architecture` or `reversible`.
   A reversible question may carry a default and a date.
   An irreversible one never takes a default.
7. A picture when the question is about a screen.

The first use of any project word is defined in place, for example "the pack, the agreed project documents".

## The one-axis rule
Options differ on one axis only.
"Store conversations in one file, or in a database?" is one axis: where they live.
"One file on this server, or a managed database with a monthly cost and a new login?" mixes three axes (place, cost, access), so the captain cannot pick one without accepting the others.
When two axes matter, they are two questions, and the second may depend on the first.
Test each question before posting it: change one option's wording, and the other options must still make sense unchanged.

## Not asked
These are listed under "Decided for you", where the captain can flip any of them.
- A fact the agent can look up: read the code, run a Recon, search the web.
- A question an owner rule already answers.
- A reversible choice with no product consequence.
- A question that depends on another open one: it waits for the next round.
- A duplicate of an open card.

## Ranking and size
Rank the frontier by impact times uncertainty: a decision that changes many documents, or is hard to undo, and where the answer is truly unknown, goes first.
Show at most five questions per round.
The question counts per depth in `SKILL.md` are targets, not caps: a question that needs asking is asked.

## A round on the board
- One round is one round ticket, and each question is its own card, with the round ticket as its parent.
- Every presentation after the first says how to answer: reply to a card, or start the note with `R<round>.<revision>`, for example `R2.1`.
- "Yes to the rest" covers the round it names and nothing else.
- The binding rules for replies are owned by `formats.md` section 2.

## Example
Round 1, question 2, for a help desk bot:

```
R1Q2 - Where should conversations be kept?
Today there is no store: a restart loses every open conversation.
a) One file on the server (recommended). Simple and cheap; moving to a database later takes a day of work.
b) A database. Scales further; adds a service to run and pay for.
c) Something else: tell me.
Label: architecture.
```
