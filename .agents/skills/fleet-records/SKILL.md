---
name: fleet-records
description: >-
  Agent-only home-layout, knowledge-routing, and backlog-record rules kept out of the always-loaded AGENTS.md.
  Load before routing durable knowledge, editing a backlog item or task note, handing work across homes, or interpreting home layout.
user-invocable: false
metadata:
  internal: true
---

# fleet-records

This skill owns the layout summary, knowledge routing, and backlog-record rules that `AGENTS.md` sections 2 and 10 point to.
The safety rules and load triggers stay in `AGENTS.md`; nothing here relaxes them.

## Home layout

`docs/configuration.md` is the single owner of the top-level operational-home layout and configuration schemas; each producing script's header and help own exact child fields and mutation mechanics.
`JG_HOME` selects an instance's private `data/`, `state/`, `config/`, and `projects/`, while scripts continue to come from their tracked code root.
Each Squad Lead has a persistent isolated `JG_HOME`, including its own state, backlog, projects, and session lock.

Tracked files hold shared instructions and tooling; `data/` holds durable private fleet records; `state/` holds runtime records and append-only status events; `config/` holds local operating choices; and `projects/` contains clones that are read-only to Overwatch except under hard rule 1's concrete captain-approved project operation exception.

## Projects and Squad Leads

Its scope field drives routing and its project list is non-exclusive provisioning data, not ownership.
Routed backlog items count as routed work: when a Squad Lead is idle and its own backlog has ready items not held for the captain, the watcher wakes it to dispatch them, P0 first, up to project capacity, and the fleet view flags a lead that stays idle with ready work.

## Knowledge routing

Route durable knowledge to its most specific owner:

- A home may declare authoritative external memory tiers in a `Memory layering` section of its captain-preference files ([`docs/configuration.md`](../../../docs/configuration.md) owns the schema); each declared tier owns the knowledge classes it names, this home's `data/` is then only a per-machine cache for those classes, capture to the tier is never skipped because a local file also received the fact, and a correction follows the tier's declared rule rather than an in-place edit.
- When a worker's harness cannot reach a declared tier, Overwatch captures on the worker's behalf from its report.
- A standing owner correction becomes a rule in `data/owner-rules.md` through `bin/jg-owner-rules.sh add --kind owner`, with his own words, its scope, and the code or contract that enforces it; a correction that stops at one agent's memory is what `bin/jg-owner-rules.sh audit` flags.
- A correction that is an engineering default every Juggernaut user should get is a product rule: it never becomes an owner-rules entry, and it becomes a ticket and a change to what ships, in `AGENTS.md` where an agent needs it always, a shipped default, a doc, or the code that enforces it.
- Home-domain captain preferences and working style belong in `data/captain.md` after inspect-then-update.
- Captain preferences shared across Squad Lead domains belong in the primary home's `data/captain-shared.md` under the `squad-lead-provisioning` contract.
- Fleet-local operational facts no declared tier owns belong in curated, home-local `data/learnings.md`.
- Task-scoped notes belong with the backlog item, and investigation findings belong in the Recon report.
- Knowledge useful to almost every contributor to one project belongs in that project's committed `AGENTS.md`, which only deliberate human edits extend.
- Knowledge general to every Juggernaut user belongs in this repo's shared tracked surface, which a user/operator home can only reach through an authorized contribution - otherwise it stays in `data/learnings.md` or a local draft for the captain.

## Backlog

The configured `tasks-axi` backend is the durable queue; the tracked default is `data/backlog.md`.
It tracks work items only, never agents; persistent Squad Leads never appear as backlog items.
Work routed to a Squad Lead is recorded in that Squad Lead home's own backlog, not the main backlog.
A new item needs a type tag and a justification line, or `bin/jg-tasks-axi.sh add` refuses it; `docs/configuration.md` "Backlog intake" owns the rule.
When a main-side thread such as a pending captain decision or relay reminder is worth durable tracking, file it as its own work item and hold it through that wrapper.
When the automatic transition gate applies, dispatch and completion move the item themselves - `bin/jg-spawn.sh` and `bin/jg-teardown.sh` own those transitions and refuse rather than report success without them - so what remains yours is filing the item before dispatch, recording decisions, and keeping notes current; `docs/configuration.md` owns gate applicability and the manual-backend exception.

`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retention, and routine command syntax.
`squad-lead-provisioning` and `bin/jg-backlog-handoff.sh` own cross-home handoff safety.

## Task notes

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge by the knowledge-routing rules above rather than scattering it through task notes.
