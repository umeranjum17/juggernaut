# trunk-ci

A red or green CI run of a trunk commit is on record within one tick of the end of its run, with no hand step.

`ci-result.sh check <jg-home>` is the watcher check. For each project with a trunk and a github.com origin it reads the forge's runs
of the trunk branch, groups them by commit, and writes one row for each commit whose runs have all ended.
A commit is red when any run ended failure, timed_out or startup_failure, and green when every run ended success, skipped or neutral.
A commit that is not on the local trunk is ignored, and a commit with a row is never read again.

## The row

`data/trunk-ci-observed.tsv`, written under `state/.trunk-ci-result.lock`:
`project`, `commit`, `epoch` (the newest run's end), `green|red`, `run id`, `watch|act`, `acted|held|-`.

## Two modes

| Mode | How it is chosen | What it does |
|---|---|---|
| watch (default) | no `config/trunk-ci-result`, or it does not say `act` | records the row and changes nothing else |
| act | `config/trunk-ci-result` says `act`, and at most 2 of the project's last 20 observed results (this one included) are red | also runs `bin/jg-trunk.sh ci <project-dir> <commit> green\|red`, which owns the green pin, the move of every home and the red alert |

When more than 2 of the last 20 are red, the result is recorded as `held` and nothing is sent: a red this common is not moved back by a script.
`JG_TRUNK_CI_RED_MAX` and `JG_TRUNK_CI_WINDOW` set the two numbers. A commit that already has the same result in `data/trunk-ci.tsv` is recorded and not sent again.
A failed `jg-trunk.sh ci` writes no row, so the next tick sends it again. Each red prints one line, which the watcher turns into a check wake.

The row appears on the first tick after the run's last job ends. `wiring.sh <jg-home>` installs and registers the check; `unwiring.sh` removes it and keeps the rows.
