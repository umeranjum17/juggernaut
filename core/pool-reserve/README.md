# pool-reserve

The copies of a project follow the home's lane limit, and two copies stay free for a red fix.

`reserve.sh limit <jg-home>` prints the copy cap: the lane limit (`core/lane-scale`) plus two reserved copies.
`reserve.sh admit <jg-home> <project-dir> [--red-fix]` is the check `bin/jg-spawn.sh` runs before it leases a copy.
An ordinary lane is deferred (exit 75, the spawn's own deferred path) once the leased copies reach the lane limit; a red-fix lane (`--red-fix-of`) may use the reserved copies up to the cap.
A home with no lane limit is left to the pool's own `max_trees`.
The script leases, ends and removes nothing; `core/lead-sweep` still cleans the copies of landed lanes.

Follow-up, not in this slice: the landing check can call `admit` too, so a landing keeps its reserved copy.

Test: `bash tests/jg-pool-reserve.test.sh`.
