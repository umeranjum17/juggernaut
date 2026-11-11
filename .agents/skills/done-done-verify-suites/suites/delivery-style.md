# Delivery style

Delivery style: run `done-done run delivery-style` (`bash journeys/delivery-style.sh`, which runs `tests/jg-delivery-style.test.sh` and writes its log and `steps.json` into the run's folder); it prints the row of each of the four modes from `core/machines/styles/delivery-styles.tsv` through `bin/jg-delivery-style.sh`, refuses an unknown mode, and checks that no row names a prover; it reads only the shipped table (screen: none).
