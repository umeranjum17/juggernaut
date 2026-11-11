# Ship brief style

Ship brief style: run `done-done run ship-brief-style` (`bash journeys/ship-brief-style.sh`, which writes its log and `steps.json` into the run's folder); it scaffolds the ship brief of each of the four modes through `bin/jg-brief.sh`, which reads `core/machines/styles/delivery-styles.tsv`, compares each with its golden in `tests/fixtures/ship-brief/` byte for byte, and requires an unknown mode to be refused; it reads only the shipped table and a synthetic home (screen: none).
