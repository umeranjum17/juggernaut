# Recon table

Recon table: run `done-done run recon-table` (`bash journeys/recon-table.sh`, which runs `bin/jg-machine.sh check recon`, `events recon` and `tests/jg-machine-recon.test.sh` and writes its log and `steps.json` into the run's folder); it lints `core/machines/tables/recon.tsv` (3 states, 4 moves, each with a test) and drives a Recon through the real owner script `bin/jg-recon-handoff.sh`: draft, critic verdict with gaps, revise, verdict clear and accept, each tied to the report hash, and a verdict for an older hash is refused and cannot close the newer draft (screen: none).
