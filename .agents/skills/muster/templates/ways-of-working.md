---
status: draft
muster: <ticket id>
---
# Ways of working: <project>

Every rule names its check. A rule with no check is refused by the muster gate; a check with no planted-fault proof
is refused too.

## Stack
- <language, framework, data store, hosting> - decision <NNNN> each.

## Rules
| Rule | Why | Enforced by | Proof (planted fault fails, allowed use passes) |
|---|---|---|---|
| <rule> | <why> | <tool and rule id> | <fault file fails; allowed file passes> |

## Engineering practices

Use the project glossary, domain model, existing constraints and done-done plan to settle each practice.
Use one row per practice and record a concrete project direction with status `Decision` or `Accepted recommendation`.

| Practice | Status | Direction |
|---|---|---|
| SOLID | <status> | <which domain responsibilities are separate, where dependencies point, and which interfaces the use cases need> |
| DDD | <status> | <how the glossary, domain boundaries and invariants guide implementation> |
| Testing | <status> | <where fast unit and behaviour tests run, which few core end-to-end journeys prove outcomes, and how those checks map to the done-done plan's verification layers> |
| Error handling | <status> | <how domain refusals and operational failures are handled and reported> |
| Security | <status> | <the affected trust boundaries and how data, access and secrets are protected> |
| Observability | <status> | <how operators distinguish healthy behaviour from failure, and what they can inspect> |

## Floor (numbers)
| Measure | Threshold | Enforced by |
|---|---|---|
| <measure> | <number> | <CI step> |

## Measured, not yet enforced
- <measure> - <current value> - <date it becomes a gate>

## Comments
<Comment policy; name the check, or say that review holds it.>

## Folders
<Convention and its source, for example bulletproof-react: shared, features, app; one-way imports.>

## Tests
<Which kinds; where they live; what proves a user journey.>

## Done means
<The Definition of Done, enforced by done-done: every objective journey passes on the released build.>

## Exceptions (time-limited)
- <rule> - <where> - <until YYYY-MM-DD> - <the captain's word, with its record>
