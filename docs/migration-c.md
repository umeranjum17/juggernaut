# Migration to option C

This page records the decisions behind the option C migration, so the code carries its own context.
Read it before any migration work.

## Decision and goals

Option C keeps the product and replaces the plumbing and structure underneath it.
The product does not change: Overwatch, Squad Leads, operators, the captain contract, the board, delivery modes, merge authority, and proofs behave the same.
Every path switches only after its parity test passes in shadow.

The five goals, scored together:

1. Fewer lines of code.
2. Robustness.
3. Speed of change on a stable core. This is the main objective: adding a guard, escalation rule, alert route, or harness quirk is one policy or data file plus one test, with no core code change.
4. Fewer tokens: event-driven wakes, batching, and role-scoped rules.
5. AXI: one agent-friendly command surface, `juggernaut-axi`.

## Stack

- NATS JetStream carries messages, queues, history, and key-value state such as locks and busy state.
- Dapr in slim mode, without Docker, runs over NATS. Workflows own timers, escalation, and wait-for-reply.
- Open Policy Agent owns every rule that is a yes/no over facts.
- ntfy is the captain channel, the one way the fleet reaches the captain and the captain replies. It is built without the public relay.
- Go is used for new long-running code. Node stays only in short-lived hooks.

## Code shape

- Facts, then policy, then action. Code gathers facts and acts. Policy decides. Only real rules move to policy; plumbing is not turned into policy.
- Policy is Rego run by OPA, kept in `policy/` with `_test.rego` files. It is never JavaScript (`.mjs`).
- There are four policy extension points: guards, escalation rules, alert routes, and harness quirk tables. Each has one frozen fact schema, one host, and contract tests.
- New code goes into the core (`core/`), never into add-ons. There are no `addons/` files, no per-feature installers, and no "add-on" word in docs, config, or home names.
- One shared library per concern: hash, path, JSON escape, atomic write, die, meta read, and default branch. Copied blocks are deleted.
- Rules are config, not hard-coded shell. Thresholds, timers, routing, and urgency live in the shared JSON rule schema or in Rego.
- Every event has an urgency set in a rule file: `now` wakes at once, `batch` joins a digest, `silent` is recorded only.

## Steps, in order

1. The watcher settles routine wakes without a model turn, with now, batch, and silent levels, and `wake next` as one call.
2. Harness quirk tables become data plus Rego.
3. The guard host moves into the core with the OPA engine, and repo-guard is the first Rego rule.
4. Shared libraries replace the copied blocks.
5. The plumbing swap to NATS, Dapr, and ntfy runs in shadow first, one path at a time. One shared NATS server runs per machine, with one account, one `jg.<home>.>` subject prefix, and its own streams per home. A remote machine joins through a leaf node.
6. The add-on concept ends: every add-on is folded into the core or deleted where the migration replaces it, and a merge check refuses new files under `addons/`.

## Process rules

- Each feature is one PR into the release branch, opened only when the whole feature is done. The release branch merges to main as one release with full proof.
- Before building anything new, run the prior-art step: look for mature open source with a permissive licence to build on.
- Report measured results only, never forecast dates.
- A status line that says working names a live worker.
- A finished report sends its conclusion at once; a bookkeeping gate never hides a finished result.
