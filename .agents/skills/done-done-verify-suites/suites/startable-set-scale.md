# Startable set at scale

Startable set at scale: run `done-done run startable-set-scale` (it writes `spawnable-scale.log` and `startable-set.txt`, the answer and each run's time) with `JG_BEADS_TEST_BD` and `JG_BEADS_TEST_DOLT` set; a real Beads store grown to 60,000 rows proves `bin/jg-backlog.sh ready --spawnable` names only the one startable ticket (a held, an assigned, a card-linked, a live-lane and an unregistered-project ticket stay out) and ends with a median under 1 second and a slowest under 2 seconds over 20 runs (screen: none).
