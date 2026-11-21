---
title: <title>
slug: <slug>
status: planned          # spec-docs lifecycle: planned | in-progress | implemented | tested | archived
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
owner: <owner>
links:
  - <relative link>
muster: <ticket id>
---
# Spec: <title>

The frontmatter is the global spec-docs skill's schema plus one `muster` line; the spec-docs skill renders
`<slug>.html` beside this file and regenerates `index.html`. The pack approval hashes this file with `status`,
`updated` and the `## Revisions` section left out.

## Context
## Problem
## Solution (user view)
## Objectives (proof first)
| Journey id | Kind | Key example (given, when, then) | On the base | On the changed build |
|---|---|---|---|---|
| <journey id> | new | given <...>, when <...>, then <...> | fails with `assert: <name>` | passes |
| <journey id> | preserve | given <...>, when <...>, then <...> | passes | passes |

Kinds: **new** behaviour must run on the base and fail on its named assertion; **preserve** behaviour must pass on both.
A journey that cannot start exits 77 and is a setup error, never the expected failure. A brand-new project's base is
its initialized skeleton commit.

## Files to change
## Test list
## Out of scope
## Verification
- [ ] Every journey in the Objectives table passes on the released build (done-done receipt on the landed commit).

## Revisions
- <YYYY-MM-DD> <what changed and why>
