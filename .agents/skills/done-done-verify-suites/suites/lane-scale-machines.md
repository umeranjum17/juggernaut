# Lane scale machines

Lane scale machines: run `done-done run lane-scale-machines` (`bash journeys/lane-scale-machines.sh`, which runs `tests/jg-lane-scale-machines.test.sh` and writes its log and `steps.json` into the run's folder); it runs the real `core/lane-scale/fleet.sh place` on fixture process lists read through an ssh stand-in: a full host sends the lane to the machine with most headroom, a machine that cannot be read is named and skipped, every machine full stops all starts, and 120 machines are read in one round (screen: none).
