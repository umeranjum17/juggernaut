# A sealed run says what it ran

A sealed run says what it ran: run `done-done run -- bash -c 'bin/jg-test-run.sh --changed --base <trunk branch> --json "$DONE_DONE_EVIDENCE_ROOT/changed-tests.json"'` at the lane's final head; it runs the changed tests and writes the scripts it ran, each with its exit, into `changed-tests.json` in the run's folder, so the run record lists the file by its hash. A failing changed test makes the run fail and the lane gets no receipt. The landing check (`tests/jg-trunk-sealed-ran.test.sh`, through `bin/jg-trunk.sh land`) counts the run only when that list holds every script of the landing's own changed selection, passed; a run with no list, a list that leaves a script out or shows one failing, or a list that no longer matches its recorded hash is not counted, and the tests run at the landing (screen: none).

A sealed run also proves the commit holds what its tests read: while `--changed` runs, `bin/jg-test-ignored-reads.sh` watches the files git ignores and the commit does not hold (a fixture under `tests/` whose folder is named `config` or `state`, an untracked build output) and fails the run with `not ok - a test read the git-ignored file <path>, which the commit does not hold` for each one a test opened for reading.
A file the commit tracks is not watched, so the same read passes once it is committed (`git add -f`).
The operational folders the `.gitignore` names at the top level (`data`, `state`, `config`, `projects`), python caches and `.DS_Store` are exempt.
With such files present and no `inotifywait`, the run fails saying so rather than passing unwatched.
`bash tests/jg-test-run.test.sh` proves both outcomes on a fixture repository (screen: none).
