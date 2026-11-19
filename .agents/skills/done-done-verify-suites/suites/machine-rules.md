# Machine table rules

Machine table rules: run `done-done run machine-rules` (`journeys/machine-rules.sh`, which lints every table under `core/machines/tables/` with `bin/jg-machine.sh check`, then runs `tests/jg-machine-writer-lint.test.sh` (the report-only `jg-machine.sh writers`: each edge whose writer file calls neither the shadow nor the move command is named, exit 0) and writes its log into the run's folder); it reads only generated fixtures and the shipped tables (screen: none).
