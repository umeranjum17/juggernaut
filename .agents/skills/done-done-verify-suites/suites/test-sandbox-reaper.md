# Test sandbox reaper

Test sandbox reaper: run `done-done run -- bash tests/jg-tmp-reaper.test.sh` with the log written into `$DONE_DONE_EVIDENCE_ROOT`; the real `bin/jg-tmp-reaper.sh check` over real stub processes proves a `jg-trunk.*` or `tmp.*` folder holding a trunk-landing tree is stopped and removed once it is older than its own timeout, while a fresh sandbox, a live task root, a sandbox with a process that has a recorded task meta, a folder a task meta names and a `tmp.*` entry with no trunk-landing tree are left alone (screen: none).
