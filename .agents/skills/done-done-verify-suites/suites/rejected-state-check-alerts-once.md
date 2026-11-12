# Rejected state check alerts once

Rejected state check alerts once: run `done-done run rejected-state-check-once` (`bash tests/jg-rejected-state-check-once.test.sh`); the real `bin/jg-watch.sh` runs one cycle at a time over fixture homes and proves a state check with no trust binding raises one wake and one durable row on its first sweep and nothing on later sweeps, a file whose bytes change alerts again, a second distinct file alerts naming only itself, and a file that is bound and then rejected again alerts again (screen: none).
