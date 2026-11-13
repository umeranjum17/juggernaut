# fleet status board at scale

Run `done-done run fleet-status-scale` (which runs `journeys/fleet-status-scale.sh`: `tests/jg-fleet-status.test.sh` then `tests/jg-fleet-status-scale.test.sh`); it writes the run log as evidence.
It proves the board reads one digest per home (101 lab homes, every observer too slow to answer, board under 10 s), names a late digest, and reads a home with no digest live.
