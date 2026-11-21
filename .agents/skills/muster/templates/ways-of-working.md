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
