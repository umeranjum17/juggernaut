# Machine observers

Machine observers: run `done-done run machine-observers` (`bash journeys/machine-observers.sh`, which runs `tests/jg-machine-observers16.test.sh` and writes its log and `steps.json` into the run's folder); it lints `core/machines/tables/squad-lead.tsv` (6 states), `supervision.tsv` (5 states, start state `off`) and `presence.tsv` (4 states, start state `present`), then calls the real `bin/jg-machine.sh show` on a fixture record in every state and checks the word, and that the observers write nothing; it reads only generated fixtures (screen: none).
