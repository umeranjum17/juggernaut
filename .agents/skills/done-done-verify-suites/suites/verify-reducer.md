# Verify reducer

The one reducer of the verify's proof results is `core/trunk-verify/reduce.py`: run `done-done run trunk-reduce` (journey `journeys/trunk-reduce.sh` over `tests/jg-trunk-reduce.test.sh`, screen: none).
The test drives its real command line: counted failures against the grace, timeouts, skips, a missing aggregate and a quarantined script as incomplete (never red, never green), the order rule read from test sources and run logs, carried-progressed failures that use no grace slot, the merged first-home check, one deduplicated repair owner per blocking input, and the record map of the asks a blocking script keeps out of use.
The log is `reduce.log` in the run folder.
