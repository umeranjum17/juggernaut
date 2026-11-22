---
name: prior-art
description: "Load before starting new or complex work: a new feature, surface or integration, or any change that invents a mechanism the project lacks."
user-invocable: false
metadata:
  internal: true
---

# prior-art

New or complex work starts from what already exists online, not from a blank page.
Run this before you design or write code, and keep the record with the task so the pick can be reviewed.

1. Search online for similar products and open-source projects that already solve this problem, using the feature, the problem, and the technology as search terms.
2. Read each candidate's licence and say plainly whether it can be used here: permissive, copyleft with obligations, or not usable.
3. Compare three to five real options on the trade-off that decides this task - fit, maintenance, size, licence, integration cost - and name what each one would cost.
4. Record the pick and the reasons in the brief's `# Prior art` section, as a `Prior art pick: ...` line plus a `Licence: ...` line, and run `jg proof prior-art-gate <brief>` before reporting done.

Pick an existing option when one fits.
When none fits, record that instead: `Prior art: none needed - <why>` is an answer, and "we wrote it ourselves" is an answer only after the comparison.
Never copy code from a candidate whose licence forbids it; adopt or vendor it under its licence, or write your own.
