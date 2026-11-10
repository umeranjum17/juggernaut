# Go commands offer only what is called

Go commands offer only what is called: run `bash tests/jg-go-entries.test.sh` (or `done-done run -- bash tests/jg-go-entries.test.sh` with the suite's log written into `$DONE_DONE_EVIDENCE_ROOT`); it builds the status classifier, the wake core and the spawn core from the checkout through `bin/jg-classify.sh`, `bin/jg-wake-core.sh` and `bin/jg-spawn-core.sh`, and proves that every command name each prints in its usage line has a caller, a shell line outside its module, the tests and the journeys, and that each entry deleted for having no caller exits 2 (screen: none).
A name only a test calls has no caller; `facts` is exempted by name until go-shell slice GS17 deletes it.
Adding or deleting an entry means editing the usage line in that command's `main.go`.
