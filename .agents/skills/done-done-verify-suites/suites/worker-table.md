# Worker table

Worker table: run `done-done run worker-table` (`bash journeys/worker-table.sh`, which runs `tests/jg-machine-worker.test.sh` and writes its log and `steps.json` into the run's folder); it lints `core/machines/tables/worker.tsv` (6 states, 11 moves, each with a test) and its enum, reads a fixture record in each of the six states through the real observer (`core/machines/observers/worker.sh`), and reports legal and illegal moves to the shadow log (a legal move adds no line); it reads only generated fixtures (screen: none).
