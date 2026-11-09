# Brief lint

Brief lint: run `done-done run brief-lint` (`bash journeys/brief-lint-real-briefs.sh`) with `JG_BRIEF_LINT_BRIEFS` naming real worker briefs to read.
The real lint runs over the shipped include file and each named brief; inspect the run-owned `real-briefs.txt`, which holds every finding line and exit code.
`bash tests/jg-brief-lint.test.sh` covers the wait-word conflict of a 9 Nov brief's lines 39, 185 and 190, its two missing skill names, the trunk PR-body conflict, the byte budget and the exit codes (screen: none).
