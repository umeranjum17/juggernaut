# Proc reaper

Proc reaper: run `done-done run -- bash tests/jg-proc-reaper.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; it arms `core/tmp-reaper/wiring.sh` in a throwaway home and runs the installed `proc-reaper` check. A child started through `bin/jg-run-owned.sh` is ended inside 2 ticks once its owner exited or its limit passed, a start with no owner or no limit is refused, and an agent-named process with no record is named by `proc.sh list` and never touched.
