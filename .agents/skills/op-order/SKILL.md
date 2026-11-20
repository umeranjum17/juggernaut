---
name: op-order
description: Load when a passed Recon or plan of 3 or more slices is turned into work orders, before writing the first order.
user-invocable: false
metadata:
  internal: true
---

# op-order: slices into work orders a basic model runs alone

## Inputs

The passed report, its misses table, its owner-decision table, its design files, and the probe scripts it cites.

## Steps

1. Order the slices by harm: after the foundation slice, the miss that hurts the owner most directly goes first.
2. Write one order per slice in this template. Every field is required.

```
Slice <n>: <name>     Misses closed: <ids>     Model: the smallest that can do it
Wave <w>. Depends on: <slices, time gates>. Owner word needed: no | yes: <which word>
Owner decisions assumed: <decision id and the default this order builds on>
Goal          one sentence: what is true after this slice that is not true now
Sources       absolute paths with sha256 prefixes in a frozen, read-only copy; final files are copied byte for byte
Files         the exact files created or changed, the CLI and libraries included; no other file may change;
              a mechanical list is allowed only with the command that produces it on the worker's base
Tests first   each test with the command that shows it failing on the base commit and passing after
Steps         numbered, each small enough to check
Acceptance    commands a script runs, each with its expected output, over fixtures committed with the slice;
              never a script that reads live homes (a live check is Main's, after landing, and says so)
Expand path   how the fleet keeps running while both paths exist
Rollback      the one flag or revert that returns to today's behaviour
Runs beside   the other slices of its wave
Budget        measured by a dry run, never guessed
```

3. A refactor that changes many callers is three orders or more: expand (the new path beside the old, behind a flag),
   then one order per disjoint set of caller files (each set small enough for one lane: about 8 files and 40 changed
   lines; sets never sharing a file), then contract (delete the old path) after the stated clean days. A hot file (one
   that 40 or more changed lines touch, or that three or more sets would need) gets its own order, or a first small
   order splits it so that later orders touch separate files.
4. Build the waves from the Files fields: two slices share a wave only when they share no file and neither reads what
   the other creates. Every slice of a wave is cut from the same commit: the trunk tip after the previous wave landed.
   Wave 1 holds at least as many slices as the owner home's lane target (`config/lane-target`); when the work cannot be
   cut that wide, the report's plan section says why, and Main may run another plan beside it.
5. Write orders/plan.json beside the orders in the form of the swarm interface's section 1: plan, title, report,
   intent, prior_art, and per slice id, title, owner_home, project, size, risk, depends_on, files, machine, order,
   owner_word and gate. A slice id is lowercase letters and digits. A title is 2 to 7 plain words, at most 48
   characters, with no path, slash or id (strict intake refuses others). Dependent slices share one owner home. An
   owner-only slice carries owner_word, with every field the board needs (`bin/jg-swarm-plan-check.sh` refuses a miss):
   `question` (12 words at most, ends in "?"), `options.a` and `options.b` (80 characters each), `outcomes.a` and
   `outcomes.b` (120 each), `why` (one line, 200), `recommend` (a or b) with `recommend_reason` (160), `default` (a or b)
   and `must` design-pick; no path or internal name in any text; a money call is settled in the report's open decisions before the swarm, never in a slice. A slice that waits on another
   home's row or a tool version carries gate; a slice that waits on anything else stays out of plan.json and the
   report names it for Main to start by hand. Check the file with bin/jg-swarm-plan-check.sh orders/plan.json
   until it prints its ok line (the filer's own dry run needs the plan row filed, so /blitz runs it later).
   `files` entries are repository paths, a new file marked ` (new)`; never prose (bin/jg-swarm-plan-check.sh refuses prose
   once slice pc1 lands).
6. Dry run: a worker of the order's model carries out the first order on a scratch copy and reports where it got stuck.
   Fix the order, then record its measured time as the budget for that size of order.

## Gates

- No two orders in one wave name the same file; the union of a wave's file lists has no repeated path.
- An owner-gated order never holds a wave: when its word is not in at its wave's start, the next wave runs and the
  gated order runs later, alone, cut from that day's trunk tip.
- orders/plan.json exists, names every order, and its depends_on lists match the orders' Depends on fields.
- Every order has fixture acceptance, a rollback and an expand path.
- An order names only paths that exist in a worker's copy, or absolute paths with hashes.
- Ready-to-copy sources: before publication, every acceptance command of an order that copies files is run on exactly
  those files, and its printed line is the line the order expects.
- At publication every pinned hash is re-checked against the frozen copy; one that differs stops the publication.
- Every file a step creates or changes is in the order's Files field (check mechanically, the CLI and test runner
  included). A later slice that needs a new subcommand of an earlier slice's tool gets it from the earlier slice.
- Every interface a later slice calls is named in full: each subcommand with its flags and output, each file path, the
  JSON shape of each structured argument, and who writes (the identity each writer stamps and where it comes from).
- Each order has a base rule: which commits it may start from, the check that proves the base is fit (its Tests-first
  lines fail as stated), and what to do when the copy's history differs from the named commit.
- Acceptance runs only what the slice can break: its own tests, the runner's changed-file selection against the base,
  and the coverage check. Never the whole suite (the landing check runs it), and never a line the slice cannot fail,
  such as a simulator run in a slice that does not change the simulated code.
- An order whose file list is mechanical (a command over the base) runs each wave-mate's list command too, and stops
  with `blocked: wave overlap <path>` when a path is in both.
- A change of more than 300 lines is split into expand (behind a flag, beside the old path, with a disagreement record)
  and contract (delete) orders, with a stated number of clean days between them.
- Budget: the dry run's measured wall time, with a number of attempts. An order not yet dry-run says "not measured".
