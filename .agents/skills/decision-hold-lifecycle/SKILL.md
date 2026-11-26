---
name: decision-hold-lifecycle
description: "Renamed pointer: load captain-hold-lifecycle instead."
user-invocable: false
metadata:
  internal: true
---

# decision-hold-lifecycle (renamed)

The separate decision concept was collapsed into the one primitive the captain cares about: a task held for the captain.
Read and follow `.agents/skills/captain-hold-lifecycle/SKILL.md`; it owns the completion gate, the recorded-answer rule, and every command this skill used to describe.
Where an older brief says `bin/jg-decision-hold.sh`, that script is gone: use the `jg hold captain-hold` commands.
