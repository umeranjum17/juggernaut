# project-state-map

A map of each project's states and moving parts for the sign-off board.
The map is built in four steps.
A script searches the code, a small model reads the hits, a script re-searches every cited line and drops false ones, and a script draws the board card.
A refresh runs the four steps only when the code changed.
The plan is `data/project-state-machines-report/report.md` in the owning home; the build is sliced, and this file lists only the steps that exist.
No step ever changes a project file.
- `bin/psm-search.sh <project-dir> [--out file] [--max-hits N] [--max-per-file N]` is the search step: it writes a `psm.hits.v1` hit list with file, line, pass and text for four passes (closed value sets, flags and empty fields, loops and timers, machinery), the project tree, and a hash of the hit text.
  Dependency and build folders, lock and minified files, binary files, secret-looking names and files over 400 KB are skipped, so no excerpt of them can reach a later step.
- `bin/psm-read.sh <hits.json> [--project-dir dir] [--out file] [--opt-in] [--max-usd N] [--replay reply.txt]` is the reading step: it sends the hit lines with two lines of context to a small model and writes the reply as a `psm.map.v1` map for the proof step.
  A live call sends code excerpts to the model provider, so it runs only with `--opt-in`, which is given per project after the owner approved it; `--replay` reads a saved reply and sends nothing.
  The spend cap (`--max-usd`, default 0.05, against an estimate from the excerpt size) stops a big run before any call, and a cap of 0 turns the step off.
  The estimate counts 3000 reply tokens at an unverified list price, so it runs high: the fixture project estimates $0.0154.
  A reply that is not a valid map is refused with every problem listed.
- `bin/psm-prove.sh <map.json> <project-dir> [--out file]` is the proof step: it checks a `psm.map.v1` map (machines with states, moves and evidence lines; moving parts; what was not read) against the code.
  A map that breaks the format is refused with every problem listed.
  Every cited line is looked up again; a line that is not there, does not contain the cited text, or names a secret-looking or outside file is dropped and counted.
  A move to an unlisted state is dropped, and a machine or part left with no evidence is dropped, so the `psm.proved.v1` result holds only what the code shows, with the counts under `proof`.
- `bin/psm-card.sh <proved.json> --out-dir dir [--filed iso] [--post board.json [--replaces key]]` draws the board card with no model call: a schema 5 report in the "State map" group with a bar summary, one picture each for explicit sets, hidden states and machinery (only the kinds the map has, phone first, light and dark), one item per machine and part with its evidence lines, and a closing section for what was not read and what was dropped.
  The same map and `--filed` give the same bytes.
  `--post` publishes with `sign-off-axi` (or `JG_REPORT_POST`), copies the pictures beside the board file, and dismisses the replaced card.

- `bin/psm-refresh.sh run <project-dir> --state dir --board board.json [--force] [--opt-in] [--max-usd N]` runs the chain for one project and keeps one live card.
  The refresh key is the tree plus the hash of the hit text; when it equals the stored key the run says "unchanged" and makes no model call and no board write.
  A changed key, or `--force`, reads, proves, posts a new card and dismisses the old one.
  A refused or failed read leaves the old card and the stored key alone.
  `tick <home>` is the scheduled entry: it reads `config/project-state-map` (one `<project-dir> opt-in` line per project, the opt-in word required) and the board in `config/fleet-board`, and is silent unless a card was refreshed or a read failed.
- `bin/psm-refresh.sh ask <home> <project> [--force] [--opt-in] [--max-usd N]` is how a person asks for a fresh map: `<project>` is a directory or a name in `config/project-state-map`.
  It shares the state and board of `tick`.
  When the code has not changed it prints "unchanged" and `current card: <key>` and costs nothing; when it changed, or with `--force`, it refreshes and replaces the card.
  A live read still needs the project's opt-in word in the config, or `--opt-in` on the ask.
  `psm-card.sh --rev` gives each card a new key, because a board refuses a key it already holds.

## Check
- `bash tests/psm-refresh.test.sh` refreshes a copy of the fixture project with a stub model: one call and one post on the first run, none when unchanged, a new card on `--force`, a refresh only when a hit line changes, refusals leaving the old card, the tick, and a real board when `sign-off-axi` is installed.
- `bash tests/psm-ask.test.sh` asks by project name and by directory: the second ask says unchanged with no model call and no post, force reruns and dismisses the old card, an unknown project, a missing opt-in and a missing board are refused.
- `bash tests/psm-acceptance.sh <evidence-dir>` is the acceptance chain on the fixture project, with a 390 px picture (needs `sign-off-axi` and `chrome-devtools-axi`).
- `bash tests/psm-read.test.sh` reads the fixture hits with a replayed reply and a stub model: the map keeps the hit key, a live read needs the opt-in, secret-looking files are not sent, the cap and a cap of 0 stop the call, and a bad reply is refused.
- `bash tests/psm-search.test.sh` runs the search over `tests/fixture-project`, which has known states and parts: the known hit list, a git repo giving the same hits with secrets skipped, the project left unchanged, the hit hash following hit text only, the caps, and refused input.
- `bash tests/psm-prove.test.sh` proves `tests/fixture-map.json`, which plants false lines: the true machines stay, the false ones are dropped and counted, and the project is left unchanged.
- `bash tests/psm-card.test.sh` draws the card from the proved fixture map: same map same bytes, the pictures the map has, the dropped count, the post and dismiss calls, and acceptance by a real board when `sign-off-axi` is installed.
