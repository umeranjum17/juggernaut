# loop-stall

A Blitz plan or a Goal with ready work that makes no progress for 10 minutes raises one P1 that only progress clears.

`loop-stall.sh tick <jg-home>` runs from the delivery tick (`bin/jg-delivery-tick.sh`) with no model awake.
It reads two feeds and times each candidate:

- Blitz: `bin/jg-swarm-check.sh ready` names a running plan with a slice it could start and none in flight. The signature is the plan's counts.
- Goal: `core/goal-loop/goal-loop.sh state` names a Goal whose current step is open and untaken (`next`). The signature is that step.

A candidate whose signature held for `JG_LOOP_STALL_SECS` (default 600) raises one `fleet-blocked` alert (precedence P1, rung 2) through `bin/jg-alert.sh`.
The key is `fleet-blocked--blitz-<plan>-stalled` or `fleet-blocked--goal-<goal>-stalled`. A live alert climbs on later ticks.

An acknowledgement, a drained wake or a repeat never closes it. Only progress does: a changed signature, or the loop having no ready work (finished, stopped for the owner, step taken).
The resolve names that as its proof. A feed that cannot be read changes nothing, because unknown is never progress.
Clocks are `data/loop-stall/<kind>--<subject>.tsv` (`since`, signature).

Proof: `bash tests/jg-loop-stall.test.sh`.
