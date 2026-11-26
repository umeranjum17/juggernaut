---
name: council
description: Use when the captain invokes /council. It is /muster council: specialist lens lanes gather the questions first, with no pack, and the merged questions go back to the round.
user-invocable: true
metadata:
  internal: true
---

# /council

/council is `/muster council`. It is not a War Room trigger.

## What it does
- `bin/jg-war-room.sh lenses <ticket> --project <p> --lenses user,domain,architecture,skeptic,quality --harness <h> --model <m> --effort <e>` starts one lens lane for each lens, through War Room's lane machinery. It needs no pack and files no plan.
- Each lens lane writes its draft (questions with its own answers, and for the domain lens the core objects, their states and events) and records it with `bin/jg-recon-handoff.sh draft`. `bin/jg-war-room.sh next <ticket>` files nothing more: it names the lens it waits for, then says to merge.
- `bin/jg-muster-council.sh merge <ticket>` writes the merged questions to the ticket's round record. Answers the lenses agree on are taken by the agent; only a contested or captain-only question stays open for the captain. The domain lens's objects, states and events go to the drafter.

A hard design or problem that needs one plan in work orders is `/war-room`, not `/council`.
