---
name: blitz
description: Use when the captain invokes /blitz or /swarm on a passed plan - file, approve and start every work order, each when its bases land, until all land.
user-invocable: true
metadata:
  internal: true
---

# /blitz

The owner's one word runs a plan to its last landing. Only owner-only cards ask him anything.

## 1. Input ladder

- A plan file (`orders/plan.json`): start it.
- A passed report with no plan file: dispatch one Recon that slices it with `op-order` and writes `orders/plan.json`. Then run the dry run of order 1. Then start. Ask the owner for no new word.
- Plain work text: run `/war-room lite`, then start.
- Never send him to `/war-room` for work that only needs slicing.

## 2. Profile

Load `quota-array-dispatch` for the orders' model. It chooses harness, model and effort. An agent count in his words is `--agents <n>`.

## 3. Start

Run `jg plan blitz start <plan.json> --harness <h> --model <m> --effort <e> --order <MainNNN of the owner's message> [--agents <n>]`.
The order is the plan's `owner_order` when `--order` is left out; each filed row names it, so the brief gate passes with no hand edit.
On a refusal, tell the owner the concrete reason and the one action that clears it.

## 4. Tell the owner once

Say which slices started and in which homes, how many wait for his word on the board, and `Say /spotrep at any time.`

## 5. While it runs

Do nothing. A stuck lane follows the stuck-worker ladder.

- Finish line: tell the owner the outcome in one line. Say landed, and released or not (AGENTS.md hard rule 5).
- Owner-wait line: the cards are already on the board. His answer frees the slice with no model turn. The board-answers check records it on Main's word row. A lead home's word-row upkeep (`jg plan swarm-words`, run with its swarm check) takes the pick into the lead's own store. Main never writes a lead home's backlog.
- Stall line: run `jg plan swarm-check status <plan>`, read each reason and clear it. Go to the owner only for what only he can clear.

## 6. Away

With `/watchover` on, the swarm needs no model turn to advance.

## 7. Lead homes

script: A lead that receives `Swarm <plan> is routed to you. Run: bin/jg-swarm-arm.sh ...` runs that exact line in its own home and reports its output.
A routed board answer for one of its swarm slices needs only the acknowledgement the line asks for. The home's word-row upkeep frees the slice by itself.
