# One move log for every machine

Machine moves log: run `done-done run machine-moves-log` (`bash journeys/machine-moves-log.sh`, which runs `bash tests/jg-machine-moves-log.test.sh` and `bash tests/jg-machine-shadow.test.sh` and writes its log and `steps.json` into the run's folder); in a test home the real `bin/jg-machine-shadow.sh` appends a legal move to `data/machine-moves.log` as one line (epoch, machine, id, from, event, to, writer) and writes nothing to `data/machine-shadow.log`, while an illegal move is only in the shadow log; it reads only generated fixtures (screen: none).
