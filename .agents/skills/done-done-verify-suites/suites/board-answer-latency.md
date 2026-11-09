# Board answer latency

Board answer latency: run `done-done run -- bash tests/jg-board-answers-latency.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT` (add `JG_BOARD_LATENCY_REAL=1` for the shipped 15 s / 30 s timing, about two minutes); the real watcher on a throwaway home arms the check itself, stays silent on the first pass, wakes within the bound of a new answer and prints the measured seconds; a registration broken after binding is re-armed, one that cannot be re-armed raises one alert naming the check and then recovers, and a disarmed check stays disarmed (screen: none).
