# fleet-status

The fleet status board (`juggernaut-axi board`, `board.sh`): one row per state machine and home. It writes nothing.

## At scale (H38b)

Each home writes one digest, `data/fleet-status/digest.tsv`, with `board.sh --digest <home>`: a `#digest <epoch> <new moves>` line, then
every row of the home. The new-move count comes from the observer cursor (`core/machines/observers/cursor.sh`, H33), so a home's tick
reads only the moves since its last digest. The board then reads one file per home and no record.

- A digest younger than `JG_BOARD_DIGEST_AGE` seconds (default 900) gives the home's rows.
- An older digest names the home in `unread` as late. Nothing is shown from it.
- A home with no digest is read live, as before (each row under `JG_BOARD_BOUND`, default 10 s).

Proof: `bash tests/jg-fleet-status-scale.test.sh` (101 homes, every observer made too slow to answer, board under 10 s).
Not done here: the tick that runs `--digest` in each home. Until it runs, homes are read live.

## Time per step (H48)

`juggernaut-axi board --steps` shows, for every machine and step in every home, n, median, p90 and worst time over 7 days and the
records waiting in the step now (count, oldest). The step with the most total waiting time leads. A step is a state a record left
(`from -> to`), read from the move log (`data/machine-moves.log`, H46); percentiles are the nearest rank. `board.sh --digest` runs
`steps.sh --rollup <home>` on the tick, which writes `data/fleet-status/steps.tsv`; the board reads only those rollups and names a
home with none in `unread`. Proof: `bash tests/jg-fleet-steps.test.sh`.
Not done here: the writers of machines with no move log line (H47) show no steps until they report.

## Prior art

Prior art: none needed. The steps rollup is a per-home aggregate of the H46 move log and the digest is a per-home cached read of rows the board already computes, and the cursor is H33's.

H33 note: its commit `0b99169f1` lost `cursor.sh` because the shared clone's exclude lists `core/machines/`, and the later commit `3f0aac969` (H40) removed its test and journey. This change restores `cursor.sh` (added with `git add -f`), the test, the journey and the journey's registration.
