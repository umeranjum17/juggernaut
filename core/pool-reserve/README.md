# pool-reserve

The copies of a project follow the home's lane limit, and two copies stay free for a red fix.

`reserve.sh limit <jg-home>` prints the copy cap: the lane limit (`core/lane-scale`) plus two reserved copies.
`reserve.sh admit <jg-home> <project-dir> [--red-fix]` is the check `bin/jg-spawn.sh` runs before it leases a copy.
An ordinary lane is deferred (exit 75, the spawn's own deferred path) once the leased copies reach the lane limit; a red-fix lane (`--red-fix-of`) may use the reserved copies up to the cap.
A home with no lane limit is left to the pool's own `max_trees`.
A pool that cannot be read (`treehouse status` fails) leaves the count unknown, which is its own answer and never zero: `admit` exits 75 with a line that says the copies cannot be counted and carries the tool's own cause, `bin/jg-spawn.sh` defers, and the next beat starts the ticket again under the same approval.
The script leases, ends and removes nothing; `core/lead-sweep` still cleans the copies of landed lanes.

Follow-up, not in this slice: the landing check can call `admit` too, so a landing keeps its reserved copy.

Test: `bash tests/jg-pool-reserve.test.sh`.
