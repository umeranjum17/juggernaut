---
name: strike-recon
description: Load at stage 1 of a deep-recon plan or design Recon that will be sliced into work, before writing outline.md.
user-invocable: false
metadata:
  internal: true
---

# strike-recon: the standing asks of a plan Recon

This skill adds no stage. `deep-recon` owns the stages, budgets, stop rules, critic rubric and report template.
At stage 1, write each ask below into `outline.md` with the report section that will answer it. Mark an ask that does
not apply `n/a: <reason>`. A critic gap that names a missing standing ask is a stage-1 gap.

## The asks

1. The owner's intent, quoted from his own messages, with every limit he named (late limits, budgets, words he wants
   or does not want used).
2. Prior art: 3 to 5 real options, each licence read at its source (the `prior-art` skill).
3. The misses table: every named miss, how it is caught, which alert fires, its fix rung (1 impossible, 2 caught by a
   check, 3 proved by the agent, 4 a written rule, 5 a person), its proof case and its slice.
4. The parts count against the earlier designs and against every state, ladder or rule engine the target base already
   runs: one row per part, kept, folded or retired, why, what covers its miss now, and the slice that removes it.
5. A replay of the real records window through the design, per slice, with each limit stated plainly as met or not.
6. A clause-level mutant run: every refusal clause has a proof case that fails without it.
7. A seeded simulation with faults (crash, lost and doubled messages, clock jumps of a day or more, a late tick,
   forged identity) and its invariants, liveness included; its workload taken from the real window's rates, with each
   kind's simulated rate printed against the window's. Say plainly what it does not simulate.
8. Efficiency: wakes, turns and tokens from the records, before and after, with the trade stated.
9. Tests: an audit by running (gut the target, rerun), never by reading alone; the cost of any new test rule.
10. Autonomy: one owner-message count per leash level, from one replay with the design's fixes.
11. Per-role instructions: what each role loads, its budget, and the check that enforces it.
12. Copy the replay and probe tools in stage 3, before the design, and save every script whose output is cited.
13. The ledger: every arrival is recorded before anyone acts on it; the count rule; the daily check of outside records
    with no item.
14. One escalation ladder per failure class: its rungs, time limits and who holds each rung.
15. Every action safe to run twice: its idempotency key and a run-twice proof case.
16. A principles pass: single responsibility, one source of truth, KISS, no special-case moves.
17. A README section, "How state is managed", a new agent can read in two minutes.
18. done-done efficiency from its own records: reruns, false refusals, catch rate, cost.
19. Every owner decision in one deduplicated table, each with the default the slices assume until he answers.
20. Every slice as a work order (the `op-order` skill), with its wave, and a mark on each slice that needs an
    owner-only word (security, sudo, discard, a cut of the always-loaded instructions), so the rest run without waiting.
21. Ready-to-copy sources: every acceptance command of the first slices run on the exact files the orders pin.
22. Every field the replaced records carry today (columns, metadata keys, body conventions, labels), each with where it
    lives after the plan, and one owner per fact: no fact kept in two records with a reconciler between them.
23. Where the design's files live on a host with several homes, and how each home finds them.
