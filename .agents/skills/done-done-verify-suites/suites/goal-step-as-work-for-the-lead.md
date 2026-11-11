# Goal step as work for the lead

Goal step as work for the lead: run `bash tests/jg-turnend-guard.test.sh` and `bash tests/jg-fleet-heartbeat.test.sh` with `JG_HOME` unset; an open Goal's waiting step (a `data/jg-goal-loop/<goal>.next` record) blocks a blind turn end in any home and makes the heartbeat row a GAP naming the Goal step, the registered goal-loop check alone needs nothing, and a taken step stops counting (screen: none).
