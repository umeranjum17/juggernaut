# project-state-map

A map of each project's states and moving parts for the sign-off board.
The map is built in four steps: a script searches the code, a small model reads the hits, a script re-searches every cited line and drops false ones, and a script draws the board card.
The plan is `data/project-state-machines-report/report.md` in the owning home; the build is sliced, and this file lists only the steps that exist.
No step ever changes a project file.
- `bin/psm-search.sh <project-dir> [--out file] [--max-hits N] [--max-per-file N]` is the search step: it writes a `psm.hits.v1` hit list with file, line, pass and text for four passes (closed value sets, flags and empty fields, loops and timers, machinery), the project tree, and a hash of the hit text.
  Dependency and build folders, lock and minified files, binary files, secret-looking names and files over 400 KB are skipped, so no excerpt of them can reach a later step.

## Check
- `bash tests/psm-search.test.sh` runs the search over `tests/fixture-project`, which has known states and parts: the known hit list, a git repo giving the same hits with secrets skipped, the project left unchanged, the hit hash following hit text only, the caps, and refused input.
