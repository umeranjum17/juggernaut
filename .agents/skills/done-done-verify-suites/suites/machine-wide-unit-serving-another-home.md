# Machine-wide unit serving another home

Machine-wide unit serving another home: run `done-done run -- bash tests/jg-bootstrap.test.sh sentinel`; the real `bin/jg-bootstrap.sh` proves an active `jg-sentinel`, `jg-wake-engine`, `jg-wake-watcher` or `jg-router` unit whose `JG_HOME` is another home prints one `UNIT_HOME:` line naming the unit, the home it serves and the repair command, and stays silent when the unit serves this home or a Squad Lead home, where before only `is-active` was tested (screen: none).
